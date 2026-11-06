;;; harness-container-runtime-test.el --- Container runtime tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; The container runtime is the seam between a stack and the daemon it
;; runs on.  These tests hold the registry, the automatic order, the
;; explicit choice that never falls back, the socket discovery and the
;; exact copy of the runtimes page.  Every process is stubbed: nothing
;; here starts a container or needs docker or podman installed.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-container-runtime)

(defvar harness-container-runtimes)
(defvar harness-container-runtime--available)
(defvar harness-container-runtime--socket-paths)

(defmacro harness-container-runtime-test--runtimes (&rest body)
  "Run BODY with an empty runtime registry and no DOCKER_HOST."
  (declare (indent 0))
  `(let* ((harness-container-runtimes (make-hash-table :test 'eq))
          (harness-container-runtime--available (make-hash-table :test 'eq))
          (harness-container-runtime--socket-paths nil)
          (harness-container-runtime 'auto)
          (docker-host (getenv "DOCKER_HOST")))
     (unwind-protect
         (progn
           (setenv "DOCKER_HOST" nil)
           ,@body)
       (setenv "DOCKER_HOST" docker-host))))

(ert-deftest harness-container-runtime-bundled-backends ()
  "Docker and Podman are declared, and Podman needs no socket."
  (let ((docker (harness-container-runtime-get 'docker))
        (podman (harness-container-runtime-get 'podman)))
    (should (equal "Docker" (plist-get docker :label)))
    (should (equal '("docker") (plist-get docker :command)))
    (should (equal '("docker" "compose") (plist-get docker :compose)))
    (should (equal "/var/run/docker.sock" (plist-get docker :socket)))
    (should (equal '(executable "docker") (car (plist-get docker :needs))))
    (should (equal "Podman" (plist-get podman :label)))
    (should (equal '("podman") (plist-get podman :command)))
    (should (equal '("podman" "compose") (plist-get podman :compose)))
    (should-not (plist-get podman :socket))))

(ert-deftest harness-container-runtime-registry ()
  "A backend is registered once, replaced by a second definition, and listed by label."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'alpha
      :label "Alpha" :command '("alpha") :compose '("alpha" "compose"))
    (harness-define-container-runtime 'beta
      :label "Beta" :command '("beta") :compose '("beta" "compose"))
    (should (equal '(alpha beta) (harness-container-runtime-ids)))
    (should (equal "Beta" (harness-container-runtime-label 'beta)))
    (should (equal '("alpha") (harness-container-runtime-command 'alpha)))
    (should (equal '("alpha" "compose")
                   (harness-container-runtime-compose-command 'alpha)))
    (harness-define-container-runtime 'alpha :label "Again")
    (should (equal "Again" (harness-container-runtime-label 'alpha)))
    (should (equal "Again" (harness-container-runtime-label)))))

(ert-deftest harness-container-runtime-auto-order-and-choice ()
  "Auto tries Docker, then Podman, then other backends; a choice never falls back."
  (harness-container-runtime-test--runtimes
    (dolist (spec '((other "Other") (podman "Podman") (docker "Docker")))
      (harness-define-container-runtime (car spec) :label (cadr spec)
        :command (list (symbol-name (car spec)))
        :compose (list (symbol-name (car spec)) "compose")))
    (should (equal '(docker podman other) (harness-container-runtime--order)))
    (should (equal '(docker other podman)
                   (harness-container-runtime-ids)))
    (cl-letf (((symbol-function 'harness-container-runtime-available-p)
               (lambda (id) (eq id 'podman))))
      (should (eq 'podman (harness-container-runtime-resolve)))
      (should (equal "Podman" (harness-container-runtime-label)))
      (setq harness-container-runtime 'docker)
      (should (eq 'docker (harness-container-runtime-resolve)))
      (should (equal "Docker" (harness-container-runtime-label))))
    (setq harness-container-runtime 'auto)
    (cl-letf (((symbol-function 'harness-container-runtime-available-p)
               (lambda (_id) nil)))
      (should (eq 'docker (harness-container-runtime-resolve)))
      (should (eq 'auto (harness-container-runtime-select 'auto))))
    (should (eq 'auto harness-container-runtime))
    (should-error (harness-container-runtime-select 'no-such-runtime)
                  :type 'user-error)))

(ert-deftest harness-container-runtime-select-forgets-cached-answers ()
  "Selecting a backend remembers it and asks for availability again."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose"))
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (puthash 'docker (cons t 0.0) harness-container-runtime--available)
    (should (eq 'docker (harness-container-runtime-select 'docker)))
    (should (eq 'docker harness-container-runtime))
    (should-not (gethash 'docker harness-container-runtime--available))
    (should (eq 'podman (harness-container-runtime-select 'podman)))
    (should (eq 'podman harness-container-runtime))))

(ert-deftest harness-container-runtime-need-reasons ()
  "A backend says which executable, socket or function it lacks."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'test
      :label "Test" :command '("true") :compose '("true" "compose")
      :needs '((executable "harness-no-such-runtime-program")))
    (should (equal "Executable unavailable · harness-no-such-runtime-program"
                   (harness-container-runtime-need-reason 'test)))
    (harness-define-container-runtime 'test
      :label "Test" :command '("true") :compose '("true" "compose")
      :needs '((socket "/nonexistent/harness-runtime.sock")))
    (should (equal "Socket unavailable · /nonexistent/harness-runtime.sock"
                   (harness-container-runtime-need-reason 'test)))
    (harness-define-container-runtime 'test
      :label "Test" :command '("true") :compose '("true" "compose")
      :needs '((lambda () "Custom reason")))
    (should (equal "Custom reason" (harness-container-runtime-need-reason 'test)))
    (harness-define-container-runtime 'test
      :label "Test" :command '("true") :compose '("true" "compose")
      :needs '((lambda () nil)))
    (should-not (harness-container-runtime-need-reason 'test))
    (harness-define-container-runtime 'test
      :label "Test" :command '("true") :compose '("true" "compose")
      :socket "/nonexistent/harness-runtime.sock")
    (should (equal "Socket unavailable · /nonexistent/harness-runtime.sock"
                   (harness-container-runtime-need-reason 'test)))
    (should (equal "Runtime unconfigured"
                   (harness-container-runtime-need-reason 'missing)))))

(ert-deftest harness-container-runtime-availability ()
  "Availability is the version command, cached until it is forgotten."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose"))
    (let ((calls 0))
      (cl-letf (((symbol-function 'harness-container-runtime--exec)
                 (lambda (_argv &optional _env)
                   (setq calls (1+ calls))
                   (cons 0 "Docker Compose version v2.29.0\n"))))
        (should (harness-container-runtime-available-p 'docker))
        (should (harness-container-runtime-available-p 'docker))
        (should (= 1 calls))
        (harness-container-runtime-forget-availability)
        (should (harness-container-runtime-available-p 'docker))
        (should (= 2 calls))))
    (cl-letf (((symbol-function 'harness-container-runtime--exec)
               (lambda (_argv &optional _env) (cons 1 "not a tty\n"))))
      (harness-container-runtime-forget-availability)
      (should-not (harness-container-runtime-available-p 'docker)))))

(ert-deftest harness-container-runtime-socket-discovery ()
  "DOCKER_HOST wins; a missing declared socket falls back to a known path."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose")
      :socket "/nonexistent/declared.sock")
    (should (equal "/nonexistent/declared.sock"
                   (harness-container-runtime-socket-path 'docker)))
    (should-not (harness-container-runtime--env 'docker))
    ;; A socket at one of the known paths is found, and DOCKER_HOST is
    ;; added to the commands so the CLI looks there too.
    (let ((socket (make-temp-file "harness-runtime-socket")))
      (unwind-protect
          (progn
            (setq harness-container-runtime--socket-paths (list socket))
            (should (equal socket (harness-container-runtime-socket-path 'docker)))
            (should (equal (list (format "DOCKER_HOST=unix://%s" socket))
                           (harness-container-runtime--env 'docker))))
        (delete-file socket)))
    ;; DOCKER_HOST names the socket outright and is passed through.
    (setenv "DOCKER_HOST" "unix:///run/elsewhere.sock")
    (should (equal "/run/elsewhere.sock"
                   (harness-container-runtime-socket-path 'docker)))
    (should-not (harness-container-runtime--env 'docker))
    ;; A declared socket that exists needs no environment either.
    (setenv "DOCKER_HOST" nil)
    (let ((socket (make-temp-file "harness-runtime-socket")))
      (unwind-protect
          (progn
            (harness-define-container-runtime 'docker
              :label "Docker" :command '("docker") :compose '("docker" "compose")
              :socket socket)
            (should-not (harness-container-runtime--env 'docker)))
        (delete-file socket)))
    ;; Podman declares no socket, so it needs no environment at all.
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (should-not (harness-container-runtime-socket-path 'podman))
    (should-not (harness-container-runtime--env 'podman))))

(ert-deftest harness-container-runtime-request-socket ()
  "Requesting the socket points DOCKER_HOST at the socket that was found."
  (harness-container-runtime-test--runtimes
    (let ((socket (make-temp-file "harness-runtime-socket")))
      (unwind-protect
          (progn
            (harness-define-container-runtime 'docker
              :label "Docker" :command '("docker") :compose '("docker" "compose")
              :socket "/nonexistent/declared.sock")
            (setq harness-container-runtime 'docker)
            (setq harness-container-runtime--socket-paths (list socket))
            (cl-letf (((symbol-function 'harness-container-runtime-available-p)
                       (lambda (&optional _id) nil)))
              (should (equal socket
                             (harness-container-runtime-request-socket))))
            (should (equal (format "unix://%s" socket) (getenv "DOCKER_HOST"))))
        (delete-file socket)))
    ;; A backend without a socket says so instead of pretending.
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (setq harness-container-runtime 'podman)
    (should-not (harness-container-runtime-request-socket))))

(ert-deftest harness-container-runtime-compose-argv ()
  "Compose argv carries the backend, file, project, profiles and arguments."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (should (equal '("podman" "compose" "-p" "voice-local"
                     "-f" "/tmp/docker-compose.yml"
                     "--profile" "unmute" "up" "-d")
                   (harness-container-runtime-compose-argv
                    "/tmp/docker-compose.yml" "voice-local" '("unmute")
                    '("up" "-d") 'podman)))
    (should (equal '("podman" "compose" "-p" "voice-local"
                     "-f" "/tmp/docker-compose.yml")
                   (harness-container-runtime-compose-argv
                    "/tmp/docker-compose.yml" "voice-local" nil nil 'podman)))
    (should (equal '("podman" "network" "connect" "voice-local_voice" "server")
                   (append (harness-container-runtime-command 'podman)
                           (list "network" "connect" "voice-local_voice" "server"))))))

(ert-deftest harness-container-runtime-network-connect ()
  "Joining a network runs the backend's own network command."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (setq harness-container-runtime 'podman)
    (let (argv)
      (cl-letf (((symbol-function 'harness-container-runtime--exec)
                 (lambda (command &optional _env)
                   (setq argv command)
                   (cons 0 ""))))
        (should (equal (cons 0 "")
                       (harness-container-runtime-network-connect
                        "voice-local_voice" "harness-server")))
        (should (equal '("podman" "network" "connect"
                         "voice-local_voice" "harness-server")
                       argv))))))

(ert-deftest harness-container-runtime-exec ()
  "A missing program is exit 127; an argv list gets its environment."
  (harness-container-runtime-test--runtimes
    (should (equal (cons 127 "harness-no-such-program: not found")
                   (harness-container-runtime--exec
                    '("harness-no-such-program"))))
    (let ((reply (harness-container-runtime--exec
                  '("sh" "-c" "printf %s \"$HARNESS_RUNTIME_TEST\"")
                  '("HARNESS_RUNTIME_TEST=yes"))))
      (should (eql 0 (car reply)))
      (should (equal "yes" (cdr reply))))
    (should (eql 3 (car (harness-container-runtime--exec '("sh" "-c" "exit 3")))))
    ;; The selected backend's environment reaches an ordinary command too.
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose"))
    (setq harness-container-runtime 'docker)
    (cl-letf (((symbol-function 'harness-container-runtime--env)
               (lambda (&optional _id) '("HARNESS_RUNTIME_TEST=from-runtime"))))
      (should (equal "from-runtime"
                     (cdr (harness-container-runtime-exec
                           '("sh" "-c" "printf %s \"$HARNESS_RUNTIME_TEST\""))))))))

(ert-deftest harness-container-runtime-run ()
  "The asynchronous runner reports its exit code and output."
  (harness-container-runtime-test--runtimes
    (let (reply)
      (harness-container-runtime-run
       '("sh" "-c" "printf hello") nil
       (lambda (value) (setq reply value)))
      (harness-test-wait (lambda () reply) 5 "runtime command")
      (should (equal (cons 0 "hello") reply)))
    (let (reply)
      (harness-container-runtime-run
       '("harness-no-such-program") nil
       (lambda (value) (setq reply value)))
      (harness-test-wait (lambda () reply) 5 "missing runtime command")
      (should (eql 127 (car reply))))))

(ert-deftest harness-container-runtime-page-copy ()
  "The page shows the automatic choice, each backend and the socket."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose")
      :socket "/var/run/docker.sock")
    (harness-define-container-runtime 'podman
      :label "Podman" :command '("podman") :compose '("podman" "compose"))
    (cl-letf (((symbol-function 'harness-container-runtime--found-socket)
               (lambda () nil))
              ((symbol-function 'harness-container-runtime-available-p)
               (lambda (&optional id) (if id (eq id 'docker) t)))
              ((symbol-function 'harness-container-runtime-need-reason)
               (lambda (&optional id)
                 (and (eq id 'podman) "Executable unavailable · podman")))
              ((symbol-function 'harness-container-runtime-socket-usable-p)
               (lambda (&optional _id) t)))
      (with-temp-buffer
        (harness-container-runtime--render)
        (should (equal (concat "Container runtimes\n"
                               "\n"
                               "  ● Automatic  Docker  [Selected]\n"
                               "  ○ Docker  ready  [Select]\n"
                               "  ○ Podman  Executable unavailable · podman  [Select]\n"
                               "  Socket  ● /var/run/docker.sock  [Request]\n")
                       (buffer-substring-no-properties (point-min) (point-max)))))
      (setq harness-container-runtime 'podman)
      (with-temp-buffer
        (harness-container-runtime--render)
        (should (equal (concat "Container runtimes\n"
                               "\n"
                               "  ○ Automatic  first available  [Select]\n"
                               "  ○ Docker  ready  [Select]\n"
                               "  ● Podman  Executable unavailable · podman  [Selected]\n"
                               "\n")
                       (buffer-substring-no-properties (point-min) (point-max)))))
      (let ((harness-container-runtimes (make-hash-table :test 'eq)))
        (setq harness-container-runtime 'auto)
        (with-temp-buffer
          (harness-container-runtime--render)
          (should (equal (concat "Container runtimes\n"
                                 "\n"
                                 "  ● Automatic  None  [Selected]\n"
                                 "\n"
                                 "  No container runtime available\n")
                         (buffer-substring-no-properties (point-min) (point-max)))))))))

(ert-deftest harness-container-runtime-entry-point ()
  "The short command opens the runtimes page, and it refreshes in place."
  (harness-container-runtime-test--runtimes
    (harness-define-container-runtime 'docker
      :label "Docker" :command '("docker") :compose '("docker" "compose")
      :socket "/var/run/docker.sock")
    (save-window-excursion
      (cl-letf (((symbol-function 'harness-container-runtime-available-p)
                 (lambda (&optional _id) nil))
                ((symbol-function 'harness-container-runtime--found-socket)
                 (lambda () nil)))
        (harness-container-runtimes)
        (unwind-protect
            (with-current-buffer "*harness runtimes*"
              (should (derived-mode-p 'harness-container-runtime-mode))
              (should (string-search "Docker" (buffer-string)))
              (should (string-search "Socket unavailable · /var/run/docker.sock"
                                     (buffer-string))))
          (kill-buffer "*harness runtimes*"))))))

(provide 'harness-container-runtime-test)
;;; harness-container-runtime-test.el ends here
