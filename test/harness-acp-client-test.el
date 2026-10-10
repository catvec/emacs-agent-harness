;;; harness-acp-client-test.el --- End-to-end ACP tests with a real third-party client  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the harness's ACP server with a real, external client: a
;; Node process built on the official third-party ACP TypeScript SDK
;; (`@agentclientprotocol/sdk'), the client library Zed-class clients
;; use.  The client (`test/harness-acp-client.mjs') speaks the real
;; wire protocol over stdio to `scripts/harness-acp-stdio', which
;; bridges to a harness run as its own hermetic `emacs --batch' process
;; (the production entry point, `harness-server-main').
;;
;; The suite skips when `node' or the SDK is absent.  Install the SDK
;; in CI with
;;
;;   npm install --no-save @agentclientprotocol/sdk@0.21.0
;;
;; in the repository root, or point HARNESS_ACP_SDK at a node_modules
;; directory (or the package directory itself).

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp-client-test-state)
(defvar harness-acp-client-test-token)
(defvar harness-acp-client-test-project-a)
(defvar harness-acp-client-test-project-b)
(defvar harness-acp-client-test-server)
(defvar harness-acp-client-test-server-stderr)

(defun harness-acp-client-test-driver ()
  "Return the path of the Node ACP client driver."
  (expand-file-name "harness-acp-client.mjs" (expand-file-name "test" harness-test-root)))

(defun harness-acp-client-test-bridge ()
  "Return the path of the stdio bridge the client spawns."
  (expand-file-name "scripts/harness-acp-stdio" harness-test-root))

(defun harness-acp-client-test-sdk-p ()
  "Non-nil when the Node client can find the ACP SDK."
  (let ((process-environment process-environment))
    (eq 0 (call-process "node" nil nil nil (harness-acp-client-test-driver) "--probe"))))

(defun harness-acp-client-test-file-text (file)
  "Return FILE's contents, or \"\"."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    (error "")))

(defun harness-acp-client-test-env (entries)
  "Return `process-environment' with ENTRIES first and their names gone elsewhere."
  (let ((names (mapcar (lambda (e) (substring e 0 (string-match "=" e))) entries)))
    (append entries
            (cl-remove-if (lambda (e)
                            (let ((eq (string-match "=" e)))
                              (and eq (member (substring e 0 eq) names))))
                          process-environment))))

(defmacro harness-acp-client-test-with-server (&rest body)
  "Start a hermetic harness process, run BODY with it, then clean up.
Binds `harness-acp-client-test-state', `-token', `-project-a',
`-project-b', `-server' and `-server-stderr'."
  (declare (indent 0))
  `(let* ((tmp (file-name-as-directory (make-temp-file "harness-acp-client-" t)))
          (state (file-name-as-directory (expand-file-name "state" tmp)))
          (home (file-name-as-directory (expand-file-name "home" tmp)))
          (project-a (file-name-as-directory (expand-file-name "project-a" tmp)))
          (project-b (file-name-as-directory (expand-file-name "project-b" tmp)))
          (config (expand-file-name "server-config.el" tmp))
          (token "acp-client-test-token")
          (address-file (expand-file-name "acp-address" state))
          (out (generate-new-buffer " *harness-acp-client-server-out*"))
          (stderr (generate-new-buffer " *harness-acp-client-server-err*")))
     (make-directory state t)
     (make-directory home t)
     (make-directory project-a t)
     (make-directory project-b t)
     (with-temp-file config
       (insert (concat
                "(setq harness-state-directory " (prin1-to-string state) ")\n"
                "(setq harness-enabled-modules '(store project config provider provider-demo\n"
                "                                 tools tools-fs perms session agent acp\n"
                "                                 priority tasks insights))\n"
                "(setq harness-policy-file nil)\n"
                "(setq harness-model \"demo:scripted\")\n"
                "(setq harness-naming-auto nil)\n"
                "(setq harness-tasks-max-running 0)\n"
                "(setq harness-tasks-store-in-repository nil)\n")))
     (let* ((default-directory harness-test-root)
            (emacs (expand-file-name invocation-name invocation-directory))
            (process-environment
             (harness-acp-client-test-env
              (list (concat "HARNESS_SERVER_CONFIG=" config)
                    (concat "HARNESS_SERVER_TOKEN=" token)
                    (concat "HARNESS_SERVER_PARENT=" (number-to-string (emacs-pid)))
                    (concat "HOME=" home))))
            (proc (make-process
                   :name "harness-acp-client-server"
                   :command (list emacs "-Q" "--batch"
                                  "-L" (expand-file-name "lisp" harness-test-root)
                                  "-L" (expand-file-name "lisp/modules" harness-test-root)
                                  "-L" harness-test-root
                                  "-l" "harness.el"
                                  "-l" "lisp/harness-server.el"
                                  "--eval" "(harness-server-main)")
                   :buffer out
                   :stderr stderr
                   :coding 'utf-8-unix
                   :noquery t)))
       (unwind-protect
           (progn
             (harness-test-wait
              (lambda () (and (file-exists-p address-file)
                              (not (string-empty-p (harness-acp-client-test-file-text address-file)))))
              300 "harness server address file")
             (let ((harness-acp-client-test-state state)
                   (harness-acp-client-test-token token)
                   (harness-acp-client-test-project-a project-a)
                   (harness-acp-client-test-project-b project-b)
                   (harness-acp-client-test-server proc)
                   (harness-acp-client-test-server-stderr stderr))
               ,@body))
         (when (process-live-p proc)
           (delete-process proc))
         (kill-buffer stderr)
         (kill-buffer out)
         (ignore-errors (delete-directory tmp t))))))

(defun harness-acp-client-test-run (scenario)
  "Run the client for SCENARIO against the running harness; return a run plist."
  (let* ((default-directory harness-test-root)
         (out (generate-new-buffer " *acp-client-out*"))
         (err (generate-new-buffer " *acp-client-err*"))
         (process-environment
          (harness-acp-client-test-env
           (list (concat "HARNESS_STATE_DIR=" harness-acp-client-test-state)
                 (concat "HARNESS_ACP_TOKEN=" harness-acp-client-test-token))))
         (proc (make-process
                :name (format "harness-acp-client-%s" scenario)
                :buffer out
                :stderr err
                :coding 'utf-8-unix
                :noquery t
                :command (list "node" (harness-acp-client-test-driver)
                               "--scenario" (symbol-name scenario)
                               "--agent" (harness-acp-client-test-bridge)
                               "--project-a" harness-acp-client-test-project-a
                               "--project-b" harness-acp-client-test-project-b
                               "--timeout" "60"))))
    (harness-test-wait (lambda () (not (process-live-p proc))) 150
                       (format "ACP client %s" scenario))
    (unless (not (process-live-p proc))
      (delete-process proc))
    (let ((status (process-exit-status proc))
          (stdout (with-current-buffer out (buffer-string)))
          (stderr (with-current-buffer err (buffer-string))))
      (kill-buffer out)
      (kill-buffer err)
      (list :status status :stdout stdout :stderr stderr))))

(defun harness-acp-client-test-fail (run format &rest args)
  "Fail with FORMAT plus RUN's output."
  (ert-fail
   (format "%s\n--- client stdout ---\n%s\n--- client stderr ---\n%s"
           (apply #'format format args)
           (plist-get run :stdout)
           (plist-get run :stderr))))

(defun harness-acp-client-test-report (scenario)
  "Run SCENARIO and return its parsed report plist."
  (let ((run (harness-acp-client-test-run scenario)))
    (unless (eq 0 (plist-get run :status))
      (harness-acp-client-test-fail run "client %s failed (status %S)"
                                    scenario (plist-get run :status)))
    (or (let ((stdout (plist-get run :stdout)))
          (when (string-match "HARNESS-ACP-CLIENT-REPORT \\([^\n]*\\)" stdout)
            (condition-case nil
                (harness-json-parse (match-string 1 stdout))
              (error nil))))
        (harness-acp-client-test-fail run "client %s produced no report" scenario))))

(defun harness-acp-client-test-update (updates kind &optional node-id)
  "Return the first update in UPDATES with KIND, and NODE-ID when given."
  (cl-find-if (lambda (u)
                (and (equal kind (plist-get u :kind))
                     (or (null node-id) (equal node-id (plist-get u :nodeId)))))
              updates))

(ert-deftest harness-acp-client-real-sessions ()
  "A real third-party ACP client drives the harness over stdio."
  (skip-unless (executable-find "node"))
  (skip-unless (harness-acp-client-test-sdk-p))
  (harness-acp-client-test-with-server
    ;; The hermetic state directory is the only place the server wrote.
    (should (file-exists-p (expand-file-name "acp-address" harness-acp-client-test-state)))

    ;; Handshake over the real wire.
    (let* ((report (harness-acp-client-test-report 'smoke))
           (init (plist-get report :init)))
      (should (eq t (plist-get report :ok)))
      (should (= 1 (plist-get init :protocolVersion)))
      (should (equal "emacs-agent-harness" (plist-get init :agentInfoName)))
      (should (eq t (plist-get init :loadSession)))
      (should (member "session/list" (plist-get init :methods)))
      (should (equal "end_turn" (plist-get report :stopReason))))

    ;; The two virtual sessions are advertised, and the project list
    ;; refreshes by rewriting its first message in place.
    (let* ((report (harness-acp-client-test-report 'virtual))
           (listed (plist-get report :listed))
           (projects (cl-find "harness:projects" listed
                              :key (lambda (s) (plist-get s :sessionId)) :test #'equal))
           (new-task (cl-find "harness:new-task" listed
                              :key (lambda (s) (plist-get s :sessionId)) :test #'equal)))
      (should (eq t (plist-get report :ok)))
      (should projects)
      (should new-task)
      (should (equal "Projects" (plist-get projects :title)))
      (should (equal "New task" (plist-get new-task :title)))
      (should (stringp (plist-get projects :cwd)))
      (should (stringp (plist-get new-task :cwd)))
      (let* ((load (harness-acp-client-test-update (plist-get report :loadUpdates) "user_message_chunk"))
             (node-id (plist-get load :nodeId))
             (before (plist-get load :text)))
        (should load)
        (should (stringp node-id))
        (should (string-match-p (regexp-quote (file-name-as-directory harness-acp-client-test-project-a))
                                before))
        (should-not (string-match-p (regexp-quote (file-name-as-directory harness-acp-client-test-project-b))
                                    before))
        (let ((refreshed (cl-find-if
                          (lambda (u)
                            (and (equal "user_message_chunk" (plist-get u :kind))
                                 (equal node-id (plist-get u :nodeId))
                                 (not (equal before (plist-get u :text)))))
                          (plist-get report :refreshUpdates))))
          (should refreshed)
          (should (string-match-p (regexp-quote (file-name-as-directory harness-acp-client-test-project-b))
                                  (plist-get refreshed :text))))))

    ;; The new-task session's chat input submits a task for its project.
    (let* ((report (harness-acp-client-test-report 'task))
           (tasks (plist-get report :tasks))
           (task (cl-find (plist-get report :prompt) tasks
                          :key (lambda (item) (plist-get item :prompt)) :test #'equal)))
      (should (eq t (plist-get report :ok)))
      (should (equal "end_turn" (plist-get report :stopReason)))
      (should task)
      (should (equal (file-name-as-directory harness-acp-client-test-project-a)
                     (plist-get task :cwd)))
      (should (equal "pending" (plist-get task :state))))

    ;; The server stops with the test.
    (delete-process harness-acp-client-test-server)
    (harness-test-wait (lambda () (not (process-live-p harness-acp-client-test-server)))
                       30 "harness server to stop")
    (should-not (process-live-p harness-acp-client-test-server))))

(provide 'harness-acp-client-test)
;;; harness-acp-client-test.el ends here
