;;; harness-tools-dev-test.el --- Tests for the open_harness tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool and method that run a checkout's harness in an Emacs of its
;; own (harness-tools-dev.el, this repository's own plugin, in
;; .harness/plugins/dev/), and the lifetimes of those Emacsen.  A
;; fake scripts/dev.sh in a temp checkout records what the launcher ran,
;; and stand-in sessions and tasks say who needs an instance, so no
;; Emacs is started here but by the test that stops a real daemon and
;; the one that drives a real daemon from the sandbox.  The real
;; scripts/dev.sh is tried with fake emacs and emacsclient programs.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools)

(defvar harness-tools-dev--check-timer)
(defvar harness-tools-dev--own-socket)
(defvar harness-tools-dev--processes-function)
(defvar harness-tools-dev-probe-timeout)
(defvar harness-tools-dev--exit-timeout)
(defvar harness-tools-dev--kill-grace)
(defvar harness-tools-dev--starting)
(defvar harness-session--tmp-root)
(defvar harness-sandbox-policy)
(defvar harness-perms-extra-auto-allow-tools)
(defvar harness-perms--auto-allow-tools)
(defvar harness-tool-slots-tools)
(defvar harness-acp-extra-method-prefixes)
(defvar harness-acp-extension-prefixes)

(declare-function harness-perms--mode-decision "harness-perms" (decision request))
(declare-function harness-plugins--apply "harness-plugins" (dir))

(declare-function harness-sandbox-detect "harness-sandbox" ())

(defmacro harness-tools-dev-test-with (&rest body)
  "Load the tools registry and tools-dev on a fresh bus; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(tools tools-dev))
       (harness-test-load-module m))
     ,@body))

;;;; A stand-in world of sessions and tasks

(defvar harness-tools-dev-test--sessions nil
  "The stand-in sessions, an alist of id -> plist.")

(defvar harness-tools-dev-test--tasks nil
  "The stand-in tasks, plists.")

(defvar harness-tools-dev-test--asked nil
  "The sockets of the instances asked to exit, newest first.")

(defun harness-tools-dev-test--task (id)
  "Return stand-in task ID, or nil."
  (cl-find id harness-tools-dev-test--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-tools-dev-test--world ()
  "Stand in for the session and task modules, from the variables above."
  (harness-register-method 'session/exists-p
                           (lambda (id) (and (assoc id harness-tools-dev-test--sessions) t)))
  (harness-register-method 'session/get
                           (lambda (id) (or (cdr (assoc id harness-tools-dev-test--sessions))
                                            (error "No session %s" id))))
  (harness-register-method 'session/list
                           (lambda (&optional filter)
                             (cl-remove-if (lambda (s) (and (plist-get filter :active)
                                                            (eq (plist-get s :status) 'inactive)))
                                           (mapcar #'cdr harness-tools-dev-test--sessions))))
  (harness-register-method 'task/list (lambda (&optional _cwd) harness-tools-dev-test--tasks))
  (harness-register-method 'task/get
                           (lambda (id) (or (harness-tools-dev-test--task id) (error "No task %s" id))))
  (harness-register-method 'task/for-session
                           (lambda (sid) (cl-find sid harness-tools-dev-test--tasks
                                                  :key (lambda (task) (plist-get task :session))
                                                  :test #'equal))))

(defun harness-tools-dev-test--session (id &rest plist)
  "Make stand-in session ID, or change it, with PLIST.
A new one is idle, of kind main and just active, unless PLIST says otherwise."
  (let ((cell (assoc id harness-tools-dev-test--sessions)))
    (if cell
        (setcdr cell (harness-plist-merge (cdr cell) plist))
      (push (cons id (harness-plist-merge (list :id id :status 'idle :kind 'main :updated (float-time))
                                          plist))
            harness-tools-dev-test--sessions))))

(defun harness-tools-dev-test--set-task (id &rest plist)
  "Make stand-in task ID, or change it, with PLIST.
A new one is active, unless PLIST says otherwise."
  (let ((task (harness-tools-dev-test--task id)))
    (setq harness-tools-dev-test--tasks
          (cons (harness-plist-merge (or task (list :id id :state 'active)) plist)
                (remove task harness-tools-dev-test--tasks)))))

(defmacro harness-tools-dev-test-world (&rest body)
  "Run BODY with tools-dev over stand-in sessions and tasks.
No instance is asked to exit for real: `harness-tools-dev-test--asked'
collects the sockets that are."
  (declare (indent 0))
  `(harness-tools-dev-test-with
     (let ((harness-tools-dev-test--sessions nil)
           (harness-tools-dev-test--tasks nil)
           (harness-tools-dev-test--asked nil))
       (harness-tools-dev-test--world)
       (when (timerp harness-tools-dev--check-timer) (cancel-timer harness-tools-dev--check-timer))
       (setq harness-tools-dev--check-timer nil)
       (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                  (lambda (socket &optional _path) (push socket harness-tools-dev-test--asked) (harness-resolved nil))))
         (unwind-protect (progn ,@body)
           (when (timerp harness-tools-dev--check-timer) (cancel-timer harness-tools-dev--check-timer))
           (setq harness-tools-dev--check-timer nil))))))

(defun harness-tools-dev-test--open (dir sid &optional focus)
  "Open DIR's harness with the tool, as session SID's agent; return the result."
  (harness-test-await (harness-tools-dev--open (list :path dir :focus (if focus t :false))
                                               (list :session-id sid :cwd dir))))

(defun harness-tools-dev-test--check ()
  "Run the check; return the sockets it stopped, sorted."
  (sort (harness-test-await (harness-tools-dev--check)) #'string<))

(defun harness-tools-dev-test--sockets (&rest dirs)
  "Return the sockets of DIRS, sorted."
  (sort (mapcar #'harness-tools-dev-socket dirs) #'string<))

(ert-deftest harness-tools-dev-socket-is-stable-and-distinct ()
  "A checkout always opens under the same socket, another under another."
  (harness-tools-dev-test-with
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (should (string-prefix-p "harness-dev-" (harness-tools-dev-socket a)))
      (should (equal (harness-tools-dev-socket a) (harness-tools-dev-socket a)))
      (should-not (equal (harness-tools-dev-socket a) (harness-tools-dev-socket b)))
      (should (string-prefix-p (expand-file-name "scripts/.dev/" a)
                               (harness-tools-dev-state a (harness-tools-dev-socket a)))))))

(ert-deftest harness-tools-dev-checkout-detection ()
  "A checkout is harness.el and scripts/dev.sh side by side."
  (harness-tools-dev-test-with
    (let ((dir (harness-test-harness-checkout))
          (plain (harness-test-temp-dir)))
      (should (harness-tools-dev-checkout-p dir))
      (should (harness-tools-dev-checkout-p harness-test-root))
      (should-not (harness-tools-dev-checkout-p plain))
      (should-not (harness-tools-dev-checkout-p nil))
      (delete-file (expand-file-name "scripts/dev.sh" dir))
      (should-not (harness-tools-dev-checkout-p dir)))))

(ert-deftest harness-tools-dev-tool-is-for-the-sessions-that-name-it ()
  "The tool is this repository's plugin's: the sessions naming it get it.
tools-dev is a plugin module, which the harness did not load from a
directory of its own (`harness-module-plugin-p').  So a session gets
open_harness only when the plugin modules it froze name tools-dev, as
this repository's .dir-locals.el has them do; another session neither
gets it nor may call it, and the catalogue (no session) lists it.  This
is the harness's rule for every tool of a project's plugin
\(`harness-tools--in-scope-p')."
  (harness-tools-dev-test-world
    (let ((elsewhere (harness-test-temp-dir)))
      (harness-tools-dev-test--session "here" :project harness-test-root :cwd harness-test-root)
      (harness-tools-dev-test--session "elsewhere" :project elsewhere :cwd elsewhere)
      ;; Stands in for the plugins module: the lists the sessions froze.
      (harness-register-method 'plugins/of-session
                               (lambda (id) (and (equal id "here") '(tools-dev))))
      (should (harness-module-plugin-p 'tools-dev))
      (should (member "open_harness" (harness-tools--names (harness-call 'session/get "here"))))
      (should-not (member "open_harness" (harness-tools--names (harness-call 'session/get "elsewhere"))))
      (should (member "open_harness" (harness-tools--names nil)))
      (let ((result (harness-test-await
                     (harness-call 'tools/execute "elsewhere"
                                   (list :id "c1" :name "open_harness" :input (list :path elsewhere))))))
        (should (plist-get result :is-error))
        (should (string-prefix-p "Unknown tool open_harness" (plist-get result :content)))))))

(defun harness-tools-dev-test--checkout (dir)
  "Copy this repository's .dir-locals.el and its plugin to DIR; return DIR.
DIR is made if missing: a checkout of the repository, as far as the
plugin goes, wherever the tests run from."
  (let ((plugin (expand-file-name ".harness/plugins/dev/" dir)))
    (make-directory plugin t)
    (copy-file (expand-file-name ".dir-locals.el" harness-test-root) (expand-file-name ".dir-locals.el" dir) t)
    (dolist (file (directory-files (expand-file-name ".harness/plugins/dev/" harness-test-root) t "\\.el\\'"))
      (copy-file file (expand-file-name (file-name-nondirectory file) plugin) t))
    (file-name-as-directory dir)))

(ert-deftest harness-tools-dev-repository-names-its-plugin ()
  "This repository's .dir-locals.el loads the plugin and names its modules.
Applied as the harness process applies a project's variables, with
its entries trusted as Emacs's `!' trusts them, the `require' loads the
plugin's process half -- modules tools-dev and client-check, plugin
modules, started -- and the sessions of the repository get both.
Untrusted, nothing loads and they get none.  In a checkout nested in
another, such as a task's worktree, which an agent writes, the entries
name both all the same but load nothing: the plugin comes from a main
checkout."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools session agent tools-handin
                       plugins))
      (harness-test-load-module m))
    (let* ((file (expand-file-name ".dir-locals.el" harness-test-root))
           (entries (cdr (assq nil (with-temp-buffer
                                     (insert-file-contents file)
                                     (read (current-buffer))))))
           (main (harness-tools-dev-test--checkout (harness-test-temp-dir)))
           (worktree (harness-tools-dev-test--checkout (expand-file-name ".worktrees/task/" main)))
           (enable-local-variables t)
           (enable-local-eval 'maybe)
           (dir-locals-directory-cache nil)
           (dir-locals-class-alist nil))
      (should (equal '(tools-dev client-check) (cdr (assq 'harness-plugin-modules entries))))
      (should (string-search "(require 'harness-dev-plugin" (prin1-to-string (cdr (assq 'eval entries)))))
      (make-directory (expand-file-name ".git" main))
      (with-temp-file (expand-file-name ".git" worktree) (insert "gitdir: " main ".git/worktrees/task\n"))
      ;; As a fresh harness process: neither half has loaded.
      (setq features (cl-set-difference features '(harness-dev-plugin harness-tools-dev
                                                                      harness-client-check)))
      (remhash "open_harness" harness-tools)
      (let ((safe-local-variable-values nil))
        (should-not (harness-plugins--apply main))
        (should-not (featurep 'harness-dev-plugin))
        (should-not (harness-module-get 'tools-dev))
        (should-not (harness-module-get 'client-check))
        (should-not (harness-tool-get "open_harness")))
      (let ((safe-local-variable-values entries))
        (should (equal '(tools-dev client-check) (harness-plugins--apply worktree)))
        (should-not (featurep 'harness-dev-plugin))
        (should-not (featurep 'harness-client-check))
        (should-not (harness-tool-get "open_harness"))
        (should (equal '(tools-dev client-check) (harness-plugins--apply main))))
      (should (featurep 'harness-tools-dev))
      (should (harness-module-plugin-p 'tools-dev))
      (should (harness-module-ready-p 'tools-dev))
      ;; The same plugin brings the hand-in check of the app, its other
      ;; module, which the entries name beside tools-dev: the harness's
      ;; hand_in consults it for the sessions that name it, those of this
      ;; repository (harness-client-check-test.el).
      (should (featurep 'harness-client-check))
      (should (harness-module-plugin-p 'client-check))
      (should (harness-module-ready-p 'client-check))
      (should (cl-find #'harness-client-check--before-hand-in
                       (gethash 'task/before-hand-in harness--filters) :key #'cdr))
      (should (harness-tool-get "open_harness"))
      (should (eq 'tools-dev (harness-tool-module (harness-tool-get "open_harness")))))))

(ert-deftest harness-tools-dev-repository-sessions-are-asked-for-the-apps-build-check ()
  "A session in this repository's checkout names client-check; one elsewhere does not.
The hand-in check of the Flutter app asks the sessions that name its
module, so the entries the repository's directory-local variables hold,
once trusted, put its sessions in the check's scope and no other session."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools session agent tools-handin
                       plugins))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (let* ((file (expand-file-name ".dir-locals.el" harness-test-root))
           (entries (cdr (assq nil (with-temp-buffer
                                     (insert-file-contents file)
                                     (read (current-buffer))))))
           (main (harness-tools-dev-test--checkout (harness-test-temp-dir)))
           (elsewhere (harness-test-temp-dir))
           (enable-local-variables t)
           (enable-local-eval 'maybe)
           (dir-locals-directory-cache nil)
           (dir-locals-class-alist nil)
           (safe-local-variable-values entries))
      (make-directory (expand-file-name ".git" main))
      (let ((here (plist-get (harness-call 'session/create :cwd main :model "demo:scripted") :id))
            (there (plist-get (harness-call 'session/create :cwd elsewhere :model "demo:scripted")
                              :id)))
        (should (equal '(tools-dev client-check) (harness-call 'plugins/of-session here)))
        (should-not (harness-call 'plugins/of-session there))
        (should (harness-client-check--in-scope-p (list :id here)))
        (should-not (harness-client-check--in-scope-p (list :id there)))))))

(ert-deftest harness-tools-dev-plugin-tells-the-harness-of-its-tool ()
  "Loading the plugin tells the harness what its own modules list for theirs.
open_harness holds a slot of the machine as bash does
\(`harness-tool-slots-tools'), and the board reaches `harness-dev/open'
over ACP (`harness-acp-extra-method-prefixes'); the harness's own lists
name it nowhere.  It is not among the tools that need no approval
\(`harness-perms-extra-auto-allow-tools'): it runs the checkout's scripts,
which the agent may have written, outside the sandbox, so the permission
mode decides it as it decides bash."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(project config tools provider perms))
      (harness-test-load-module m))
    (require 'harness-tool-slots)
    (require 'harness-acp)
    (let ((harness-perms-extra-auto-allow-tools nil)
          (harness-tool-slots-tools (eval (car (get 'harness-tool-slots-tools 'standard-value)) t))
          (harness-acp-extra-method-prefixes nil))
      (should-not (member "open_harness" harness-perms--auto-allow-tools))
      (should-not (member "open_harness" harness-tool-slots-tools))
      (should-not (member "harness-dev/" harness-acp-extension-prefixes))
      (harness-test-load-module 'tools-dev)
      (should-not (member "open_harness" harness-perms-extra-auto-allow-tools))
      (should (member "open_harness" harness-tool-slots-tools))
      (should (member "harness-dev/" harness-acp-extra-method-prefixes))
      ;; The mode decides it, as it decides bash: the user is asked in ask
      ;; and accept-edits mode, and only yolo allows it unasked.
      (dolist (case '((ask . ask) (accept-edits . ask) (yolo . allow)))
        (should (eq (cdr case)
                    (plist-get (harness-perms--mode-decision
                                (list :behavior 'ask)
                                (list :session (list :id "s1" :permission-mode (car case))
                                      :tool "open_harness" :kind 'exec))
                               :behavior)))))))

(ert-deftest harness-tools-dev-tool-runs-the-live-loop ()
  "The tool runs the checkout's scripts/dev.sh with its own socket."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (result (harness-test-await (harness-tools-dev--open nil (list :cwd dir)))))
      (should-not (plist-get result :is-error))
      (should (string-match-p (regexp-quote (harness-tools-dev-socket dir))
                              (plist-get result :content)))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 1 (length calls)))
        (should (file-equal-p dir (cdr (assoc "cwd" (car calls)))))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal (harness-tools-dev-socket dir) (cdr (assoc "socket" (car calls)))))
        ;; The instance knows the Emacs it belongs to: here, this one.
        (should (equal (number-to-string (harness-tools-dev--owner))
                       (cdr (assoc "owner" (car calls)))))
        ;; Its state is its own, whatever this Emacs inherited: an
        ;; instance opening another passes its own HARNESS_DEV_STATE on.
        (should (equal (harness-tools-dev-state dir (harness-tools-dev-socket dir))
                       (cdr (assoc "state" (car calls)))))
        ;; Its socket is in the root of the sessions' temporary
        ;; directories, whoever opens it.
        (should (equal (directory-file-name (harness-tools-dev-socket-dir))
                       (cdr (assoc "socket_dir" (car calls)))))
        (should (string-prefix-p (file-name-as-directory (expand-file-name harness-session--tmp-root))
                                 (harness-tools-dev-socket-dir)))
        ;; The result names the socket's file, there.
        (should (string-search (concat "HARNESS_DEV_SOCKET="
                                       (harness-tools-dev-socket-path (harness-tools-dev-socket dir))
                                       " scripts/dev.sh shot")
                               (plist-get result :content))))
      ;; By default the socket's path is short enough for a socket's
      ;; address, which holds about a hundred bytes.
      (let ((harness-session--tmp-root nil))
        (should (< (length (harness-tools-dev-socket-path (harness-tools-dev-socket dir))) 100))))))

(ert-deftest harness-tools-dev-start-reports-launcher-failures ()
  "A silent failure names its exit status or timeout instead of ending in a colon."
  (harness-tools-dev-test-with
    (let ((dir (harness-test-harness-checkout)))
      (dolist (case '(((timeout "" "") . "timed out after")
                      ((7 "" "") . "exit status 7")
                      ((1 "" "frame failed") . "frame failed")))
        (let ((result (car case)))
          (cl-letf (((symbol-function 'harness-tools-dev--probe)
                     (lambda (&rest _) (harness-resolved nil)))
                    ((symbol-function 'harness-tools-dev--run)
                     (lambda (&rest _)
                       (harness-resolved (list :exit (nth 0 result) :stdout (nth 1 result)
                                               :stderr (nth 2 result))))))
            (let ((answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
              (should (plist-get answer :is-error))
              (should (string-search (cdr case) (plist-get answer :content)))
              (should-not (gethash (harness-tools-dev-socket dir) harness-tools-dev--starting)))))))))

(ert-deftest harness-tools-dev-does-not-replace-an-unresponsive-instance ()
  "A timed-out probe aborts before even an older checkout's launcher runs."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (path (harness-tools-dev-socket-path socket))
           (probes nil))
      (harness-tools-dev--make-socket-dir)
      (with-temp-file path)
      (cl-letf (((symbol-function 'harness-run-command)
                 (lambda (command &rest keys)
                   (push (list command keys) probes)
                   (harness-resolved '(:exit timeout :stdout "" :stderr "")))))
        (let ((answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
          (should (plist-get answer :is-error))
          (should (string-search "did not respond" (plist-get answer :content)))
          (should (string-search "Wait and retry" (plist-get answer :content)))
          (should (string-search "restart=true" (plist-get answer :content)))
          (should (string-search "unsaved work" (plist-get answer :content)))
          (should-not (file-exists-p (expand-file-name "invocation.log" dir)))
          (should-not (gethash socket harness-tools-dev--starting))
          (should (= 1 (length probes)))
          (should (equal (concat "./" socket) (nth 4 (caar probes))))
          (should (equal (file-name-directory path) (plist-get (cadar probes) :cwd))))))))

(ert-deftest harness-tools-dev-probe-timeout-is-configurable ()
  "The responsiveness probe uses its custom bound and names it."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (path (harness-tools-dev-socket-path socket))
           (timeout nil))
      (harness-tools-dev--make-socket-dir)
      (with-temp-file path)
      (cl-letf (((symbol-function 'harness-run-command)
                 (lambda (_command &rest keys)
                   (setq timeout (plist-get keys :timeout))
                   (harness-resolved '(:exit timeout :stdout "" :stderr "")))))
        (let* ((harness-tools-dev-probe-timeout 12.5)
               (answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
          (should (plist-get answer :is-error))
          (should (= 12.5 timeout))
          (should (string-search "timed out after 12.5s" (plist-get answer :content)))
          (should (string-search "Wait and retry" (plist-get answer :content))))))))

(ert-deftest harness-tools-dev-refused-socket-with-live-daemon-is-not-stale ()
  "A wedged daemon can refuse connections when its socket backlog fills."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (path (harness-tools-dev-socket-path socket))
           (running (list (list :socket socket :pid 1234)))
           (harness-tools-dev--processes-function (lambda () running))
           (script-ran nil))
      (harness-tools-dev--make-socket-dir)
      (with-temp-file path)
      (cl-letf (((symbol-function 'harness-run-command)
                 (lambda (&rest _) (harness-resolved '(:exit 1 :stdout "" :stderr "Connection refused"))))
                ((symbol-function 'harness-tools-dev--run)
                 (lambda (&rest _) (setq script-ran t) (harness-resolved '(:exit 0 :stdout "" :stderr "")))))
        (dolist (state (list running :unavailable))
          (setq running state)
          (let ((answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
            (should (plist-get answer :is-error))
            (should (string-search "did not respond" (plist-get answer :content)))
            (should (string-search "Wait and retry" (plist-get answer :content)))
            (if (eq state :unavailable)
                (progn
                  (should (string-search "process table is unavailable" (plist-get answer :content)))
                  (should (string-search "remove" (plist-get answer :content)))
                  (should-not (string-search "restart=true" (plist-get answer :content))))
              (should (string-search "restart=true" (plist-get answer :content)))
              (should (string-search "unsaved work" (plist-get answer :content))))
            (should-not script-ran)))
        ;; Only when the process table confirms it is stale may start proceed.
        (setq running nil)
        (should-not (plist-get (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))
                               :is-error))
        (should script-ran)))))

(ert-deftest harness-tools-dev-probes-an-older-instance-by-name ()
  "An older instance can have its socket in Emacs's default directory."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (running (list (list :socket socket :pid 1234)))
           (harness-tools-dev--processes-function (lambda () running))
           (command nil)
           (script-ran nil))
      (should-not (file-exists-p (harness-tools-dev-socket-path socket)))
      (cl-letf (((symbol-function 'harness-run-command)
                 (lambda (args &rest _) (setq command args)
                   (harness-resolved '(:exit timeout :stdout "" :stderr ""))))
                ((symbol-function 'harness-tools-dev--run)
                 (lambda (&rest _) (setq script-ran t) (harness-resolved nil))))
        (dolist (state (list running :unavailable))
          (setq running state)
          (let ((answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
            (should (plist-get answer :is-error))
            (should (string-search "did not respond" (plist-get answer :content)))
            (should (equal socket (cadr (member "-s" command))))
            (should-not script-ran)))
        ;; When the process table is unavailable and no socket file is
        ;; known, a quick failure by name may mean there is no daemon.
        (cl-letf (((symbol-function 'harness-run-command)
                   (lambda (&rest _) (harness-resolved '(:exit 1 :stdout "" :stderr "no socket"))))
                  ((symbol-function 'harness-tools-dev--run)
                   (lambda (&rest _) (setq script-ran t)
                     (harness-resolved '(:exit 0 :stdout "started" :stderr "")))))
          (should-not (plist-get (harness-test-await
                                  (harness-tools-dev--open (list :path dir) (list :cwd dir)))
                                 :is-error))
          (should script-ran))))))

(ert-deftest harness-tools-dev-explicit-restart-preserves-holders ()
  "An explicit restart stops the old instance and keeps its other holders."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "old" :cwd dir :status 'running)
      (harness-tools-dev-test--session "new" :cwd dir :status 'running)
      (should-not (plist-get (harness-tools-dev-test--open dir "old" t) :is-error))
      (let ((answer (harness-test-await
                     (harness-tools-dev--open (list :path dir :restart t)
                                              (list :session-id "new" :cwd dir)))))
        (should-not (plist-get answer :is-error))
        (should (equal (list socket) harness-tools-dev-test--asked))
        (should (= 3 (length (harness-test-dev-invocations dir))))
        (should (equal '("old" "new") (plist-get (harness-tools-dev--find socket) :sessions)))
        (should (plist-get (harness-tools-dev--find socket) :user)))
      ;; It must never kill the harness actually serving this session.
      (let ((harness-tools-dev--own-socket socket))
        (let ((answer (harness-tools-dev--open (list :path dir :restart t) (list :cwd dir))))
          (should (plist-get answer :is-error))
          (should (string-search "this harness runs in" (plist-get answer :content)))))
      (should (= 3 (length (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-restart-refuses-to-start-if-stop-failed ()
  "A daemon still alive after a requested stop is not replaced."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (answer nil))
      (harness-tools-dev-test--session "old" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "old")
      (cl-letf (((symbol-function 'harness-tools-dev--daemon-pids) (lambda (&rest _) '(1234)))
                ((symbol-function 'harness-tools-dev--stop-socket)
                 (lambda (sock &rest _) (harness-tools-dev--forget sock) (harness-resolved nil))))
        (setq answer (harness-test-await
                      (harness-tools-dev--open (list :path dir :restart t) (list :cwd dir)))))
      (should (plist-get answer :is-error))
      (should (string-search "Could not stop" (plist-get answer :content)))
      (should (= 1 (length (harness-test-dev-invocations dir))))
      (should (equal '("old") (plist-get (harness-tools-dev--find socket) :sessions)))
      (should-not (gethash socket harness-tools-dev--starting)))))

(ert-deftest harness-tools-dev-restart-renews-other-holders-links ()
  "The old holders' hard links point to the new socket after a restart."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (fixed (harness-tools-dev-socket-path socket))
           (tmp (lambda (id) (expand-file-name id harness-session--tmp-root)))
           (old-link (expand-file-name socket (funcall tmp "old")))
           (new-link (expand-file-name socket (funcall tmp "new")))
           (inode (lambda (file) (file-attribute-inode-number (file-attributes file)))))
      (harness-register-method 'session/tmp-dir
                               (lambda (id)
                                 (make-directory (funcall tmp id) t)
                                 (funcall tmp id)))
      (dolist (id '("old" "new"))
        (harness-tools-dev-test--session id :cwd dir :status 'running))
      (should-not (plist-get (harness-tools-dev-test--open dir "old") :is-error))
      (let ((old-inode (funcall inode old-link)))
        ;; The replacement has a different inode; the old hard link keeps
        ;; the previous one alive until it is repointed.
        (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                   (lambda (&rest _) (delete-file fixed) (harness-resolved nil))))
          (should-not (plist-get (harness-test-await
                                  (harness-tools-dev--open (list :path dir :restart t)
                                                           (list :session-id "new" :cwd dir)))
                                 :is-error)))
        (should-not (equal old-inode (funcall inode fixed)))
        (should (equal (funcall inode fixed) (funcall inode old-link)))
        (should (equal (funcall inode fixed) (funcall inode new-link)))))))

(ert-deftest harness-tools-dev-restart-waits-for-an-existing-stop-and-keeps-holders ()
  "A stop already in progress must not erase the previous holders."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (gate (harness-make-promise)))
      (harness-tools-dev-test--session "old" :cwd dir :status 'running)
      (harness-tools-dev-test--session "new" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "old" t)
      (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                 (lambda (&rest _) gate)))
        (let* ((stop (harness-call 'harness-dev/stop dir))
               (restart (harness-tools-dev--open (list :path dir :restart t)
                                                  (list :session-id "new" :cwd dir))))
          (should-not (harness-promise-settled-p restart))
          (harness-resolve gate nil)
          (should (harness-test-await stop))
          (should-not (plist-get (harness-test-await restart) :is-error))
          (should (equal '("old" "new") (plist-get (harness-tools-dev--find socket) :sessions)))
          (should (plist-get (harness-tools-dev--find socket) :user)))))))

(ert-deftest harness-tools-dev-open-waits-for-a-restart-to-finish ()
  "Another open cannot run the launcher while an explicit restart runs."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (stop-gate (harness-make-promise))
           (start-gate (harness-make-promise))
           (calls 0))
      (dolist (id '("old" "restart" "other"))
        (harness-tools-dev-test--session id :cwd dir :status 'running))
      (harness-tools-dev-test--open dir "old")
      (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                 (lambda (&rest _) stop-gate))
                ((symbol-function 'harness-tools-dev--probe)
                 (lambda (&rest _) (harness-resolved nil)))
                ((symbol-function 'harness-tools-dev--run)
                 (lambda (&rest _)
                   (cl-incf calls)
                   (if (= calls 1) start-gate
                     (harness-resolved '(:exit 0 :stdout "started" :stderr ""))))))
        (let* ((restart (harness-tools-dev--open (list :path dir :restart t)
                                                  (list :session-id "restart" :cwd dir)))
               (open (harness-tools-dev--open (list :path dir)
                                               (list :session-id "other" :cwd dir))))
          (should-not (harness-promise-settled-p open))
          (should (= 0 calls))
          (harness-resolve stop-gate nil)
          (should (= 1 calls))
          (should-not (harness-promise-settled-p open))
          (harness-resolve start-gate '(:exit 0 :stdout "started" :stderr ""))
          (should-not (plist-get (harness-test-await restart) :is-error))
          (should-not (plist-get (harness-test-await open) :is-error))
          (should (= 2 calls))
          (should (equal '("old" "restart" "other")
                         (plist-get (harness-tools-dev--find socket) :sessions))))))))

(ert-deftest harness-tools-dev-restart-preserves-a-new-holder-if-focus-fails ()
  "A failed focus after startup must not undo the newly recorded holder."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "old" :cwd dir :status 'running)
      (harness-tools-dev-test--session "new" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "old")
      (cl-letf (((symbol-function 'harness-tools-dev--probe)
                 (lambda (&rest _) (harness-resolved nil)))
                ((symbol-function 'harness-tools-dev--run)
                 (lambda (_dir args &rest _)
                   (if (equal (car args) "eval")
                       (harness-rejected '(error "focus failed"))
                     (harness-resolved '(:exit 0 :stdout "started" :stderr ""))))))
        (let ((answer (harness-test-await
                       (harness-tools-dev--open (list :path dir :focus t :restart t)
                                                (list :session-id "new" :cwd dir)))))
          (should (plist-get answer :is-error))
          (should (equal '("old" "new") (plist-get (harness-tools-dev--find socket) :sessions)))
          (should (plist-get (harness-tools-dev--find socket) :user)))))))

(ert-deftest harness-tools-dev-restart-requires-a-process-table ()
  "A restart cannot succeed when it cannot verify the old daemon stopped."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (running nil)
           (harness-tools-dev--processes-function (lambda () running)))
      (harness-tools-dev-test--session "old" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "old")
      ;; Do not touch an instance when its state cannot be checked at all.
      (setq running :unavailable)
      (let ((answer (harness-tools-dev--open (list :path dir :restart t) (list :cwd dir))))
        (should (plist-get answer :is-error))
        (should (string-search "process table unavailable" (plist-get answer :content)))
        (should-not harness-tools-dev-test--asked))
      ;; Nor claim success when the table disappears during the stop.
      (setq running nil)
      (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                 (lambda (&rest _) (setq running :unavailable) (harness-resolved nil))))
        (let ((answer (harness-test-await
                       (harness-tools-dev--open (list :path dir :restart t) (list :cwd dir)))))
          (should (plist-get answer :is-error))
          (should (string-search "process table unavailable" (plist-get answer :content)))))
      (should (= 1 (length (harness-test-dev-invocations dir))))
      (should (equal '("old") (plist-get (harness-tools-dev--find socket) :sessions)))
      (should-not (gethash socket harness-tools-dev--starting)))))

(ert-deftest harness-tools-dev-socket-directory-is-private ()
  "The sockets' directory is private, in a root of the user's own.
A root that is not, as somebody's symbolic link in a shared /tmp would
be, is refused: the socket is then in Emacs's default directory."
  (harness-tools-dev-test-with
    (let* ((base (harness-test-temp-dir))
           (harness-session--tmp-root (expand-file-name "root/" base)))
      (should (equal (harness-tools-dev-socket-dir) (harness-tools-dev--make-socket-dir)))
      (should (= #o700 (file-modes (harness-tools-dev-socket-dir))))
      (should (= #o700 (file-modes harness-session--tmp-root)))
      (let ((harness-session--tmp-root (expand-file-name "link/" base))
            (dir (harness-test-harness-checkout)))
        (make-symbolic-link (expand-file-name "root" base) (directory-file-name harness-session--tmp-root))
        (should-not (harness-tools-dev--make-socket-dir))
        (let ((result (harness-test-await (harness-tools-dev--open nil (list :cwd dir)))))
          (should-not (plist-get result :is-error))
          (should (equal "" (cdr (assoc "socket_dir" (car (harness-test-dev-invocations dir))))))
          (should (string-search (concat "HARNESS_DEV_SOCKET=" (harness-tools-dev-socket dir) " scripts/dev.sh shot")
                                 (plist-get result :content)))))
      (delete-directory base t))))

(ert-deftest harness-tools-dev-links-the-socket-into-the-sessions-directory ()
  "Opening an instance links its socket into the session's temporary directory.
The session's sandboxed shell reaches that directory, and the instance
through the link; the result's commands name the link."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (fixed (harness-tools-dev-socket-path socket))
           (tmp (lambda (id) (file-name-as-directory (expand-file-name id harness-session--tmp-root))))
           (inode (lambda (file) (file-attribute-inode-number (file-attributes file)))))
      ;; Two sessions have a temporary directory, the third none.
      (harness-register-method 'session/tmp-dir
                               (lambda (id)
                                 (when (member id '("s1" "s2"))
                                   (with-file-modes #o700 (make-directory (funcall tmp id) t))
                                   (funcall tmp id))))
      (dolist (id '("s1" "s2" "s3"))
        (harness-tools-dev-test--session id :cwd dir :status 'running))
      (let ((result (harness-tools-dev-test--open dir "s1"))
            (link (expand-file-name socket (funcall tmp "s1"))))
        (should-not (plist-get result :is-error))
        (should (file-exists-p fixed))
        (should (file-exists-p link))
        (should (equal (funcall inode fixed) (funcall inode link)))
        (should (string-search (concat "HARNESS_DEV_SOCKET=" (shell-quote-argument link) " scripts/dev.sh shot")
                               (plist-get result :content)))
        (should (string-search "link in your temporary directory" (plist-get result :content)))
        ;; Another session opening it gets a link of its own.
        (let ((other (expand-file-name socket (funcall tmp "s2"))))
          (should (string-search (concat "HARNESS_DEV_SOCKET=" (shell-quote-argument other))
                                 (plist-get (harness-tools-dev-test--open dir "s2") :content)))
          (should (equal (funcall inode fixed) (funcall inode other))))
        ;; What is left at the link's place, as by an earlier instance,
        ;; gives way.
        (delete-file link)
        (with-temp-file link (insert "an earlier instance's socket\n"))
        (should-not (equal (funcall inode fixed) (funcall inode link)))
        (harness-tools-dev-test--open dir "s1")
        (should (equal (funcall inode fixed) (funcall inode link))))
      ;; A session with no temporary directory is given the socket's file.
      (let ((content (plist-get (harness-tools-dev-test--open dir "s3") :content)))
        (should (string-search (concat "HARNESS_DEV_SOCKET=" (shell-quote-argument fixed) " scripts/dev.sh shot")
                               content))
        (should-not (string-search "link in your temporary directory" content)))
      ;; One opener of them all: the instance is the same.
      (should (equal '("s1" "s2" "s3") (plist-get (harness-tools-dev--find socket) :sessions)))
      (should (equal (list socket) (delete-dups (mapcar (lambda (call) (cdr (assoc "socket" call)))
                                                        (harness-test-dev-invocations dir))))))))

(ert-deftest harness-tools-dev-instances-belong-to-the-users-emacs ()
  "An instance belongs to the Emacs the harness process serves, else this one.
A restart of the harness process alone must not stop the instances."
  (harness-tools-dev-test-with
    (let ((ppid (alist-get 'ppid (process-attributes (emacs-pid)))))
      (skip-unless ppid)
      ;; A harness process: its parent is the Emacs the user runs.
      (let ((process-environment (cons (format "HARNESS_SERVER_PARENT=%d" ppid) process-environment)))
        (should (= ppid (harness-tools-dev--owner))))
      ;; The variable inherited from further up names no parent of ours.
      (let ((process-environment (cons (format "HARNESS_SERVER_PARENT=%d" (1+ ppid)) process-environment)))
        (should (= (emacs-pid) (harness-tools-dev--owner))))
      (let ((process-environment (cons "HARNESS_SERVER_PARENT" process-environment)))
        (should (= (emacs-pid) (harness-tools-dev--owner)))))))

(ert-deftest harness-tools-dev-tool-refuses-other-directories ()
  "A path that is not a harness checkout is an error, before anything runs."
  (harness-tools-dev-test-with
    (let ((plain (harness-test-temp-dir)))
      (let ((result (harness-tools-dev--open (list :path plain) (list :cwd plain))))
        (should (plist-get result :is-error))
        (should (string-match-p "not a checkout" (plist-get result :content)))
        (should-not (file-exists-p (expand-file-name "invocation.log" plain)))))))

(ert-deftest harness-tools-dev-method-opens-a-checkout ()
  "The board's method starts the checkout and returns its info."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir))))
      (should (equal dir (plist-get info :path)))
      (should (equal (harness-tools-dev-socket dir) (plist-get info :socket)))
      (should-not (plist-get info :focused))
      (should (= 1 (length (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-method-focuses-the-frame ()
  "With focus the instance's frame is raised through its own dev loop."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir t))))
      (should (plist-get info :focused))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 2 (length calls)))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal "eval (harness-dev-focus)" (cdr (assoc "args" (cadr calls)))))))))

;;;; Lifetimes

(ert-deftest harness-tools-dev-task-instance-stops-with-the-task ()
  "The instance a task's agent opened stops once the task stops working."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "s1" :worktree dir :cwd dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (let ((result (harness-tools-dev-test--open dir "s1")))
        (should-not (plist-get result :is-error))
        ;; The agent hears when it stops.
        (should (string-match-p "stops by itself once this task stops working"
                                (plist-get result :content))))
      (should (equal '("s1") (plist-get (harness-tools-dev--find socket) :sessions)))
      (should (file-exists-p (harness-tools-dev--registry-path)))
      ;; While the task works, between turns too, it stays.
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "s1" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      ;; In review, it goes.
      (harness-tools-dev-test--set-task "t1" :state 'review)
      (should (equal (list socket) (harness-tools-dev-test--check)))
      (should (equal (list socket) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find socket))
      ;; Forgotten on disk too.
      (setq harness-tools-dev--instances-dir nil)
      (should-not (harness-tools-dev--instances))
      ;; Stopping ran nothing of the checkout's: its dev loop only started it.
      (should (equal '("start") (mapcar (lambda (call) (cdr (assoc "args" call)))
                                        (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-task-instance-stops-when-the-task-stops ()
  "A task stopped by an error or a cancel no longer needs its instance."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (harness-tools-dev-test--open dir "s1")
      (harness-tools-dev-test--session "s1" :status 'idle)
      (harness-tools-dev-test--set-task "t1" :outcome 'cancelled)
      (should (equal (harness-tools-dev-test--sockets dir) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-focused-instance-stays-until-the-task-is-done ()
  "An instance opened for the user to look at stays through review and merge."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (should (string-match-p "stays until the task is done"
                              (plist-get (harness-tools-dev-test--open dir "s1" t) :content)))
      (let ((entry (harness-tools-dev--find socket)))
        (should (plist-get entry :user))
        (should (equal "t1" (plist-get entry :task))))
      (harness-tools-dev-test--session "s1" :status 'idle)
      (dolist (state '(review merging))
        (harness-tools-dev-test--set-task "t1" :state state)
        (should-not (harness-tools-dev-test--check)))
      (harness-tools-dev-test--set-task "t1" :state 'done)
      (should (equal (list socket) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-board-instance-stays-until-the-task-goes ()
  "The board's Open harness lasts until its task is done, archived or deleted."
  (harness-tools-dev-test-world
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (harness-tools-dev-test--set-task "ta" :state 'review :worktree a)
      (harness-tools-dev-test--set-task "tb" :state 'review :worktree b)
      (harness-test-await (harness-call 'harness-dev/open a t))
      (harness-test-await (harness-call 'harness-dev/open b t))
      (should (equal "ta" (plist-get (harness-tools-dev--find (harness-tools-dev-socket a)) :task)))
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--set-task "ta" :archived t)
      (should (equal (harness-tools-dev-test--sockets a) (harness-tools-dev-test--check)))
      (setq harness-tools-dev-test--tasks (remove (harness-tools-dev-test--task "tb")
                                                  harness-tools-dev-test--tasks))
      (should (equal (harness-tools-dev-test--sockets b) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-subagent-instance-stops-with-its-work ()
  "A sub-agent's instance goes with its work, unless its task works in the same checkout."
  (harness-tools-dev-test-world
    (let ((own (harness-test-harness-checkout))
          (shared (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "parent" :worktree shared :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "parent" :worktree shared)
      ;; One sub-agent in a worktree of its own, one in its task's.
      (harness-tools-dev-test--session "c1" :kind 'subagent :parent-id "parent"
                                       :worktree own :cwd own :status 'running)
      (harness-tools-dev-test--session "c2" :kind 'subagent :parent-id "parent"
                                       :cwd shared :status 'running)
      (should (string-match-p "once your work is done"
                              (plist-get (harness-tools-dev-test--open own "c1") :content)))
      (harness-tools-dev-test--open shared "c2")
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "c1" :status 'idle)
      (harness-tools-dev-test--session "c2" :status 'idle)
      (should (equal (harness-tools-dev-test--sockets own) (harness-tools-dev-test--check)))
      ;; The task still works in the shared checkout, between its turns too.
      (harness-tools-dev-test--session "parent" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--set-task "t1" :state 'done)
      (should (equal (harness-tools-dev-test--sockets shared) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-conversation-instance-stays-while-it-goes-on ()
  "A conversation's instance stays until it is closed or long idle."
  (harness-tools-dev-test-world
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "talk" :cwd a :status 'running)
      (harness-tools-dev-test--session "other" :cwd b :status 'running)
      (should (string-match-p "once this session is closed"
                              (plist-get (harness-tools-dev-test--open a "talk") :content)))
      (harness-tools-dev-test--open b "other")
      (harness-tools-dev-test--session "talk" :status 'idle)
      (harness-tools-dev-test--session "other" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "talk" :status 'inactive)
      (harness-tools-dev-test--session "other" :updated (- (float-time) harness-tools-dev--idle-timeout 1))
      (should (equal (harness-tools-dev-test--sockets a b) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-instance-of-a-removed-checkout-stops ()
  "An instance whose checkout is gone stops, needed or not."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (delete-directory dir t)
      (should (equal (list socket) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-events-start-the-check ()
  "A task going to review stops its agent's instance a moment later."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (stopped nil))
      (harness-on 'harness-dev/stopped (lambda (socket path reason) (push (list socket path reason) stopped)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (harness-tools-dev-test--open dir "s1")
      (harness-tools-dev-test--session "s1" :status 'idle)
      (harness-tools-dev-test--set-task "t1" :state 'review)
      (harness-emit 'task/review (harness-tools-dev-test--task "t1"))
      (harness-test-wait (lambda () stopped) 10 "the instance to stop")
      (should (equal (list (list (harness-tools-dev-socket dir) dir
                                 "the sessions that opened it are done with it"))
                     stopped)))))

(ert-deftest harness-tools-dev-sweep-finds-unrecorded-instances ()
  "The sweep takes on the instances of this harness's worktrees, and no others."
  (harness-tools-dev-test-world
    (let* ((done (harness-test-harness-checkout))
           (working (harness-test-harness-checkout))
           (stranger (harness-test-harness-checkout))
           (gone (harness-test-harness-checkout))
           (exited (harness-test-harness-checkout))
           (running (mapcar (lambda (dir) (list :socket (harness-tools-dev-socket dir) :path dir :pid 0))
                            (list done working stranger gone)))
           ;; An instance asked to exit does.
           (harness-tools-dev--processes-function
            (lambda () (cl-remove-if (lambda (daemon)
                                       (member (plist-get daemon :socket) harness-tools-dev-test--asked))
                                     running))))
      (delete-directory gone t)
      (harness-tools-dev-test--set-task "t-done" :state 'done :worktree done)
      (harness-tools-dev-test--set-task "t-working" :session "s" :worktree working)
      (harness-tools-dev-test--session "s" :worktree working :status 'running)
      ;; One recorded once, which has exited since.
      (harness-tools-dev-test--session "talk" :cwd exited :status 'running)
      (harness-tools-dev-test--open exited "talk")
      (should (equal (harness-tools-dev-test--sockets done gone)
                     (sort (harness-test-await (harness-call 'harness-dev/sweep)) #'string<)))
      (should (plist-get (harness-tools-dev--find (harness-tools-dev-socket working)) :adopted))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket stranger)))
      (should-not (member (harness-tools-dev-socket stranger) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket exited)))
      (should-not (member (harness-tools-dev-socket exited) harness-tools-dev-test--asked))
      ;; What is left is what something needs.
      (should (equal (list (list (harness-tools-dev-socket working) t))
                     (mapcar (lambda (entry) (list (plist-get entry :socket) (plist-get entry :needed)))
                             (harness-call 'harness-dev/instances))))
      ;; Once its task is done, the next sweep stops it too.
      (harness-tools-dev-test--session "s" :status 'idle)
      (harness-tools-dev-test--set-task "t-working" :state 'done)
      (should (equal (harness-tools-dev-test--sockets working)
                     (harness-test-await (harness-call 'harness-dev/sweep)))))))

(ert-deftest harness-tools-dev-worktree-instance-stops-before-removal ()
  "The instance of a worktree stops before the worktree is removed."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (other (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (should (eq 'kept (harness-test-await
                         (harness-run-filter-async 'worktree/before-remove 'kept "/repo/" dir))))
      (should (equal (harness-tools-dev-test--sockets dir) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket dir)))
      ;; Where no instance runs, nothing is asked.
      (should (eq 'kept (harness-test-await
                         (harness-run-filter-async 'worktree/before-remove 'kept "/repo/" other))))
      (should (equal (harness-tools-dev-test--sockets dir) harness-tools-dev-test--asked)))))

(ert-deftest harness-tools-dev-start-waits-for-a-stop ()
  "Opening an instance being stopped starts it again once it has stopped."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (gate (harness-make-promise)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                 (lambda (socket &optional _path) (push socket harness-tools-dev-test--asked) gate)))
        (let ((stop (harness-call 'harness-dev/stop dir))
              (start (harness-tools-dev--open (list :path dir) (list :session-id "talk" :cwd dir))))
          (harness-test-wait (lambda () harness-tools-dev-test--asked) 5 "the stop to begin")
          (sit-for 0.2)
          ;; The dev loop ran for the first open only.
          (should (= 1 (length (harness-test-dev-invocations dir))))
          (harness-resolve gate nil)
          (should (harness-test-await stop))
          (should-not (plist-get (harness-test-await start) :is-error))
          (should (= 2 (length (harness-test-dev-invocations dir))))
          (should (harness-tools-dev--find (harness-tools-dev-socket dir))))))))

(ert-deftest harness-tools-dev-reads-daemon-command-lines ()
  "An instance is told by the command line scripts/dev.sh gives its daemon."
  (should (equal '(:socket "harness-dev-0123456789ab" :path "/w/a b/")
                 (harness-tools-dev--parse-command
                  "emacs -Q --daemon=harness-dev-0123456789ab -l /w/a b/scripts/harness-dev.el")))
  (should (equal '(:socket "harness-dev-0123456789ab" :path nil)
                 (harness-tools-dev--parse-command "emacs --daemon=harness-dev-0123456789ab")))
  ;; The daemon is given its socket's file; the socket is its name still.
  (should (equal '(:socket "harness-dev-0123456789ab" :path "/w/a b/")
                 (harness-tools-dev--parse-command
                  "emacs -Q --daemon=/tmp/harness-1000/.dev/harness-dev-0123456789ab -l /w/a b/scripts/harness-dev.el")))
  ;; The user's own dev daemon, and anything else, is not one.
  (should-not (harness-tools-dev--parse-command "emacs -Q --daemon=harness-v3 -l /w/scripts/harness-dev.el"))
  (should-not (harness-tools-dev--parse-command "emacs -Q --daemon=/x/harness-v3 -l /w/scripts/harness-dev.el"))
  (should-not (harness-tools-dev--parse-command "emacs -Q --daemon=/x/harness-dev-0123456789ab/y -l /w/scripts/harness-dev.el"))
  (should-not (harness-tools-dev--parse-command "emacs --daemon=harness-dev-xyz"))
  (should-not (harness-tools-dev--parse-command "emacs --batch -l harness-server.el"))
  (should-not (harness-tools-dev--parse-command nil)))

(ert-deftest harness-tools-dev-knows-its-own-socket-by-its-file ()
  "An instance tells its own socket from `daemonp', which is the socket's file."
  (harness-tools-dev-test-with
    (dolist (daemon '("/tmp/harness-1000/.dev/harness-dev-0123456789ab" "harness-dev-0123456789ab"))
      (let ((harness-tools-dev--own-socket 'unknown))
        (cl-letf (((symbol-function 'daemonp) (lambda () daemon)))
          (should (equal "harness-dev-0123456789ab" (harness-tools-dev--own-socket))))))))

(ert-deftest harness-tools-dev-own-socket-retries-an-unreadable-parent ()
  "A parent the process table cannot show leaves the answer unfixed.
A later lookup that can read it finds the daemon socket, so a restart
cannot take an unread parent for evidence that this harness is no
instance at all."
  (harness-tools-dev-test-with
    (let ((harness-tools-dev--own-socket 'unknown)
          (parent nil))
      (cl-letf (((symbol-function 'daemonp) #'ignore)
                ((symbol-function 'process-attributes)
                 (lambda (pid)
                   (if (eql pid (emacs-pid)) '((ppid . 4242)) parent))))
        ;; The parent cannot be read: the answer is inconclusive.
        (should-not (harness-tools-dev--own-socket))
        (should (eq harness-tools-dev--own-socket 'unknown))
        ;; Now it can: the lookup is definite and cached.
        (setq parent '((args . "emacs -Q --daemon=harness-dev-0123456789ab")))
        (should (equal "harness-dev-0123456789ab" (harness-tools-dev--own-socket)))
        (should (equal "harness-dev-0123456789ab" harness-tools-dev--own-socket))
        ;; A parent that names no instance is a definite nil.
        (setq harness-tools-dev--own-socket 'unknown
              parent '((args . "emacs -Q")))
        (should-not (harness-tools-dev--own-socket))
        (should-not harness-tools-dev--own-socket)))))

(ert-deftest harness-tools-dev-reaches-an-instance-by-its-sockets-file ()
  "emacsclient is given the socket's file when there is one, else its name.
An instance an older harness started has its socket in Emacs's default
directory, under its name."
  (harness-tools-dev-test-with
    (let* ((harness-session--tmp-root (harness-test-temp-dir))
           (socket "harness-dev-0123456789ab")
           (path (harness-tools-dev-socket-path socket)))
      (should (equal socket (harness-tools-dev--client-socket socket)))
      (harness-tools-dev--make-socket-dir)
      (with-temp-file path)
      (should (equal path (harness-tools-dev--client-socket socket)))
      (delete-directory harness-session--tmp-root t))))

(ert-deftest harness-tools-dev-stops-a-real-daemon ()
  "A daemon started the way scripts/dev.sh starts one is found and stopped."
  (harness-tools-dev-test-with
    (skip-unless (listp (harness-tools-dev-processes)))
    (let* ((dir (harness-test-harness-checkout))
           ;; A temporary checkout's, so no other Emacs runs under it.
           (socket (harness-tools-dev-socket dir))
           (emacs (expand-file-name invocation-name invocation-directory))
           ;; Only the daemon this test starts is ever seen, or stopped.
           (harness-tools-dev--processes-function
            (lambda ()
              (let ((all (harness-tools-dev-processes)))
                (if (listp all)
                    (cl-remove-if-not (lambda (daemon) (equal socket (plist-get daemon :socket))) all)
                  all)))))
      (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
        (insert ";; A dev loop that loads nothing.\n"))
      (unwind-protect
          (progn
            (call-process emacs nil nil nil "-Q" (concat "--daemon=" socket)
                          "-l" (expand-file-name "scripts/harness-dev.el" dir))
            (let ((found (car (harness-test-wait (lambda () (funcall harness-tools-dev--processes-function))
                                                 10 "the daemon to start"))))
              (should (equal dir (plist-get found :path)))
              (should (integerp (plist-get found :pid))))
            (should (harness-test-await (harness-call 'harness-dev/stop dir) 30))
            (should-not (funcall harness-tools-dev--processes-function)))
        (let ((left (funcall harness-tools-dev--processes-function)))
          (when (listp left)
            (dolist (daemon left) (ignore-errors (signal-process (plist-get daemon :pid) 'kill)))))))))

(ert-deftest harness-tools-dev-recovers-a-real-wedged-daemon-on-request ()
  "A real stuck Emacs is diagnosed, then stopped only on explicit restart."
  (harness-tools-dev-test-with
    (skip-unless (listp (harness-tools-dev-processes)))
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir))
           (path (harness-tools-dev-socket-path socket))
           (emacs (expand-file-name invocation-name invocation-directory))
           (harness-tools-dev-probe-timeout 0.5)
           (harness-tools-dev--exit-timeout 0.5)
           (harness-tools-dev--kill-grace 0.1)
           (harness-tools-dev--processes-function
            (lambda ()
              (let ((all (harness-tools-dev-processes)))
                (if (listp all)
                    (cl-remove-if-not (lambda (daemon) (equal socket (plist-get daemon :socket))) all)
                  all)))))
      (skip-unless (< (length path) 100))
      (harness-tools-dev--make-socket-dir)
      (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
        (insert ";; A daemon without a GUI, for this test.\n"))
      ;; The replacement launcher really starts a new daemon under the same socket.
      (with-temp-file (expand-file-name "scripts/dev.sh" dir)
        (insert "#!/bin/sh\nexec " (shell-quote-argument emacs)
                " -Q --daemon=\"$HARNESS_DEV_SOCKET_DIR/$HARNESS_DEV_SOCKET\""
                " -l \"$PWD/scripts/harness-dev.el\"\n"))
      (set-file-modes (expand-file-name "scripts/dev.sh" dir) #o755)
      (unwind-protect
          (progn
            (should (eql 0 (call-process emacs nil nil nil "-Q" (concat "--daemon=" path)
                                         "-l" (expand-file-name "scripts/harness-dev.el" dir))))
            (let* ((old (car (harness-test-wait (lambda () (funcall harness-tools-dev--processes-function))
                                                10 "the test daemon")))
                   (pid (plist-get old :pid)))
              ;; A client timeout does not interrupt the Lisp it started.
              (let ((r (harness-test-await
                        (harness-run-command (list (harness-tools-dev--emacsclient) "-s" path
                                                   "--eval" "(while t)")
                                             :timeout 0.5))))
                (should (eq 'timeout (plist-get r :exit))))
              (let ((answer (harness-test-await (harness-tools-dev--open (list :path dir) (list :cwd dir)))))
                (should (plist-get answer :is-error))
                (should (string-search "did not respond" (plist-get answer :content)))
                (should (member pid (harness-tools-dev--daemon-pids socket))))
              (let ((answer (harness-test-await
                             (harness-tools-dev--open (list :path dir :restart t) (list :cwd dir)) 30)))
                (should-not (plist-get answer :is-error))
                (should-not (member pid (harness-tools-dev--daemon-pids socket)))
                (should (harness-tools-dev--daemon-pids socket))
                (let ((r (harness-test-await (harness-tools-dev--probe dir socket))))
                  (should-not r)))))
        (let ((left (funcall harness-tools-dev--processes-function)))
          (when (listp left)
            (dolist (daemon left) (ignore-errors (signal-process (plist-get daemon :pid) 'kill)))))))))

;;;; The real scripts/dev.sh

(defun harness-tools-dev-test--real-checkout ()
  "Make a checkout of the harness with the real scripts/dev.sh; return it."
  (let* ((dir (harness-test-harness-checkout))
         (script (expand-file-name "scripts/dev.sh" dir)))
    (copy-file (expand-file-name "scripts/dev.sh" harness-test-root) script t)
    (set-file-modes script #o755)
    dir))

(defun harness-tools-dev-test--fake-bin ()
  "Make a directory of fake `emacs' and `emacsclient' programs; return it.
Each appends a line to calls.log there: `emacs STATE ARGS', STATE being
HARNESS_DEV_STATE, and `emacsclient PWD ARGS'.  The fake emacs makes
the file `--daemon=' names when that is a path, as the daemon makes its
socket, and its directory; the fake emacsclient succeeds when the file
its -s names exists, seen from where it runs, as the real one does when
a daemon answers there."
  (let ((bin (harness-test-temp-dir)))
    (with-temp-file (expand-file-name "emacs" bin)
      (insert "#!/bin/sh\n"
              "printf 'emacs %s %s\\n' \"$HARNESS_DEV_STATE\" \"$*\" >> \"$(dirname \"$0\")/calls.log\"\n"
              "for a in \"$@\"; do\n"
              "  case \"$a\" in\n"
              "    --daemon=*/*) s=${a#--daemon=}; mkdir -p \"${s%/*}\"; : > \"$s\" ;;\n"
              "  esac\n"
              "done\n"))
    (with-temp-file (expand-file-name "emacsclient" bin)
      (insert "#!/bin/sh\n"
              "printf 'emacsclient %s %s\\n' \"$PWD\" \"$*\" >> \"$(dirname \"$0\")/calls.log\"\n"
              "s=\n"
              "while [ $# -gt 0 ]; do\n"
              "  case \"$1\" in -s) s=$2; shift ;; esac\n"
              "  shift\n"
              "done\n"
              "[ -n \"$s\" ] && [ -e \"$s\" ]\n"))
    (dolist (program '("emacs" "emacsclient"))
      (set-file-modes (expand-file-name program bin) #o755))
    bin))

(defun harness-tools-dev-test--calls (bin)
  "Return the lines the fake programs in BIN logged, and forget them."
  (let ((log (expand-file-name "calls.log" bin)))
    (prog1 (and (file-exists-p log)
                (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t)))
      (when (file-exists-p log) (delete-file log)))))

(defun harness-tools-dev-test--socket-arg (call)
  "Return the socket emacsclient was given in CALL, a line of calls.log."
  (cadr (member "-s" (split-string call " "))))

(defun harness-tools-dev-test--dev-sh (dir bin env &rest args)
  "Run DIR's scripts/dev.sh with ARGS, the fake programs of BIN first on PATH.
ENV lists VAR=VALUE strings put before the environment.  The variables
scripts/dev.sh reads and ENV does not set are unset: the suite may run
in an agent's sandbox, or in an instance, which set them.  Return
\(EXIT STDOUT STDERR)."
  (let* ((default-directory dir)
         (process-environment
          (append env
                  (list (concat "PATH=" (directory-file-name bin) ":" (getenv "PATH"))
                        "HARNESS_DEV_TIMEOUT=10"
                        "HARNESS_DEV_SOCKET" "HARNESS_DEV_SOCKET_DIR" "HARNESS_DEV_STATE" "HARNESS_SANDBOX")
                  process-environment))
         (err (make-temp-file "harness-dev-sh-stderr-")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process (expand-file-name "scripts/dev.sh" dir) nil (list t err) nil args)))
            (list exit (buffer-string) (with-temp-buffer (insert-file-contents err) (buffer-string)))))
      (delete-file err))))

(ert-deftest harness-tools-dev-dev-sh-finds-the-socket ()
  "scripts/dev.sh puts a named socket in HARNESS_DEV_SOCKET_DIR, or takes a path.
With neither, the name is left to Emacs's default directory, as before."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (sockets (harness-test-temp-dir))
         (name "harness-dev-0123456789ab")
         (path (expand-file-name name sockets))
         (state (expand-file-name (concat "scripts/.dev/state-" name) dir)))
    (unwind-protect
        (progn
          ;; A name and a directory, given with a slash at its end.
          (let ((r (harness-tools-dev-test--dev-sh dir bin (list (concat "HARNESS_DEV_SOCKET=" name)
                                                                 (concat "HARNESS_DEV_SOCKET_DIR=" sockets))
                                                   "start")))
            (should (eql 0 (car r)))
            (should (string-match-p "up, frame ready" (nth 1 r)))
            (should-not (string-search "warning" (nth 2 r))))
          (let* ((calls (harness-tools-dev-test--calls bin))
                 (clients (cl-remove-if-not (lambda (call) (string-prefix-p "emacsclient " call)) calls)))
            ;; The daemon is given the path, and its state is named
            ;; after the socket's name.
            (should (member (format "emacs %s -Q --daemon=%s -l %sscripts/harness-dev.el" state path dir) calls))
            (should clients)
            ;; A missing socket must not let ALTERNATE_EDITOR start an Emacs.
            (should (cl-every (lambda (call) (string-search " -a false -s " call)) clients))
            (should (equal (list path) (delete-dups (mapcar #'harness-tools-dev-test--socket-arg clients)))))
          ;; A path, whatever the directory says.
          (let ((r (harness-tools-dev-test--dev-sh dir bin (list (concat "HARNESS_DEV_SOCKET=" path)
                                                                 "HARNESS_DEV_SOCKET_DIR=/nowhere")
                                                   "status")))
            (should (equal '(0 "running\n") (seq-take r 2))))
          (should (equal (list path) (mapcar #'harness-tools-dev-test--socket-arg
                                             (harness-tools-dev-test--calls bin))))
          ;; A name alone: Emacs's default directory.
          (let ((r (harness-tools-dev-test--dev-sh dir bin (list (concat "HARNESS_DEV_SOCKET=" name)) "status")))
            (should (equal '(1 "not running\n") (seq-take r 2))))
          (should (equal (list name) (mapcar #'harness-tools-dev-test--socket-arg
                                             (harness-tools-dev-test--calls bin))))
          ;; Nothing: the user's own dev daemon.
          (harness-tools-dev-test--dev-sh dir bin nil "status")
          (should (equal '("harness-v3") (mapcar #'harness-tools-dev-test--socket-arg
                                                 (harness-tools-dev-test--calls bin)))))
      (dolist (d (list dir bin sockets)) (delete-directory d t)))))

(ert-deftest harness-tools-dev-dev-sh-reaches-a-long-socket-path ()
  "A socket path too long for a socket's address is reached from its directory.
`shot' sends its PATH absolute, since emacsclient's directory is then
the socket's, which --eval takes for `default-directory'."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (base (harness-test-temp-dir))
         (deep (file-name-as-directory (expand-file-name (make-string 90 ?d) base)))
         (name "harness-dev-0123456789ab")
         (path (expand-file-name name deep)))
    (unwind-protect
        (progn
          (make-directory deep t)
          (with-temp-file path)
          (should (> (length path) 100))
          (let ((r (harness-tools-dev-test--dev-sh dir bin (list (concat "HARNESS_DEV_SOCKET=" path))
                                                   "shot" "rel.png")))
            (should (eql 0 (car r)))
            (should (equal (concat (expand-file-name "rel.png" dir) "\n") (nth 1 r))))
          (let ((calls (harness-tools-dev-test--calls bin)))
            (should (= 1 (length calls)))
            (should (string-prefix-p "emacsclient " (car calls)))
            (should (string-match " -s \\./\\([^ ]+\\) --eval (harness-dev-shot \"\\([^\"]+\\)\")\\'" (car calls)))
            (should (equal name (match-string 1 (car calls))))
            (should (equal (expand-file-name "rel.png" dir) (match-string 2 (car calls))))
            ;; Run from the socket's directory.
            (should (file-equal-p deep (nth 1 (split-string (car calls) " "))))))
      (dolist (d (list dir bin base)) (delete-directory d t)))))

(ert-deftest harness-tools-dev-dev-sh-warns-in-the-sandbox ()
  "In the sandbox, scripts/dev.sh start warns its Emacs ends with the command.
It starts it all the same: one command may start, drive and stop it."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (sockets (harness-test-temp-dir))
         (env (list "HARNESS_SANDBOX=bwrap" "HARNESS_DEV_SOCKET=harness-dev-0123456789ab"
                    (concat "HARNESS_DEV_SOCKET_DIR=" sockets))))
    (unwind-protect
        (let ((r (apply #'harness-tools-dev-test--dev-sh dir bin env '("start"))))
          (should (eql 0 (car r)))
          (should (string-match-p "warning: in the harness sandbox (bwrap) this Emacs ends with the command" (nth 2 r)))
          (should (string-search "open_harness" (nth 2 r)))
          (should (cl-some (lambda (call) (string-prefix-p "emacs " call)) (harness-tools-dev-test--calls bin)))
          ;; Once it runs, nothing to warn about.
          (let ((again (apply #'harness-tools-dev-test--dev-sh dir bin env '("start"))))
            (should (eql 0 (car again)))
            (should (string-match-p "already running" (nth 1 again)))
            (should (equal "" (nth 2 again))))
          (should-not (cl-some (lambda (call) (string-prefix-p "emacs " call)) (harness-tools-dev-test--calls bin))))
      (dolist (d (list dir bin sockets)) (delete-directory d t)))))

(ert-deftest harness-tools-dev-dev-sh-refuses-a-timed-out-probe ()
  "An unresponsive daemon is not declared dead or replaced by another one."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (env '("HARNESS_DEV_SOCKET=harness-dev-0123456789ab"
                "HARNESS_DEV_PROBE_TIMEOUT=0.1")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\nsleep 3\n"))
          (set-file-modes (expand-file-name "emacsclient" bin) #o755)
          (dolist (command '("start" "status" "stop" "restart"))
            (let ((r (harness-tools-dev-test--dev-sh dir bin env command)))
              (should-not (eql 0 (car r)))
              (should (string-search "did not respond" (nth 2 r)))
              (should (string-search "unsaved work" (nth 2 r)))
              (should-not (string-search "not running" (nth 1 r)))
              (should-not (harness-tools-dev-test--calls bin)))))
      (dolist (d (list dir bin)) (delete-directory d t)))))

(ert-deftest harness-tools-dev-dev-sh-refuses-a-refused-live-daemon ()
  "A live daemon whose socket refuses connections is not replaced.
The daemon is real; its socket is moved and a plain file left where
emacsclient looks, so the refusal is real too.  `start' must diagnose
it rather than launch another Emacs, and `status' must not call it
gone."
  (skip-unless (listp (harness-tools-dev-processes)))
  (skip-unless (executable-find "emacsclient"))
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (sockets (harness-test-temp-dir))
         (name "harness-dev-0123456789ab")
         (path (expand-file-name name sockets))
         (emacs (expand-file-name invocation-name invocation-directory))
         (env (list (concat "HARNESS_DEV_SOCKET=" name)
                    (concat "HARNESS_DEV_SOCKET_DIR=" sockets)
                    "HARNESS_DEV_PROBE_TIMEOUT=1")))
    (unwind-protect
        (progn
          (make-directory sockets t)
          (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
            (insert ";; A daemon for the refused-socket test.\n"))
          (should (eql 0 (call-process emacs nil nil nil "-Q"
                                      (concat "--daemon=" path)
                                      "-l" (expand-file-name "scripts/harness-dev.el" dir))))
          (harness-test-wait (lambda () (file-exists-p path)) 10 "the daemon socket")
          (let ((daemon (car (harness-test-wait
                              (lambda ()
                                (let ((all (harness-tools-dev-processes)))
                                  (and (listp all)
                                       (seq-filter (lambda (d) (equal name (plist-get d :socket))) all))))
                              10 "the daemon to show in the process table"))))
            (should (integerp (plist-get daemon :pid))))
          ;; The daemon keeps listening on the moved file; a plain file
          ;; where emacsclient looks makes it refuse the connection.
          (rename-file path (concat path ".moved"))
          (with-temp-file path (insert "not a socket\n"))
          ;; Real emacsclient; the fake emacs records any second start.
          (delete-file (expand-file-name "emacsclient" bin))
          (make-symbolic-link (executable-find "emacsclient")
                              (expand-file-name "emacsclient" bin))
          (let ((status (apply #'harness-tools-dev-test--dev-sh dir bin env '("status"))))
            (should-not (eql 0 (car status)))
            (should-not (string-search "not running" (nth 1 status)))
            (should (string-search "did not respond" (nth 2 status)))
            (should (string-search "connections refused" (nth 2 status))))
          (let ((start (apply #'harness-tools-dev-test--dev-sh dir bin env '("start"))))
            (should-not (eql 0 (car start)))
            (should-not (string-search "up, frame ready" (nth 1 start)))
            (should (string-search "did not respond" (nth 2 start)))
            (should-not (cl-some (lambda (call) (string-prefix-p "emacs " call))
                                 (harness-tools-dev-test--calls bin)))))
      (let ((all (ignore-errors (harness-tools-dev-processes))))
        (when (listp all)
          (dolist (daemon all)
            (when (equal name (plist-get daemon :socket))
              (ignore-errors (signal-process (plist-get daemon :pid) 'kill))))))
      (dolist (d (list dir bin sockets)) (ignore-errors (delete-directory d t))))))

(ert-deftest harness-tools-dev-dev-sh-sees-a-daemon-named-by-its-socket ()
  "A bare `--daemon=NAME`, as an older dev.sh starts it, is found alive.
The socket is in Emacs's default directory then, and a refused
connection must not let start launch a second daemon."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (name "harness-dev-0123456789ab")
         (env (list (concat "HARNESS_DEV_SOCKET=" name)
                    "HARNESS_DEV_PROBE_TIMEOUT=1")))
    (unwind-protect
        (progn
          ;; emacsclient refuses, while ps names a daemon under the socket.
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\nexit 1\n"))
          (with-temp-file (expand-file-name "ps" bin)
            (insert "#!/bin/sh\necho 'emacs -Q --daemon=" name
                    " -l /x/scripts/harness-dev.el'\n"))
          (dolist (program '("emacsclient" "ps"))
            (set-file-modes (expand-file-name program bin) #o755))
          (let ((status (apply #'harness-tools-dev-test--dev-sh dir bin env '("status"))))
            (should-not (eql 0 (car status)))
            (should-not (string-search "not running" (nth 1 status)))
            (should (string-search "connections refused" (nth 2 status))))
          (let ((start (apply #'harness-tools-dev-test--dev-sh dir bin env '("start"))))
            (should-not (eql 0 (car start)))
            (should (string-search "did not respond" (nth 2 start)))
            (should-not (cl-some (lambda (call) (string-prefix-p "emacs " call))
                                 (harness-tools-dev-test--calls bin)))))
      (dolist (d (list dir bin)) (delete-directory d t)))))

(ert-deftest harness-tools-dev-dev-sh-frame-failure-is-visible ()
  "An error from creating the frame is not silently reported as failure."
  (let* ((dir (harness-tools-dev-test--real-checkout))
         (bin (harness-tools-dev-test--fake-bin))
         (sockets (harness-test-temp-dir))
         (env (list "HARNESS_DEV_SOCKET=harness-dev-0123456789ab"
                    (concat "HARNESS_DEV_SOCKET_DIR=" sockets))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\n"
                    "case \"$*\" in *harness-dev-frame*) echo 'display cannot be opened' >&2; exit 1 ;; esac\n"
                    "while [ $# -gt 0 ]; do\n"
                    "  if [ \"$1\" = -s ]; then [ -e \"$2\" ]; exit; fi\n"
                    "  shift\n"
                    "done\nexit 1\n"))
          (set-file-modes (expand-file-name "emacsclient" bin) #o755)
          (let ((r (harness-tools-dev-test--dev-sh dir bin env "start")))
            (should-not (eql 0 (car r)))
            (should (string-search "display cannot be opened" (nth 2 r)))
            (should (string-search "could not create its frame" (nth 2 r)))))
      (dolist (d (list dir bin sockets)) (delete-directory d t)))))

;;;; From the sandbox

(ert-deftest harness-tools-dev-sandboxed-shell-drives-the-instance ()
  "An agent's sandboxed shell drives the instance its session opened, by the link.
A real daemon, started by the real scripts/dev.sh as the tool starts
it, is driven from the real bwrap: there the sockets' directory is out
of sight, and the link in the session's temporary directory reaches the
daemon."
  (harness-tools-dev-test-with
    (dolist (m '(project config sandbox))
      (harness-test-load-module m))
    (harness-sandbox-detect)
    (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
    (skip-unless (and (executable-find "emacs") (executable-find "emacsclient")))
    (let* ((dir (harness-tools-dev-test--real-checkout))
           (socket (harness-tools-dev-socket dir))
           (fixed (harness-tools-dev-socket-path socket))
           (tmp (file-name-as-directory (expand-file-name "s1" harness-session--tmp-root)))
           (harness-sandbox-policy 'required)
           (asked nil)
           ;; Only the daemon this test starts is ever seen, or stopped.
           (harness-tools-dev--processes-function
            (lambda ()
              (let ((all (harness-tools-dev-processes)))
                (if (listp all)
                    (cl-remove-if-not (lambda (daemon) (equal socket (plist-get daemon :socket))) all)
                  all)))))
      (unwind-protect
          (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap dir '("true"))
                                                           :cwd dir :timeout 20))))
            (unless (eql 0 (plist-get probe :exit))
              (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
            (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
              (insert ";; The dev loop of a daemon with no display: no frame.\n"
                      "(defun harness-dev-frame () t)\n"))
            (with-file-modes #o700 (make-directory tmp t))
            (harness-register-method 'session/exists-p (lambda (id) (equal id "s1")))
            (harness-register-method 'session/get
                                     (lambda (id)
                                       (if (equal id "s1")
                                           (list :id "s1" :cwd dir :status 'running :kind 'main
                                                 :updated (float-time))
                                         (error "No session %s" id))))
            (harness-register-method 'session/tmp-dir (lambda (id) (and (equal id "s1") tmp)))
            (unwind-protect
                (let* ((info (harness-test-await (harness-tools-dev-start dir nil (list :session "s1")) 90))
                       (link (plist-get info :link))
                       (drive (lambda (socket command)
                                (harness-test-await
                                 (harness-run-command
                                  (harness-call 'sandbox/wrap dir
                                                (list "bash" "-c"
                                                      (format "HARNESS_DEV_SOCKET=%s scripts/dev.sh %s"
                                                              (shell-quote-argument socket) command))
                                                :writable (list tmp))
                                  :cwd dir :timeout 60)
                                 70))))
                  (should (file-exists-p fixed))
                  (should (equal (expand-file-name socket tmp) link))
                  ;; Through the link, the daemon answers.
                  (let ((r (funcall drive link "eval '(+ 1 2)'")))
                    (should (equal "3" (string-trim (plist-get r :stdout))))
                    (should (eql 0 (plist-get r :exit))))
                  ;; Its socket's own file is out of the sandbox's sight.
                  (let ((r (funcall drive fixed "status")))
                    (should (equal "not running" (string-trim (plist-get r :stdout))))
                    (should (eql 1 (plist-get r :exit)))))
              ;; The stop the harness makes, then whatever it takes.
              (let ((ask (symbol-function 'harness-tools-dev--ask-to-exit)))
                (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                           (lambda (socket &optional path)
                             (harness-then (funcall ask socket path) (lambda (r) (setq asked r) r)))))
                  (ignore-errors (harness-test-await (harness-call 'harness-dev/stop dir) 30))))
              (unless (eql 0 (plist-get asked :exit))
                (call-process "emacsclient" nil nil nil "-a" "false" "-s" fixed "--eval" "(kill-emacs)"))
              (ignore-errors (harness-test-wait (lambda () (not (file-exists-p fixed))) 15 "the socket to go"))
              (let ((left (funcall harness-tools-dev--processes-function)))
                (when (listp left)
                  (dolist (daemon left) (ignore-errors (signal-process (plist-get daemon :pid) 'kill))))))
            ;; The harness asked the daemon to exit, through the socket's
            ;; file, and it went, its socket with it.
            (should (eql 0 (plist-get asked :exit)))
            (should-not (file-exists-p fixed)))
        (delete-directory dir t)))))

(ert-deftest harness-tools-dev-stops-a-daemon-through-the-socket-in-its-checkout ()
  "A daemon whose socket is in its checkout, where scripts/dev.sh puts it,
is asked to exit through that socket, not killed: emacsclient names it
from the checkout, as its whole name is longer than a Unix socket's."
  (harness-tools-dev-test-with
    (skip-unless (listp (harness-tools-dev-processes)))
    (skip-unless (file-directory-p (format "/proc/%d/cwd" (emacs-pid))))
    (let* ((long (expand-file-name (concat (make-string 90 ?x) "/checkout/") (harness-test-temp-dir)))
           (dir (progn (make-directory (expand-file-name "scripts" long) t) long))
           (socket (harness-tools-dev-socket dir))
           (file (expand-file-name (concat "scripts/.dev/run/" socket) dir))
           (emacs (expand-file-name invocation-name invocation-directory))
           (logged nil)
           (harness-log-hook (list (lambda (level message) (push (cons level message) logged))))
           (harness-tools-dev--processes-function
            (lambda ()
              (let ((all (harness-tools-dev-processes)))
                (if (listp all)
                    (cl-remove-if-not (lambda (daemon) (equal socket (plist-get daemon :socket))) all)
                  all)))))
      (should (> (string-bytes file) 107))
      (with-temp-file (expand-file-name "harness.el" dir) (insert ";; fake harness\n"))
      ;; As the real one does, through its working directory: the
      ;; daemon starts in the checkout.
      (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
        (insert ";;; -*- lexical-binding: t; -*-\n"
                "(setq server-socket-dir (format \"/proc/%d/cwd/scripts/.dev/run/\" (emacs-pid)))\n"))
      (unwind-protect
          (let ((default-directory dir))
            (call-process emacs nil nil nil "-Q" (concat "--daemon=" socket)
                          "-l" (expand-file-name "scripts/harness-dev.el" dir))
            (harness-test-wait (lambda () (funcall harness-tools-dev--processes-function))
                               10 "the daemon to start")
            (should (file-exists-p file))
            (should (harness-test-await (harness-call 'harness-dev/stop dir) 30))
            (should-not (funcall harness-tools-dev--processes-function))
            ;; It exited when asked: its server took its socket away, and
            ;; nothing had to kill it.
            (should-not (file-exists-p file))
            (should-not (cl-some (lambda (entry) (string-match-p "did not exit" (cdr entry))) logged)))
        (let ((left (funcall harness-tools-dev--processes-function)))
          (when (listp left)
            (dolist (daemon left) (ignore-errors (signal-process (plist-get daemon :pid) 'kill)))))))))

(provide 'harness-tools-dev-test)
;;; harness-tools-dev-test.el ends here
