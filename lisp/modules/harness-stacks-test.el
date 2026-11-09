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
(defvar harness-stacks--commands)
(defvar harness-stacks--failures)
(defvar harness-container-runtimes)
(defvar harness-container-runtime--available)

(defmacro harness-stacks-test--stacks (&rest body)
  "Run BODY with an empty stack registry holding one test stack."
  (declare (indent 0))
  `(let ((harness-compose-stacks (make-hash-table :test 'eq))
         (harness-stacks--states (make-hash-table :test 'eq))
         (harness-stacks--commands (make-hash-table :test 'eq))
         (harness-stacks--failures (make-hash-table :test 'eq))
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

(ert-deftest harness-stacks-profiles-follow-a-setting ()
  "A profile function is asked for each command, so a setting picks the service."
  (harness-stacks-test--stacks
    (let ((choice "first"))
      (harness-define-compose-stack 'test-stack
        :label "Test stack"
        :directory "/tmp/test-stack"
        :project "test-project"
        :profiles (lambda () (list choice))
        :all-profiles '("first" "second"))
      (should (equal '("docker" "compose" "-p" "test-project"
                       "-f" "/tmp/test-stack/docker-compose.yml"
                       "--profile" "first"
                       "ps" "--format" "json")
                     (harness-compose-stack--argv (harness-compose-stack-get 'test-stack)
                                                  "ps" "--format" "json")))
      (setq choice "second")
      (should (equal '("docker" "compose" "-p" "test-project"
                       "-f" "/tmp/test-stack/docker-compose.yml"
                       "--profile" "second"
                       "up" "-d")
                     (harness-compose-stack--argv (harness-compose-stack-get 'test-stack)
                                                  "up" "-d")))
      ;; Stopping enables every profile the stack can run, so a service
      ;; another selection started goes too.
      (should (equal '("docker" "compose" "-p" "test-project"
                       "-f" "/tmp/test-stack/docker-compose.yml"
                       "--profile" "first" "--profile" "second"
                       "down")
                     (harness-compose-stack--stop-argv
                      (harness-compose-stack-get 'test-stack) "down"))))))

(ert-deftest harness-stacks-up ()
  "Starting a stack runs compose up in the background, then asks its state."
  (harness-stacks-test--stacks
    (let (calls envs answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (argv env callback &optional _directory)
                   (push argv calls)
                   (push env envs)
                   (funcall callback (cons 0 ""))))
                ((symbol-function 'harness-stacks--exec-for-stack)
                 (lambda (_stack &rest _arguments)
                   (cons 0 "[{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}]"))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "up" "-d")
                       (car calls)))
        (should (equal '("WHISPER_MODEL=ggml-tiny.en.bin") (car envs)))
        (should (eq 'running (plist-get answer :state)))
        (should (equal "1 of 1 service" (plist-get answer :detail)))))))

(ert-deftest harness-stacks-up-failure ()
  "A failing compose command is a visible state, not a signal.
The state keeps the exit status beside the reason, and the command that
failed stays readable in the stack's log."
  (harness-stacks-test--stacks
    (let (answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env callback &optional _directory)
                   (funcall callback (cons 1 "Cannot connect to the Docker daemon\n")))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (eq 'error (plist-get answer :state)))
        (should (equal "exit 1 · Cannot connect to the Docker daemon"
                       (plist-get answer :detail)))
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "up" "-d")
                       (plist-get (harness-compose-stack-last-command 'test-stack)
                                  :argv)))
        (should (equal "/tmp/test-stack"
                       (plist-get (harness-compose-stack-last-command 'test-stack)
                                  :directory)))))))

(ert-deftest harness-stacks-failure-survives-the-status-queries ()
  "A failed start stays the stack's state, and its log, until one succeeds.
The page asks `compose ps' after a start fails, and the answer to a
question is not a second start: with no container up the query would
read `stopped', and the reason the start failed would be gone from the
page and from its log.  The podman-shaped failure is kept verbatim."
  (harness-stacks-test--stacks
    (let ((failure (concat
                    ">>>> Executing external compose provider \"/opt/homebrew/bin/podman-compose\". <<<<\n"
                    "\n"
                    "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\"\n"
                    "Error: executing /opt/homebrew/bin/podman-compose -p test-project -f /tmp/test-stack/docker-compose.yml --profile whisper up -d: exit status 1\n"))
          (answer nil) (queries 0))
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env callback &optional _directory)
                   (funcall callback (cons 1 failure))))
                ((symbol-function 'harness-stacks--exec-for-stack)
                 (lambda (_stack &rest _arguments)
                   (setq queries (1+ queries))
                   (cons 0 ""))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (equal "exit 1 · Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\""
                       (plist-get answer :detail)))
        ;; The page's query finds no service, and changes nothing.
        (let ((queried (harness-compose-stack-status 'test-stack)))
          (should (> queries 0))
          (should (eq 'error (plist-get queried :state)))
          (should (equal (plist-get answer :detail) (plist-get queried :detail)))
          (should (equal answer queried)))
        ;; The log is the start that failed, not the query after it.
        (should (string-match-p "--profile whisper up -d" (harness-compose-stack-log-text 'test-stack)))
        (should (string-match-p "Exit  1" (harness-compose-stack-log-text 'test-stack)))
        ;; A start that works clears it.
        (cl-letf (((symbol-function 'harness-stacks--run)
                   (lambda (_argv _env callback &optional _directory)
                     (funcall callback (cons 0 ""))))
                  ((symbol-function 'harness-stacks--exec-for-stack)
                   (lambda (_stack &rest _arguments)
                     (cons 0 "{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}"))))
          (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
          (should (eq 'running (plist-get answer :state)))
          (should-not (harness-compose-stack-last-failure 'test-stack))
          (should (string-match-p "up -d" (harness-compose-stack-log-text 'test-stack))))))))

(ert-deftest harness-stacks-one-line ()
  "A failed compose command keeps its reason, not its progress or escapes."
  (should (equal "Error response from daemon: pull access denied for kyutai/unmute"
                 (harness-stacks--one-line
                  (concat "\u001b[?25l\u001b[0G[+] up 0/1\n"
                          " Image kyutai/unmute:latest Pulling \n"
                          " Image kyutai/unmute:latest Error pull access denied\n"
                          "Error response from daemon: pull access denied for kyutai/unmute\n"))))
  (should (equal "Cannot connect to the Docker daemon"
                 (harness-stacks--one-line "Cannot connect to the Docker daemon\n")))
  (should (equal "last line" (harness-stacks--one-line "first\nlast line\n")))
  (should (equal "done" (harness-stacks--one-line "\u001b[?25ldone\u001b[0G")))
  (should-not (harness-stacks--one-line "\u001b[?25l\u001b[0G\n"))
  (should-not (harness-stacks--one-line ""))
  ;; Nothing is cut at a width: the part past it is what says what failed.
  (should (equal (make-string 200 ?x)
                 (harness-stacks--one-line (make-string 200 ?x))))
  ;; Podman's wrapper around its compose provider is the last line and the
  ;; least it says: the provider's own error is the reason.
  (should (equal "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\""
                 (harness-stacks--one-line
                  (concat "Trying to pull ghcr.io/ggml-org/whisper.cpp:main...\n"
                          "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\"\n"
                          "Error: executing /opt/homebrew/bin/podman-compose -p voice-local -f /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml --profile whisper up -d: exit status 1\n"))))
  ;; A provider whose only complaint is the wrapper line still says it.
  (should (equal "Error: executing /opt/homebrew/bin/podman-compose up: exit status 1"
                 (harness-stacks--one-line
                  "Error: executing /opt/homebrew/bin/podman-compose up: exit status 1\n"))))

(ert-deftest harness-stacks-down ()
  "Stopping a stack runs compose down and records the stopped state."
  (harness-stacks-test--stacks
    (let (calls answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (argv _env callback &optional _directory)
                   (push argv calls)
                   (funcall callback (cons 0 "")))))
        (harness-compose-stack-down 'test-stack (lambda (state) (setq answer state)))
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "down")
                       (car calls)))
        (should (eq 'stopped (plist-get answer :state)))
        (should (equal "Stopped" (plist-get answer :detail)))))))

(ert-deftest harness-stacks-down-every-profile ()
  "Stopping a stack enables every profile it can run, not only the selected one.
Compose removes the profile services a command enables, so a down that
named only the new selection would leave the old one running."
  (harness-stacks-test--stacks
    (let (calls)
      (harness-define-compose-stack 'test-stack
        :label "Test stack"
        :directory "/tmp/test-stack"
        :project "test-project"
        :profiles (lambda () '("second"))
        :all-profiles '("first" "second"))
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (argv _env callback &optional _directory)
                   (push argv calls)
                   (funcall callback (cons 0 "")))))
        (harness-compose-stack-down 'test-stack)
        (should (equal '("docker" "compose" "-p" "test-project"
                         "-f" "/tmp/test-stack/docker-compose.yml"
                         "--profile" "first" "--profile" "second"
                         "down")
                       (car calls)))))))

(ert-deftest harness-stacks-status-json ()
  "Compose ps JSON says how many services run, and whether one is still starting."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest _arguments)
                 (cons 0 (concat "{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}\n"
                                 "{\"Service\":\"unmute\",\"State\":\"running\",\"Health\":\"starting\"}\n")))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'starting (plist-get state :state)))
        (should (equal "2 of 2 services" (plist-get state :detail)))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest _arguments)
                 (cons 0 "{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}\n"))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'running (plist-get state :state)))
        (should (harness-compose-stack-running-p 'test-stack))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest _arguments)
                 (cons 0 "[{\"Service\":\"whisper\",\"State\":\"exited\",\"Health\":\"\"}]"))))
      (should (eq 'stopped (plist-get (harness-compose-stack-status 'test-stack) :state))))))

(ert-deftest harness-stacks-running-command-is-not-a-failure ()
  "A start still running is not the stack's failure.
The command is remembered before it runs so that a failure which never
comes back still names what was run; a page refresh during the pull
asks for the state, and must not read the still-running start as a
failed one and lose the reason of the failure before it."
  (harness-stacks-test--stacks
    (let (answer)
      (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
                ((symbol-function 'harness-stacks--run)
                 (lambda (_argv _env _callback &optional _directory)
                   ;; The start is under way: no answer yet.
                   nil))
                ((symbol-function 'harness-stacks--exec-for-stack)
                 (lambda (_stack &rest _arguments) (cons 0 ""))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should-not answer)
        (should (eq 'starting (plist-get (gethash 'test-stack harness-stacks--states)
                                         :state)))
        (should-not (harness-compose-stack-last-failure 'test-stack))
        (should (equal "up" (nth 6 (plist-get (harness-compose-stack-last-command
                                               'test-stack)
                                              :argv))))
        (should-not (plist-get (harness-compose-stack-last-command 'test-stack) :exit))))))

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
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest arguments)
                 (if (member "--format" arguments)
                     (cons 1 "unknown flag: --format")
                   (cons 0 "abc123\n")))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'running (plist-get state :state)))
        (should (equal "1 of 1 service" (plist-get state :detail)))))
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest arguments)
                 (if (member "--format" arguments)
                     (cons 1 "unknown flag: --format")
                   (cons 0 "")))))
      (should (eq 'stopped (plist-get (harness-compose-stack-status 'test-stack) :state))))))

(ert-deftest harness-stacks-status-error ()
  "A failing docker is an error state with a one-line reason."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-stacks--exec-for-stack)
               (lambda (_stack &rest _arguments)
                 (cons 1 "permission denied\n"))))
      (let ((state (harness-compose-stack-status 'test-stack)))
        (should (eq 'error (plist-get state :state)))
        (should (equal "exit 1 · permission denied" (plist-get state :detail)))))))

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
                 (lambda (_argv _env callback &optional _directory)
                   (funcall callback (cons 0 ""))))
                ((symbol-function 'harness-compose-stack-attach-network)
                 (lambda (_id) "Network unavailable · no such container"))
                ((symbol-function 'harness-stacks--exec-for-stack)
                 (lambda (_stack &rest _arguments)
                   (cons 0 "[{\"Service\":\"whisper\",\"State\":\"running\",\"Health\":\"\"}]"))))
        (harness-compose-stack-up 'test-stack (lambda (state) (setq answer state)))
        (should (eq 'running (plist-get answer :state)))
        (should (equal "1 of 1 service · Network unavailable · no such container"
                       (plist-get answer :detail)))
        (should (equal answer (gethash 'test-stack harness-stacks--states)))))))

(ert-deftest harness-stacks-page-copy ()
  "The page shows each stack's state, endpoints and its controls.
A stack that has run no command has nothing to log, so it shows no
`[Log]' until one has."

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

(ert-deftest harness-stacks-page-log-button ()
  "A stack that has run a command shows its log control."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-compose-stack--runtime-reason) (lambda () nil)))
      (puthash 'test-stack (list :state 'error :detail "exit 1 · no such image"
                                 :ports nil)
               harness-stacks--states)
      (harness-stacks--command-remember 'test-stack
                                        '("docker" "compose" "up" "-d")
                                        nil 1 "no such image\n"
                                        "/tmp/test-stack")
      (with-temp-buffer
        (harness-stacks--render)
        (should (equal (concat "Compose stacks\n"
                               "\n"
                               "  Runtime  Test runtime  ready  [Change]\n"
                               "\n"
                               "  ○ Test stack  error  [Start]  [Log]\n"
                               "      exit 1 · no such image\n"
                               "      whisper · unavailable\n"
                               "      unmute · unavailable\n")
                       (buffer-substring-no-properties (point-min) (point-max))))
        ;; The tooltip is the rule's own words, not a sentence.
        (goto-char (point-min))
        (search-forward "[Log]")
        (should (equal "Compose stack · last command and output"
                       (get-text-property (match-beginning 0) 'help-echo)))))))

(ert-deftest harness-stacks-page-reason-whole ()
  "A long reason is on the page whole, not cut to a fixed width.
The reason a start failed is what the page is read for: cutting it
wherever it passed some column is what made the failure unreadable in
the first place, so the row carries every word of it.  What is not
shown is the progress before it (see `harness-stacks--one-line')."
  (harness-stacks-test--stacks
    (cl-letf (((symbol-function 'harness-compose-stack-available-p) (lambda () t))
              ((symbol-function 'harness-compose-stack--runtime-reason) (lambda () nil)))
      (let ((detail (concat "exit 1 · Error: no image found in manifest list for architecture "
                            "\"arm64\", variant \"v8\", OS \"linux\", and the provider's own "
                            "path /opt/homebrew/bin/podman-compose is named here too")))
        (puthash 'test-stack (list :state 'error :detail detail :ports nil)
                 harness-stacks--states)
        (with-temp-buffer
          (harness-stacks--render)
          (should (equal (concat "Compose stacks\n"
                                 "\n"
                                 "  Runtime  Test runtime  ready  [Change]\n"
                                 "\n"
                                 "  ○ Test stack  error  [Start]\n"
                                 "      " detail "\n"
                                 "      whisper · unavailable\n"
                                 "      unmute · unavailable\n")
                         (buffer-substring-no-properties (point-min) (point-max)))))))))

(ert-deftest harness-stacks-log-text ()
  "The log is the exact command, where it ran, its status and its output."
  (harness-stacks-test--stacks
    (harness-stacks--command-remember
     'test-stack
     '("/opt/homebrew/bin/podman-compose" "-p" "voice-local"
       "-f" "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml"
       "--profile" "whisper" "up" "-d")
     '("WHISPER_MODEL=ggml-base.en.bin")
     1
     (concat ">>>> Executing external compose provider \"/opt/homebrew/bin/podman-compose\". <<<<\n"
             "\n"
             "Traceback (most recent call last):\n"
             "  File \"/opt/homebrew/bin/podman-compose\", line 6, in <module>\n"
             "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\"\n"
             "Error: executing /opt/homebrew/bin/podman-compose -p voice-local -f /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml --profile whisper up -d: exit status 1\n")
     "/Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local")
    (should (equal (concat
                    "/opt/homebrew/bin/podman-compose -p voice-local"
                    " -f /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml"
                    " --profile whisper up -d\n"
                    "Directory  /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local\n"
                    "Environment  WHISPER_MODEL=ggml-base.en.bin\n"
                    "Exit  1\n"
                    "\n"
                    ">>>> Executing external compose provider \"/opt/homebrew/bin/podman-compose\". <<<<\n"
                    "\n"
                    "Traceback (most recent call last):\n"
                    "  File \"/opt/homebrew/bin/podman-compose\", line 6, in <module>\n"
                    "Error: no image found in manifest list for architecture \"arm64\", variant \"v8\", OS \"linux\"\n"
                    "Error: executing /opt/homebrew/bin/podman-compose -p voice-local -f /Users/noah/documents/ai/emacs-agent-harness/scripts/stacks/voice-local/docker-compose.yml --profile whisper up -d: exit status 1\n")
                   (harness-compose-stack-log-text 'test-stack)))
    (should-not (harness-compose-stack-log-text 'no-such-stack))))

(ert-deftest harness-stacks-log-buffer-copy ()
  "The log buffer is read-only, in its own mode, and says which stack it is."
  (harness-stacks-test--stacks
    (harness-stacks--command-remember 'test-stack '("docker" "compose" "up" "-d")
                                      nil 0 "" "/tmp/test-stack")
    (save-window-excursion
      (unwind-protect
          (progn
            (harness-compose-stack-log 'test-stack)
            (with-current-buffer (harness-stacks--log-buffer-name 'test-stack)
              (should (derived-mode-p 'harness-stacks-log-mode))
              (should buffer-read-only)
              (should (equal (concat "docker compose up -d\n"
                                     "Directory  /tmp/test-stack\n"
                                     "Exit  0\n"
                                     "\n")
                             (buffer-substring-no-properties (point-min) (point-max))))
              (should (eq 'test-stack (get-text-property (point-min) 'harness-stack-id)))))
        (kill-buffer (harness-stacks--log-buffer-name 'test-stack))))
    (should-error (harness-compose-stack-log 'no-such-stack) :type 'user-error)))

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
