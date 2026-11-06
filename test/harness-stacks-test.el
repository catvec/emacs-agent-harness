;;; harness-stacks-test.el --- Tests for docker compose stacks  -*- lexical-binding: t; -*-

;;; Commentary:

;; The stacks module runs the selected container runtime as argv
;; lists, so every test stubs the runner: the registry, the command it
;; would run, the environment it adds, the state it parses back and the
;; network it joins.  Nothing here starts a container, pulls an image
;; or needs docker or podman installed.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-stacks)

(defvar harness-compose-stacks)
(defvar harness-stacks--states)
(defvar harness-container-runtimes)
(defvar harness-container-runtime--available)

(defmacro harness-stacks-test--stacks (&rest body)
  "Run BODY with an empty stack registry holding one test stack."
  (declare (indent 0))
  `(let ((harness-compose-stacks (make-hash-table :test 'eq))
         (harness-stacks--states (make-hash-table :test 'eq))
         (harness-container-runtimes (make-hash-table :test 'eq))
         (harness-container-runtime 'test-runtime)
         (harness-container-runtime--available (make-hash-table :test 'eq)))
     (harness-define-container-runtime 'test-runtime
       :label "Test runtime"
       :command '("docker")
       :compose '("docker" "compose")
       :needs '((executable "docker")))
     (harness-define-compose-stack 'test-stack
       :label "Test stack"
       :doc "A stack for the tests."
       :directory "/tmp/test-stack"
       :project "test-project"
       :network "voice"
       :endpoints '((whisper 8080) (unmute 8000))
       :env (lambda () '(("WHISPER_MODEL" . "ggml-tiny.en.bin"))))
     ,@body))

(defun harness-stacks-test--stub (exit output)
  "Return a `harness-stacks--exec' stand-in answering EXIT and OUTPUT."
  (lambda (_argv &optional _env) (cons exit output)))

(ert-deftest harness-stacks-registry ()
  "A stack is registered once, replaced by a second definition, and listed by label."
  (harness-stacks-test--stacks
    (should (harness-compose-stack-get 'test-stack))
    (should (equal "Test stack" (harness-compose-stack--label 'test-stack)))
    (should (equal '(test-stack) (harness-compose-stack-ids)))
    (harness-define-compose-stack 'another :label "Another")
    (should (equal '(another test-stack) (harness-compose-stack-ids)))
    (harness-define-compose-stack 'test-stack :label "Renamed")
    (should (equal "Renamed" (harness-compose-stack--label 'test-stack)))
    (should (equal "another" (plist-get (harness-compose-stack-get 'another) :project)))
    (should (equal "docker-compose.yml" (plist-get (harness-compose-stack-get 'another) :file)))))

(ert-deftest harness-stacks-argv ()
  "The command is an argv list, with the project and the file, and its env."
  (harness-stacks-test--stacks
    (should (equal '("docker" "compose" "-p" "test-project"
                     "-f" "/tmp/test-stack/docker-compose.yml"
                     "up" "-d")
                   (harness-compose-stack--argv (harness-compose-stack-get 'test-stack)
                                                "up" "-d")))
    (should (equal '("WHISPER_MODEL=ggml-tiny.en.bin")
                   (harness-compose-stack--env-pairs (harness-compose-stack-get 'test-stack))))))

(ert-deftest harness-stacks-profiles ()
  "A stack's profiles are enabled on every docker compose command."
  (harness-stacks-test--stacks
    (harness-define-compose-stack 'test-stack
      :label "Test stack"
      :directory "/tmp/test-stack"
      :project "test-project"
      :profiles '("unmute" "gpu"))
    (should (equal '("docker" "compose" "-p" "test-project"
                     "-f" "/tmp/test-stack/docker-compose.yml"
                     "--profile" "unmute" "--profile" "gpu"
                     "up" "-d")
                   (harness-compose-stack--argv (harness-compose-stack-get 'test-stack)
                                                "up" "-d")))
    (should (equal '("docker" "compose" "-p" "test-project"
                     "-f" "/tmp/test-stack/docker-compose.yml"
                     "--profile" "unmute" "--profile" "gpu"
                     "ps" "--format" "json")
                   (harness-compose-stack--argv (harness-compose-stack-get 'test-stack)
                                                "ps" "--format" "json")))))

(ert-deftest harness-stacks-up ()
  "Starting a stack runs compose up in the background, then asks its state."
  (harness-stacks-test--stacks
    (let (calls envs answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (argv env callback)
                   (push argv calls)
                   (push env envs)
                   (funcall callback (cons 0 ""))))
                ((symbol-function 'harness-stacks--exec)
                 (harness-stacks-test--stub 0 "[{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}]")))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "up" "-d")
                       (car calls)))
        (should (equal '("WHISPER_MODEL=ggml-tiny.en.bin") (car envs)))
        (should (eq 'running (plist-get answer :state)))
        (should (equal "1 of 1 service" (plist-get answer :detail)))))))

(ert-deftest harness-stacks-up-failure ()
  "A failing compose command is a visible one-line state, not a signal."
  (harness-stacks-test--stacks
    (let (answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env callback)
                   (funcall callback (cons 1 "Cannot connect to the Docker daemon\n")))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (eq 'error (plist-get answer :state)))
        (should (equal "Cannot connect to the Docker daemon" (plist-get answer :detail)))))))

(ert-deftest harness-stacks-down ()
  "Stopping a stack runs compose down and records the stopped state."
  (harness-stacks-test--stacks
    (let (calls answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (argv _env callback)
                   (push argv calls)
                   (funcall callback (cons 0 "")))))
        (harness-compose-stack-down 'test-stack (lambda (state) (setq answer state)))
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "down")
                       (car calls)))
        (should (eq 'stopped (plist-get answer :state)))
        (should (equal "Stopped" (plist-get answer :detail)))))))

(ert-deftest harness-stacks-status-json ()
  "Compose ps JSON says how many services run, and whether one is still starting."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (harness-stacks-test--stub
                0 (concat "{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}\n"
                          "{\"Service\":\"unmute\",\"State\":\"running\",\"Health\":\"starting\"}\n"))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'starting (plist-get state :state)))
        (should (equal "2 of 2 services" (plist-get state :detail)))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (harness-stacks-test--stub
                0 "{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}\n")))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'running (plist-get state :state)))
        (should (harness-compose-stack-running-p 'test-stack))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (harness-stacks-test--stub
                0 "[{\"Service\":\"whisper\",\"State\":\"exited\",\"Health\":\"\"}]")))
      (should (eq 'stopped (plist-get (harness-compose-stack-status 'test-stack) :state))))))

(ert-deftest harness-stacks-published-ports ()
  "Docker's Publishers and its or Podman's Ports yield the published pairs."
  (should (equal '(("whisper" (8080 . 32768)))
                 (plist-get
                  (harness-compose-stack--parse-ps
                   (concat "{\"Service\":\"whisper\",\"State\":\"running\","
                           "\"Publishers\":[{\"URL\":\"127.0.0.1\","
                           "\"TargetPort\":8080,\"PublishedPort\":32768,"
                           "\"Protocol\":\"tcp\"}],"
                           "\"Ports\":\"127.0.0.1:32768->8080/tcp\"}"))
                  :ports)))
  (should (equal '(("unmute" (8000 . 32769)))
                 (plist-get
                  (harness-compose-stack--parse-ps
                   "{\"Service\":\"unmute\",\"State\":\"running\",\"Ports\":\"0.0.0.0:32769->8000/tcp\"}")
                  :ports)))
  (should (equal '(("unmute" (8000 . 32769)))
                 (plist-get
                  (harness-compose-stack--parse-ps
                   "{\"Service\":\"unmute\",\"State\":\"running\",\"Ports\":[\"0.0.0.0:32769->8000/tcp\"]}")
                  :ports)))
  (should-not (plist-get (harness-compose-stack--parse-ps
                          "{\"Service\":\"unmute\",\"State\":\"running\",\"Ports\":\"0.0.0.0:32769->8000/udp\"}")
                         :ports)))

(ert-deftest harness-stacks-status-fallback ()
  "When ps JSON fails, a stopped stack is one with no service ids."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (lambda (argv &optional _env)
                 (if (member "--format" argv)
                     (cons 1 "unknown flag: --format")
                   (cons 0 "abc123\n")))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'running (plist-get state :state)))
        (should (equal "1 of 1 service" (plist-get state :detail)))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (lambda (argv &optional _env)
                 (if (member "--format" argv)
                     (cons 1 "unknown flag: --format")
                   (cons 0 "")))))
      (should (eq 'stopped (plist-get (harness-compose-stack-status 'test-stack) :state))))))

(ert-deftest harness-stacks-status-error ()
  "A failing docker is an error state with a one-line reason."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec)
               (harness-stacks-test--stub 1 "permission denied\n")))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'error (plist-get state :state)))
        (should (equal "permission denied" (plist-get state :detail)))))))

(ert-deftest harness-stacks-unknown-and-unavailable ()
  "An unknown stack and a missing docker each say so."
  (harness-stacks-test--stacks
    (let ((state (harness-compose-stack-status 'no-such-stack)))
      (should (eq 'error (plist-get state :state)))
      (should (equal "Unknown compose stack · no-such-stack" (plist-get state :detail))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil)))
      (harness-compose-stack--forget-availability)
      (should-not (harness-compose-stack-available-p))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'error (plist-get state :state)))
        (should (equal "Executable unavailable · docker" (plist-get state :detail)))))))

(ert-deftest harness-stacks-endpoints ()
  "A service's random published port becomes a loopback URL, with a path."
  (harness-stacks-test--stacks
    (puthash 'test-stack
             (list :state 'running :detail "1 of 1 service"
                   :ports '(("whisper" (8080 . 32768))
                            ("unmute" (8000 . 32769))))
             harness-stacks--states)
    (should (equal "http://127.0.0.1:32768" (harness-compose-stack-endpoint 'test-stack 'whisper)))
    (should (equal "http://127.0.0.1:32768/inference"
                   (harness-compose-stack-endpoint 'test-stack 'whisper "inference")))
    (should (equal "http://127.0.0.1:32769/v1/audio/speech"
                   (harness-compose-stack-endpoint 'test-stack 'unmute "/v1/audio/speech")))
    (should-not (harness-compose-stack-endpoint 'test-stack 'missing))
    (should-not (harness-compose-stack-endpoint 'no-such-stack 'whisper))
    ;; A fixed port in the old declaration still wins over discovery.
    (harness-define-compose-stack 'test-stack
      :label "Test stack"
      :directory "/tmp/test-stack"
      :project "test-project"
      :endpoints '((whisper 9000 . 8080)))
    (should (equal "http://127.0.0.1:9000"
                   (harness-compose-stack-endpoint 'test-stack 'whisper)))))

(ert-deftest harness-stacks-network-name ()
  "Compose prefixes the project to a network, unless the name is full."
  (harness-stacks-test--stacks
    (let ((stack (harness-compose-stack-get 'test-stack)))
      (should (equal "test-project_voice" (harness-stacks--network-name stack)))
      (cl-letf (((symbol-function 'getenv)
                 (lambda (name) (and (equal name "HARNESS_STACK_NETWORK") "shared"))))
        (should (equal "shared" (harness-stacks--network-name stack))))
      (harness-define-compose-stack 'test-stack :network "already_full")
      (should (equal "already_full"
                     (harness-stacks--network-name (harness-compose-stack-get 'test-stack)))))))

(ert-deftest harness-stacks-attach-network ()
  "A server in a container joins the stack network; one on the host does not."
  (harness-stacks-test--stacks
    (let ((original (getenv "HARNESS_SERVER_CONTAINER"))
          (calls nil))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-stacks--server-container)
                     (lambda () "harness-server"))
                    ((symbol-function 'harness-container-runtime-network-connect)
                     (lambda (network container &optional _id)
                       (push (list "docker" "network" "connect" network container) calls)
                       (cons 0 ""))))
            (should-not (harness-compose-stack-attach-network 'test-stack))
            (should (equal '("docker" "network" "connect" "test-project_voice" "harness-server")
                           (car calls)))
            ;; A network that is already attached is a success, not an error.
            (cl-letf (((symbol-function 'harness-container-runtime-network-connect)
                       (lambda (_network _container &optional _id)
                         (cons 1 "Error response from daemon: network voice already exists"))))
              (should-not (harness-compose-stack-attach-network 'test-stack)))
            (cl-letf (((symbol-function 'harness-container-runtime-network-connect)
                       (lambda (_network _container &optional _id)
                         (cons 1 "no such network"))))
              (should (equal "Network unavailable · no such network"
                             (harness-compose-stack-attach-network 'test-stack))))
            (cl-letf (((symbol-function 'harness-stacks--server-container) (lambda () nil)))
              (should-not (harness-compose-stack-attach-network 'test-stack))))
        (setenv "HARNESS_SERVER_CONTAINER" original)))))

(ert-deftest harness-stacks-up-reports-the-network ()
  "A stack that runs but cannot join the server's network says so."
  (harness-stacks-test--stacks
    (let (answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env callback) (funcall callback (cons 0 ""))))
                ((symbol-function 'harness-compose-stack-attach-network)
                 (lambda (_id) "Network unavailable · no such container"))
                ((symbol-function 'harness-stacks--exec)
                 (harness-stacks-test--stub
                  0 "[{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}]")))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (eq 'running (plist-get answer :state)))
        (should (equal "1 of 1 service · Network unavailable · no such container"
                       (plist-get answer :detail)))
        (should (equal answer (gethash 'test-stack harness-stacks--states)))))))

(ert-deftest harness-stacks-page-copy ()
  "The page shows each stack's state, endpoints and its one control."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-compose-stack--runtime-reason) (lambda () nil)))
      (puthash 'test-stack (list :state 'running :detail "2 of 2 services"
                                 :ports '(("whisper" (8080 . 40001))
                                          ("unmute" (8000 . 40002))))
               harness-stacks--states)
      (with-temp-buffer
        (harness-stacks--render)
        (should (equal (concat "Compose stacks\n"
                               "\n"
                               "  Runtime  Test runtime  ready  [Change]\n"
                               "\n"
                               "  ● Test stack  running  2 of 2 services  [Stop]\n"
                               "      whisper · http://127.0.0.1:40001\n"
                               "      unmute · http://127.0.0.1:40002\n")
                       (buffer-substring-no-properties (point-min) (point-max)))))
      (puthash 'test-stack (list :state 'stopped :detail "No services"
                                 :ports '(("whisper" (8080 . 40003))
                                          ("unmute" (8000 . 40004))))
               harness-stacks--states)
      (with-temp-buffer
        (harness-stacks--render)
        (should (equal (concat "Compose stacks\n"
                               "\n"
                               "  Runtime  Test runtime  ready  [Change]\n"
                               "\n"
                               "  ○ Test stack  stopped  No services  [Start]\n"
                               "      whisper · http://127.0.0.1:40003\n"
                               "      unmute · http://127.0.0.1:40004\n")
                       (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest harness-stacks-entry-point ()
  "The module's short command opens the stacks page."
  (harness-stacks-test--stacks
    (save-window-excursion
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () nil)))
        (harness-stacks)
        (unwind-protect
            (with-current-buffer "*harness stacks*"
              (should (derived-mode-p 'harness-stacks-mode))
              (should (string-search "Test stack" (buffer-string))))
          (kill-buffer "*harness stacks*"))))))

(provide 'harness-stacks-test)
;;; harness-stacks-test.el ends here
