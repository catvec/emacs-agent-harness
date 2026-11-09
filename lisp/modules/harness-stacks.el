;;; harness-stacks.el --- Compose stacks that modules declare  -*- lexical-binding: t; -*-

;;; Commentary:

;; A module may need a service beside the harness: a speech stack, a
;; database, a search index.  It declares a compose stack with
;; `harness-define-compose-stack', and this module starts it, stops it,
;; reports its state and connects the network it runs in to the one the
;; harness server uses.  The runtime is not fixed: `container-runtime'
;; supplies the compose command, the network commands and the socket,
;; so Docker and rootless Podman are the same to a stack.
;;
;;   (harness-define-compose-stack 'voice-local
;;     :label "Local voice"
;;     :doc "whisper.cpp or Parakeet and Kokoro, on loopback."
;;     :directory (expand-file-name "scripts/stacks/voice-local" harness-directory)
;;     :project "voice-local"
;;     :network "voice"
;;     :endpoints '((whisper 8080) (parakeet 8081) (tts 8880))
;;     :profiles #'harness-voice-stack-profiles
;;     :all-profiles '("whisper" "parakeet")
;;     :env (lambda () '(("WHISPER_MODEL" . "ggml-base.en.bin"))))
;;
;; The stack's services publish their ports on loopback with no fixed
;; host port, so two stacks never fight over 8080: the runtime picks a
;; free loopback port, and `harness-compose-stack-endpoint' reads the
;; published one from `compose ps'.  A stack whose services run behind
;; compose profiles declares them with :profiles -- a list, or a
;; function returning one when a setting selects the service, as a
;; speech model does -- and the same profiles are enabled on every
;; command.  :all-profiles names every profile the stack can use, for
;; `down': stopping must remove what another selection started, and
;; compose only removes the profiles a command enables.  When the
;; harness server runs in a container instead -- a development
;; container, a CI box -- the container is attached to the stack's
;; network with the runtime's `network connect', so the server reaches
;; the services by name too.  `HARNESS_SERVER_CONTAINER' names that
;; container; without it, a process inside a container finds itself by
;; `/.dockerenv' and `HOSTNAME'.  The compose network's real name is
;; the project's, `PROJECT_NETWORK' (compose prefixes it), unless
;; `HARNESS_STACK_NETWORK' names it outright.
;;
;; Commands run as argv lists, never through a shell, and every command
;; a stack needs is defined where its services are.  `M-x
;; harness-stacks' lists the stacks with their state, endpoints and
;; start/stop buttons; the module a stack belongs to starts it from its
;; own UI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'harness-core)
(require 'harness-util)
(require 'harness-container-runtime)

(defgroup harness-stacks nil
  "Compose stacks that modules and plugins declare."
  :group 'harness)

(defvar harness-compose-stacks (make-hash-table :test 'eq)
  "Compose stack id -> plist of :id, :label, :doc, :directory, :file,
:project, :network, :endpoints, :profiles, :all-profiles and :env.")

(defvar harness-stacks--states (make-hash-table :test 'eq)
  "Compose stack id -> the last state plist seen for it.")

(defvar harness-stacks--commands (make-hash-table :test 'eq)
  "Compose stack id -> the last command run for it.
A plist of `:argv' (the exact argv list), `:directory' (where it ran),
`:env' (the variables added), `:exit' (its exit status, or nil while it
runs), `:output' (both streams as it wrote them) and `:at' (when it
ended).  `M-x harness-compose-stack-log' shows it whole.")

(defvar harness-stacks--failures (make-hash-table :test 'eq)
  "Compose stack id -> the start or stop that last failed for it.
The record is as `harness-stacks--commands' holds one.  It is kept
until a later start or stop succeeds, so a state query that finds
nothing running does not turn a failed start into a stopped stack and
lose the reason: the failure stays what the page shows, and the log it
opens is the command that failed.")

(defconst harness-stacks--runtime-wrapper-patterns
  '("\\`Error: executing .*: exit status -?[0-9]+\\'"
    "\\`Error: executing .*: signal: [a-z0-9]+\\'")
  "Lines that report only that the runtime's compose provider failed.
Podman's `compose' is a thin wrapper around an external provider, such
as `/opt/homebrew/bin/podman-compose', and when the provider fails it
prints one line naming the provider and its whole argv, with the exit
status.  That line is the last the output holds and the least it says:
the provider's own error came before it.")

(defvar harness-stacks--timeout 600
  "Seconds a runtime's compose up may take before the harness notes it.")

;;;; Registry

(cl-defun harness-define-compose-stack (id &key label doc directory file project network
                                           endpoints profiles all-profiles env)
  "Register compose stack ID.
LABEL and DOC describe it.  DIRECTORY holds the compose file FILE
\(docker-compose.yml by default).  PROJECT is the compose project name,
the id by default.  NETWORK is the compose network its services join.
ENDPOINTS maps a service name to its container port, (SERVICE PORT),
and the published loopback port is discovered from the runtime; the
old (SERVICE HOST-PORT . CONTAINER-PORT) still names a fixed port.
PROFILES names the compose profiles every command enables, so a service
behind one starts and stops with the stack; a function returning that
list is called for each command, so a setting can choose the service.
ALL-PROFILES names every profile the stack can use, for `down': the
stack's other selections are removed too, since compose removes only
the profiles a command enables.  ENV is a function returning an alist
of extra environment variables for the stack's commands, such as a
model size.  Defining ID again replaces it."
  (puthash id (list :id id
                    :label (or label (symbol-name id))
                    :doc doc
                    :directory directory
                    :file (or file "docker-compose.yml")
                    :project (or project (symbol-name id))
                    :network network
                    :endpoints endpoints
                    :profiles profiles
                    :all-profiles all-profiles
                    :env env)
           harness-compose-stacks)
  id)

(defun harness-compose-stack-get (id)
  "Return the record of compose stack ID, or nil."
  (and id (gethash id harness-compose-stacks)))

(defun harness-compose-stack-ids ()
  "Return the registered compose stack ids, by label."
  (let (ids)
    (maphash (lambda (id _record) (push id ids)) harness-compose-stacks)
    (sort ids (lambda (a b)
                (string< (harness-compose-stack--label a)
                         (harness-compose-stack--label b))))))

(defun harness-compose-stack--label (id)
  "Return the label of compose stack ID."
  (or (plist-get (harness-compose-stack-get id) :label) (format "%s" id)))

;;;; Commands

(defun harness-stacks--directory (stack)
  "Return the directory of STACK, where its compose commands run.
A compose file names its volumes and build contexts relative to itself,
and a provider resolves them from the directory the command runs in:
Docker Compose from the file, podman-compose from its own working
directory.  Running in the stack's directory is what makes the file's
relative paths mean the same thing to both."
  (or (plist-get stack :directory)
      default-directory))

(defun harness-compose-stack--file (stack)
  "Return the compose file of STACK."
  (expand-file-name (plist-get stack :file) (harness-stacks--directory stack)))

(defun harness-compose-stack--env-pairs (stack)
  "Return STACK's extra environment as a list of KEY=VALUE strings."
  (let ((env (plist-get stack :env)))
    (when (functionp env) (setq env (funcall env)))
    (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair))) env)))

(defun harness-compose-stack--profiles (stack)
  "Return the compose profiles STACK enables on a command.
A function in the stack record is called, so a setting can select the
service, as the local voice model selects its speech engine."
  (let ((profiles (plist-get stack :profiles)))
    (if (functionp profiles) (funcall profiles) profiles)))

(defun harness-compose-stack--compose-argv (stack profiles arguments)
  "Return STACK's compose command with PROFILES, then ARGUMENTS."
  (funcall #'harness-container-runtime-compose-argv
           (harness-compose-stack--file stack)
           (plist-get stack :project)
           profiles
           arguments))

(defun harness-compose-stack--argv (stack &rest arguments)
  "Return the runtime's compose command of STACK, then ARGUMENTS.
The stack's profiles are enabled on every command: a profile service
must start, report its state and stop with the rest."
  (harness-compose-stack--compose-argv
   stack (harness-compose-stack--profiles stack) arguments))

(defun harness-compose-stack--stop-argv (stack &rest arguments)
  "Return STACK's compose command with every profile it can use, then ARGUMENTS.
Stopping must remove what another selection started: compose removes
only the profiles a command enables, so a service enabled under a
different profile would otherwise keep running unseen."
  (let ((all (plist-get stack :all-profiles)))
    (when (functionp all) (setq all (funcall all)))
    (harness-compose-stack--compose-argv
     stack (or all (harness-compose-stack--profiles stack)) arguments)))

(defun harness-compose-stack-available-p ()
  "Non-nil when the selected container runtime and its compose plugin work."
  (harness-container-runtime-available-p))

(defun harness-compose-stack--runtime-reason ()
  "Return the one-line reason the selected runtime cannot run stacks."
  (or (harness-container-runtime-need-reason)
      (and (not (harness-compose-stack-available-p))
           (format "Compose unavailable · %s"
                   (harness-container-runtime-label)))))

(defun harness-compose-stack--forget-availability ()
  "Ask again whether the container runtime is usable, on the next question."
  (harness-container-runtime-forget-availability))

(defun harness-stacks--strip-controls (text)
  "Return TEXT without terminal control sequences or carriage returns.
Compose writes a spinner and in-place progress when its output is not a
terminal; none of it belongs in a one-line state."
  (let ((text (replace-regexp-in-string "\r" "\n" (or text ""))))
    (replace-regexp-in-string "\033\\[[0-9;?]*[[:alpha:]]" "" text)))

(defun harness-stacks--error-line-p (line)
  "Non-nil when LINE reads like the reason a command failed."
  (let ((case-fold-search t))
    (string-match-p
     (concat "error\\|failed\\|denied\\|unavailable\\|not found"
             "\\|cannot\\|no such\\|unknown\\|traceback\\|exception")
     line)))

(defun harness-stacks--wrapper-line-p (line)
  "Non-nil when LINE says only that the runtime's compose provider failed.
Podman's `compose' wraps an external provider, and its last line names
that provider and its argv and nothing else; the provider's own reason
came before it."
  (let ((case-fold-search nil))
    (cl-some (lambda (pattern) (string-match-p pattern line))
             harness-stacks--runtime-wrapper-patterns)))

(defun harness-stacks--reason-line (lines)
  "Return the line of LINES that best says why a command failed.
LINES are non-empty lines, trimmed, in the order the command wrote
them.  A wrapper line -- the runtime saying its provider exited
nonzero -- is the last line and the least informative, so the last line
that reads like a failure and is not one wins; failing that, the first
so that a provider which prints its complaint first is still heard; and
when nothing reads like a failure, the last line is what is left."
  (let ((errors (seq-filter #'harness-stacks--error-line-p lines)))
    (or (car (last (seq-remove #'harness-stacks--wrapper-line-p errors)))
        (car (seq-remove #'harness-stacks--wrapper-line-p errors))
        (car (last lines)))))

(defun harness-stacks--one-line (text)
  "Return TEXT as the one line that says why a command failed.
A failed compose command writes progress before the reason, so the
line that reads like the reason is kept (see
`harness-stacks--reason-line').  Nothing is cut: there is no width a
reason may be shortened to, since the part past it is what says what
failed.  A display that must fit one row truncates for its own width,
where the width is known, and `M-x harness-compose-stack-log' has the
whole of it.  Nil means there was no line to show."
  (let* ((clean (harness-stacks--strip-controls text))
         (lines (seq-remove #'string-empty-p
                            (mapcar #'string-trim (split-string clean "\n")))))
    (harness-stacks--reason-line lines)))

(defun harness-stacks--status-line (exit text)
  "Return the words for a failed command with EXIT and its output TEXT.
The exit status is part of the reason: a provider that exits 0 while
the runtime prints an error is a different problem from one that
exits 1, and a client cannot tell them apart from the words alone."
  (let ((reason (harness-stacks--one-line text)))
    (cond ((and exit reason (not (eq exit 0)))
           (format "exit %d · %s" exit reason))
          (reason reason)
          (exit (format "exit %d" exit))
          (t "Compose failed"))))

(defun harness-stacks--quoted-argv (argv)
  "Return the shell command line that runs ARGV as it is."
  (mapconcat #'shell-quote-argument argv " "))

(defun harness-stacks--command-remember (id argv env exit output
                                            &optional directory kind)
  "Remember the command just run for stack ID, and return the record.
ARGV is its exact argv list, ENV the variables added to it, EXIT its
exit status, OUTPUT both streams, DIRECTORY where it ran, and KIND
`start', `stop' or `query' what it was asked to do.  A start or stop
that fails is kept as the stack's failure; one that succeeds clears it,
and a query changes neither, since a query that finds nothing running
is not a stack that started."
  (let ((record (list :argv (append argv nil)
                      :directory (or directory default-directory)
                      :env (append env nil)
                      :exit exit
                      :output (or output "")
                      :kind kind
                      :at (float-time))))
    (puthash id record harness-stacks--commands)
    (when (and (memq kind '(start stop)) (numberp exit))
      (if (eql exit 0)
          (remhash id harness-stacks--failures)
        (puthash id record harness-stacks--failures)))
    record))

(defun harness-compose-stack-last-command (id)
  "Return the last command run for compose stack ID, or nil.
The plist holds `:argv', `:directory', `:env', `:exit', `:output',
`:kind' and `:at', as `harness-stacks--commands' describes."
  (and id (gethash id harness-stacks--commands)))

(defun harness-compose-stack-last-failure (id)
  "Return the start or stop of compose stack ID that last failed, or nil.
The record is the one `harness-compose-stack-last-command' describes.
It is kept until a later start or stop succeeds, so the reason a start
failed outlives the state queries that follow it."
  (and id (gethash id harness-stacks--failures)))

(defun harness-stacks--run (argv env callback &optional directory)
  "Run runtime ARGV with ENV in DIRECTORY; CALLBACK gets (EXIT . OUTPUT).
The compose command can pull images for minutes, so it never blocks
Emacs; the harness reports it when it ends."
  (harness-container-runtime-run argv env callback directory))

(defun harness-stacks--exec (argv &optional env directory)
  "Run runtime ARGV, with ENV, in DIRECTORY, and return (EXIT-CODE . OUTPUT)."
  (harness-container-runtime-exec argv env directory))

(defun harness-stacks--exec-for-stack (stack &rest arguments)
  "Ask STACK's runtime about it with ARGUMENTS; return (EXIT . OUTPUT).
The command runs in the stack's directory, with its environment, and
is remembered as the stack's last command; a query is not a start, so
it neither sets nor clears the stack's failure."
  (let* ((argv (apply #'harness-compose-stack--argv stack arguments))
         (env (harness-compose-stack--env-pairs stack))
         (directory (harness-stacks--directory stack))
         (reply (harness-stacks--exec argv env directory)))
    (harness-stacks--command-remember (plist-get stack :id) argv env
                                      (car reply) (cdr reply) directory
                                      'query)
    reply))


;;;; State

(defun harness-compose-stack--remember (id state)
  "Remember STATE, a plist, for compose stack ID."
  (puthash id state harness-stacks--states)
  state)

(defun harness-compose-stack-status (id &optional callback)
  "Return the state of compose stack ID, or report it to CALLBACK.
The value is a plist: `:state' is `running', `starting', `stopped' or
`error', and `:detail' a one-line explanation, such as
\"2 of 2 services\"."
  (let ((state (harness-compose-stack--query id)))
    (harness-compose-stack--remember id state)
    (when callback (funcall callback state))
    state))

(defun harness-compose-stack--query (id)
  "Ask the container runtime for the state of compose stack ID.
A start or stop that failed, and that nothing has succeeded since, is
the state, whatever the services now do: a failed start is not a
stopped stack, and its reason stays until the next start or stop
succeeds."
  (let ((stack (harness-compose-stack-get id))
        (failure (harness-compose-stack-last-failure id)))
    (cond
     ((null stack)
      (list :state 'error :detail (format "Unknown compose stack · %s" id)))
     ((not (harness-compose-stack-available-p))
      (list :state 'error
            :detail (or (harness-compose-stack--runtime-reason)
                        "Runtime unavailable")))
     (t
      (let* ((reply (harness-stacks--exec-for-stack stack "ps" "--format" "json"))
             (state (if (eql 0 (car reply))
                        (harness-compose-stack--parse-ps (cdr reply))
                      (harness-compose-stack--parse-ps-quiet stack))))
        (if (and failure (not (harness-compose-stack--up-p state)))
            (harness-stacks--failed-state id (plist-get failure :output))
          state))))))

(defun harness-compose-stack--up-p (state)
  "Non-nil when STATE, a state plist, is a stack that runs.
A stack that is starting runs: something it started is on its way, so
a failure before it is no longer what the stack is."
  (memq (plist-get state :state) '(running starting)))

(defun harness-compose-stack--parse-ps (output)
  "Return the state plist described by the runtime's compose ps OUTPUT.
The plist carries `:ports', the random loopback ports the runtime gave
the services, so an endpoint needs no second call."
  (let* ((services (harness-compose-stack--services output))
         (total (length services))
         (running (seq-count (lambda (service)
                               (equal "running" (plist-get service :State)))
                             services))
         (starting (seq-count (lambda (service)
                                (member (plist-get service :Health) '("starting" "unhealthy")))
                              services))
         (ports (harness-compose-stack--ports services)))
    (cond
     ((zerop total) (list :state 'stopped :detail "No services" :ports nil))
     ((and (= running total) (zerop starting))
      (list :state 'running :detail (harness-compose-stack--services-detail running total)
            :ports ports))
     ((zerop running)
      ;; Nothing runs: unless a start or stop failed and nothing has
      ;; succeeded since, in which case that is what the stack is.
      (list :state 'stopped :detail (format "0 of %d services" total) :ports ports))
     (t (list :state 'starting :detail (harness-compose-stack--services-detail running total)
              :ports ports)))))

(defun harness-compose-stack--ports (services)
  "Return SERVICE -> ((CONTAINER-PORT . PUBLISHED-PORT)) for SERVICES."
  (delq nil
        (mapcar (lambda (service)
                  (let ((name (plist-get service :Service))
                        (pairs (harness-compose-stack--published-pairs service)))
                    (when (and name pairs) (cons name pairs))))
                services)))

(defun harness-compose-stack--published-pairs (service)
  "Return the (CONTAINER-PORT . PUBLISHED-PORT) pairs of SERVICE.
Docker's compose prints `Publishers'; Podman prints `Ports', sometimes
as `HOST:PORT->CONTAINER/tcp' strings; both are read, TCP only."
  (let ((publishers (plist-get service :Publishers))
        (ports (plist-get service :Ports))
        pairs)
    (when (vectorp publishers) (setq publishers (append publishers nil)))
    (when (vectorp ports) (setq ports (append ports nil)))
    (dolist (publisher (append (if (listp publishers) publishers (list publishers))
                               (cond ((stringp ports) (list ports))
                                     ((listp ports) ports))))
      (cond
       ((stringp publisher)
        (when (string-match "\\([0-9]+\\)->\\([0-9]+\\)/tcp" publisher)
          (push (cons (string-to-number (match-string 2 publisher))
                      (string-to-number (match-string 1 publisher)))
                pairs)))
       ((listp publisher)
        (let ((container (or (plist-get publisher :TargetPort)
                             (plist-get publisher :target_port)
                             (plist-get publisher :container_port)))
              (published (or (plist-get publisher :PublishedPort)
                             (plist-get publisher :published_port)
                             (plist-get publisher :host_port)))
              (protocol (or (plist-get publisher :Protocol)
                            (plist-get publisher :protocol)
                            "tcp")))
          (when (and (numberp container) (numberp published) (> published 0)
                     (string-equal "tcp" (format "%s" protocol)))
            (push (cons container published) pairs))))))
    (delete-dups (nreverse pairs))))

(defun harness-compose-stack--services-detail (running total)
  "Return the words for RUNNING of TOTAL services."
  (format "%d of %d %s" running total (if (= total 1) "service" "services")))

(defun harness-compose-stack--services (output)
  "Return the service plists in a compose ps json OUTPUT.
Compose prints one object per line, or an array, depending on its
version; both are read."
  (let ((text (string-trim (or output ""))))
    (cond
     ((string-empty-p text) nil)
     ((eq (aref text 0) ?\[)
      (condition-case nil
          (append (json-parse-string text :object-type 'plist :array-type 'list) nil)
        (error nil)))
     (t
      (delq nil
            (mapcar (lambda (line)
                      (condition-case nil
                          (json-parse-string line :object-type 'plist :array-type 'list)
                        (error nil)))
                    (split-string text "\n" t)))))))

(defun harness-compose-stack--parse-ps-quiet (stack)
  "Ask for the service ids of STACK when its JSON listing failed."
  (let ((reply (harness-stacks--exec-for-stack stack "ps" "-q")))
    (cond
     ((not (eql 0 (car reply)))
      (list :state 'error
            :detail (harness-stacks--status-line (car reply) (cdr reply))))
     ((string-empty-p (string-trim (cdr reply)))
      (list :state 'stopped :detail "No services"))
     (t (list :state 'running
              :detail (harness-compose-stack--services-detail
                       (length (split-string (string-trim (cdr reply)) "\n" t))
                       (length (split-string (string-trim (cdr reply)) "\n" t))))))))

(defun harness-compose-stack-running-p (id)
  "Non-nil when every service of compose stack ID runs."
  (eq 'running (plist-get (harness-compose-stack-status id) :state)))

;;;; Starting and stopping

(defun harness-compose-stack-up (id &optional callback)
  "Start compose stack ID; CALLBACK gets its state plist.
The command runs in the background, since a first start may pull
images; when it ends the stack's network is joined to the harness
server's, if the server runs in a container."
  (let ((stack (harness-compose-stack-get id)))
    (cond
     ((null stack)
      (let ((state (list :state 'error :detail (format "Unknown compose stack · %s" id))))
        (harness-compose-stack--remember id state)
        (when callback (funcall callback state))
        state))
     ((not (harness-compose-stack-available-p))
      (let ((state (list :state 'error
                         :detail (or (harness-compose-stack--runtime-reason)
                                     "Runtime unavailable"))))
        (harness-compose-stack--remember id state)
        (when callback (funcall callback state))
        state))
     (t
      (message "Compose stack · starting · %s" (harness-compose-stack--label id))
      (harness-compose-stack--remember id (list :state 'starting :detail "Starting"))
      (harness-stacks--command
       stack (list "up" "-d")
       (lambda (reply)
         (if (eql 0 (car reply))
             (let ((network-error (harness-compose-stack-attach-network id)))
               (harness-compose-stack-status
                id (lambda (state)
                     (when network-error
                       ;; The stack runs, but the server cannot reach it
                       ;; by name: say so instead of reporting only success.
                       (setq state (plist-put (copy-sequence state)
                                              :detail (format "%s · %s"
                                                              (or (plist-get state :detail)
                                                                  "Running")
                                                              network-error))))
                     (harness-compose-stack--remember id state)
                     (when callback (funcall callback state)))))
           (let ((state (harness-stacks--failed-state id (cdr reply))))
             (harness-compose-stack--remember id state)
             (when callback (funcall callback state))))))))))

(defun harness-compose-stack-down (id &optional callback)
  "Stop compose stack ID; CALLBACK gets its state plist."
  (let ((stack (harness-compose-stack-get id)))
    (cond
     ((null stack)
      (let ((state (list :state 'error :detail (format "Unknown compose stack · %s" id))))
        (when callback (funcall callback state))
        state))
     ((not (harness-compose-stack-available-p))
      (let ((state (list :state 'error
                         :detail (or (harness-compose-stack--runtime-reason)
                                     "Runtime unavailable"))))
        (when callback (funcall callback state))
        state))
     (t
      (message "Compose stack · stopping · %s" (harness-compose-stack--label id))
      (harness-stacks--command
       stack (list "down")
       (lambda (reply)
         (let ((state (if (eql 0 (car reply))
                          (list :state 'stopped :detail "Stopped")
                        (harness-stacks--failed-state id (cdr reply)))))
           (harness-compose-stack--remember id state)
           (when callback (funcall callback state))))
       t 'stop)))))

(defun harness-stacks--failed-state (id output)
  "Return the error state of stack ID after a command wrote OUTPUT.
The detail keeps the exit status beside the provider's own reason, so a
client shows what failed as well as which command did (see
`harness-compose-stack--log-record')."
  (list :state 'error
        :detail (harness-stacks--status-line
                 (plist-get (harness-compose-stack--log-record id) :exit)
                 output)))

(defun harness-stacks--command (stack arguments callback &optional every-profile kind)
  "Run STACK's compose command with ARGUMENTS, reporting to CALLBACK.
EVERY-PROFILE enables all the profiles the stack can use, for `down'.
KIND is `start' or `stop'.  A command that runs longer than
`harness-stacks--timeout' is reported, not killed: a first pull can be
slow without being wrong.  The command runs in the stack's directory
with pipes, and its argv, directory, environment, exit status and whole
output are kept as the stack's last command when it ends; failing, it
is kept as the stack's failure too."
  (let* ((kind (or kind 'start))
         (label (harness-compose-stack--label (plist-get stack :id)))
         (argv (if every-profile
                   (apply #'harness-compose-stack--stop-argv stack arguments)
                 (apply #'harness-compose-stack--argv stack arguments)))
         (env (harness-compose-stack--env-pairs stack))
         (directory (harness-stacks--directory stack))
         (timer (run-at-time harness-stacks--timeout nil
                             (lambda () (message "Compose stack · still running · %s" label)))))
    ;; The command is recorded before it runs, so a failure that never
    ;; comes back still names what was run and where.  It is not yet a
    ;; failure: the last one stays until this one ends.
    (harness-stacks--command-remember (plist-get stack :id) argv env nil "" directory kind)
    (harness-stacks--run argv env
                         (lambda (reply)
                           (when (timerp timer) (cancel-timer timer))
                           (harness-stacks--command-remember
                            (plist-get stack :id) argv env
                            (car reply) (cdr reply) directory kind)
                           (funcall callback reply))
                         directory)))

;;;; Networks

(defun harness-stacks--network-name (stack)
  "Return the container network name of STACK.
Compose prefixes the project name to a network, so the declared
`voice' is `PROJECT_voice'; a name with an underscore is taken as the
full name, and `HARNESS_STACK_NETWORK' overrides both."
  (or (let ((named (getenv "HARNESS_STACK_NETWORK")))
        (and named (not (string-empty-p named)) named))
      (when-let* ((network (plist-get stack :network)))
        (if (string-search "_" network)
            network
          (format "%s_%s" (plist-get stack :project) network)))))

(defun harness-stacks--server-container ()
  "Return the container the harness server runs in, or nil.
`HARNESS_SERVER_CONTAINER' names it; in a container without that, the
container's own hostname is the id."
  (or (let ((named (getenv "HARNESS_SERVER_CONTAINER")))
        (and named (not (string-empty-p named)) named))
      (and (file-exists-p "/.dockerenv")
           (let ((host (getenv "HOSTNAME")))
             (and host (not (string-empty-p host)) host)))))

(defun harness-compose-stack-attach-network (id)
  "Join the harness server's container to compose stack ID's network.
Return nil when the server is on this machine -- the stack's published
loopback ports are the connection then -- or a one-line reason when the
join fails."
  (let* ((stack (harness-compose-stack-get id))
         (network (and stack (harness-stacks--network-name stack)))
         (container (harness-stacks--server-container)))
    (cond
     ((null stack) "Unknown compose stack")
     ((null network) nil)
     ((null container) nil)
     (t
      (let ((reply (harness-container-runtime-network-connect network container)))
        (cond
         ((eql 0 (car reply)) nil)
         ((string-match-p "already exists" (cdr reply)) nil)
         (t (format "Network unavailable · %s"
                    (or (harness-stacks--one-line (cdr reply)) network)))))))))

;;;; Endpoints

(defun harness-compose-stack--declared-endpoint (entry)
  "Return (STATIC-PORT . CONTAINER-PORT) for endpoint ENTRY.
ENTRY is (SERVICE CONTAINER-PORT), or the older
(SERVICE HOST-PORT . CONTAINER-PORT) with a fixed port."
  (let ((rest (cdr entry)))
    (cond
     ((null rest) (cons nil nil))
     ((null (cdr rest)) (cons nil (car rest)))
     ((atom (cdr rest)) (cons (car rest) (cdr rest)))
     (t (cons (car rest) (cadr rest))))))

(defun harness-compose-stack-endpoint (id service &optional path)
  "Return the loopback URL of SERVICE in compose stack ID, or nil.
PATH is appended to the published port.  The port is the one the
runtime gave the service as a random loopback port; a fixed
(SERVICE HOST-PORT . CONTAINER-PORT) in the stack record still wins."
  (let* ((stack (harness-compose-stack-get id))
         (entry (and stack (assq service (plist-get stack :endpoints))))
         (declared (and entry (harness-compose-stack--declared-endpoint entry)))
         (static (car declared))
         (container (cdr declared))
         (state (or (gethash id harness-stacks--states)
                    (harness-compose-stack-status id)))
         (ports (plist-get state :ports))
         (published (or static
                        (and container
                             (harness-compose-stack--published
                              ports service container)))))
    (when (and (numberp published) (> published 0))
      (format "http://127.0.0.1:%d%s" published
              (if (and path (not (string-empty-p path)))
                  (concat "/" (string-remove-prefix "/" path))
                "")))))

(defun harness-compose-stack--published (ports service container)
  "Return the published port of CONTAINER on SERVICE in PORTS, or nil.
PORTS maps a service name, a string as the runtime JSON prints it, to
its (CONTAINER-PORT . PUBLISHED-PORT) pairs; SERVICE is a symbol."
  (let ((entry (seq-find (lambda (pair)
                           (equal (format "%s" (car pair))
                                  (format "%s" service)))
                         ports)))
    (cdr (assq container (cdr entry)))))

;;;; The log of a stack's last command

(defun harness-stacks--log-buffer-name (id)
  "Return the name of the log buffer of compose stack ID."
  (format "*harness stack log: %s*" id))

(defvar harness-stacks-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-stacks-log-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Key map of `harness-stacks-log-mode'.")

(define-derived-mode harness-stacks-log-mode special-mode "Stack Log"
  "Major mode of a compose stack's command log.
It shows the last command the stack ran, where it ran, the environment
it added, its exit status and its whole output, as written.  After a
failed start or stop it shows that one: the reason a start failed is
what the log is opened for, and the state queries that followed it are
not."
  (setq truncate-lines nil)
  (buffer-disable-undo))

(defun harness-compose-stack--log-record (id)
  "Return the command record of compose stack ID that its log shows.
A start or stop that failed is the one, until one succeeds; otherwise
it is the last command run."
  (or (harness-compose-stack-last-failure id)
      (harness-compose-stack-last-command id)))

(defun harness-compose-stack-log-text (id)
  "Return the log of compose stack ID, as text.
The command comes first, as the shell line that runs it, then where it
ran, the environment it added, its exit status and its output.  A start
or stop that failed is the command shown, until one succeeds.  Nil when
the stack has run no command."
  (when-let* ((record (harness-compose-stack--log-record id)))
    (let ((exit (plist-get record :exit))
          (output (or (plist-get record :output) "")))
      (concat
       (format "%s\n" (harness-stacks--quoted-argv (plist-get record :argv)))
       (format "Directory  %s\n" (plist-get record :directory))
       (if (plist-get record :env)
           (format "Environment  %s\n"
                   (mapconcat #'identity (plist-get record :env) " "))
         "")
       (format "Exit  %s\n"
               (cond ((numberp exit)
                      (if (eql exit 0) "0" (format "%d" exit)))
                     (t "running")))
       "\n"
       (harness-stacks--strip-controls output)
       (unless (or (string-empty-p output) (string-suffix-p "\n" output))
         "\n")))))

(defun harness-stacks-log-refresh ()
  "Draw the log of the stack this buffer shows."
  (interactive)
  (let ((id (get-text-property (point-min) 'harness-stack-id)))
    (when id
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or (harness-compose-stack-log-text id) "No command\n"))
        (goto-char (point-min))))))

;;;###autoload
(defun harness-compose-stack-log (id)
  "Show the last command run for compose stack ID, and its whole output.
That is the exact argv list, where it ran, the environment added to it,
its exit status and everything it wrote, on both streams: what the
one-line state cannot hold and a failure is read from."
  (interactive
   (list (intern (completing-read "Compose stack: "
                                  (mapcar #'symbol-name (harness-compose-stack-ids))
                                  nil t))))
  (unless (harness-compose-stack-get id)
    (user-error "Unknown compose stack · %s" id))
  (let ((buffer (get-buffer-create (harness-stacks--log-buffer-name id))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (harness-stacks-log-mode)
        (erase-buffer)
        (insert (or (harness-compose-stack-log-text id) "No command\n"))
        (goto-char (point-min))
        (put-text-property (point-min) (point-max) 'harness-stack-id id)))
    (pop-to-buffer buffer)))

;;;; The stacks page

(defvar harness-stacks-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-stacks-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Key map of `harness-stacks-mode'.")

(define-derived-mode harness-stacks-mode special-mode "Stacks"
  "Major mode of the compose stacks page.
\\[harness-stacks-refresh] asks the runtime again for every stack's state."
  (setq truncate-lines nil)
  (buffer-disable-undo))

;;;###autoload
(defun harness-compose-stacks ()
  "Show the compose stacks, their state and their start and stop controls."
  (interactive)
  (let ((buffer (get-buffer-create "*harness stacks*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (harness-stacks-mode)
        (harness-stacks--render)))
    (pop-to-buffer buffer)
    (harness-stacks-refresh)))

;;;###autoload
(defun harness-stacks ()
  "Show the compose stacks that modules and plugins declare."
  (interactive)
  (harness-compose-stacks))

(defun harness-stacks--render ()
  "Draw the stacks page in the current buffer."
  (let ((inhibit-read-only t)
        (reason (harness-compose-stack--runtime-reason)))
    (erase-buffer)
    (insert (propertize "Compose stacks" 'face 'bold) "\n\n")
    (insert "  "
            (propertize "Runtime" 'face 'bold)
            "  "
            (propertize (harness-container-runtime-label) 'face 'default)
            "  "
            (propertize (or reason "ready")
                        'face (if reason 'error 'shadow))
            "  ")
    (insert-text-button "[Change]"
                        'action (lambda (_button) (harness-container-runtimes))
                        'follow-link t
                        'help-echo "Container runtime · choose")
    (insert "\n\n")
    (let ((ids (harness-compose-stack-ids)))
      (if (null ids)
          (insert "  No compose stacks\n")
        (dolist (id ids)
          (harness-stacks--insert-stack id))))))

(defun harness-stacks--insert-stack (id)
  "Insert the line of compose stack ID at point."
  (let* ((stack (harness-compose-stack-get id))
         (state (gethash id harness-stacks--states))
         (kind (plist-get state :state))
         (detail (or (plist-get state :detail) "Unknown"))
         (running (eq kind 'running)))
    (insert "  "
            (propertize (if running "●" "○")
                        'face (pcase kind
                                ('running 'success)
                                ('error 'error)
                                (_ 'shadow)))
            " "
            (propertize (harness-compose-stack--label id) 'face 'bold)
            "  "
            (propertize (pcase kind
                          ('running "running")
                          ('starting "starting")
                          ('stopped "stopped")
                          ('error "error")
                          (_ "unknown"))
                        'face (pcase kind
                                ('running 'success)
                                ('error 'error)
                                (_ 'shadow)))
            "  ")
    ;; A short detail -- "2 of 2 services" -- says the state on its row.
    ;; A failed command's reason goes below it, whole: see the end of
    ;; this function.
    (when (not (eq kind 'error))
      (insert (propertize detail 'face 'shadow) "  "))
    (let ((action (if running
                      (lambda (_button) (harness-compose-stack-down id #'harness-stacks--redraw))
                    (lambda (_button) (harness-compose-stack-up id #'harness-stacks--redraw)))))
      (insert-text-button
       (if running "[Stop]" "[Start]")
       'action action
       'follow-link t
       'help-echo (if running
                      "Compose stack · stop"
                    "Compose stack · start")))
    (when (harness-compose-stack--log-record id)
      (insert "  ")
      (insert-text-button
       "[Log]"
       'action (lambda (_button) (harness-compose-stack-log id))
       'follow-link t
       'help-echo "Compose stack · last command and output"))
    (insert "\n")
    ;; A failed command's reason is on a line of its own, below the row
    ;; and its controls: it is what the page is read for, and a reason
    ;; long enough to push the controls off the row would be a row whose
    ;; buttons move with the message.  Nothing of it is cut.
    (when (eq kind 'error)
      (insert "      "
              (propertize detail 'face 'shadow)
              "\n"))
    (dolist (entry (plist-get stack :endpoints))
      (insert "      "
              (propertize (format "%s · %s" (car entry)
                                  (or (harness-compose-stack-endpoint id (car entry))
                                      "unavailable"))
                          'face 'shadow)
              "\n"))))

(defun harness-stacks--redraw (&optional _state)
  "Redraw the stacks page, when a window shows it, and any stack's log."
  (when (get-buffer-window "*harness stacks*")
    (with-current-buffer "*harness stacks*"
      (harness-stacks--render)))
  (dolist (id (harness-compose-stack-ids))
    (let ((buffer (get-buffer (harness-stacks--log-buffer-name id))))
      (when (and (buffer-live-p buffer) (get-buffer-window buffer))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (or (harness-compose-stack-log-text id) "No command\n"))
            (goto-char (point-min))
            (put-text-property (point-min) (point-max) 'harness-stack-id id)))))))

(defun harness-stacks-refresh ()
  "Ask the container runtime again for every stack's state."
  (interactive)
  (harness-compose-stack--forget-availability)
  (dolist (id (harness-compose-stack-ids))
    (harness-compose-stack-status id #'harness-stacks--redraw)))

;;;; Module

(defun harness-stacks--init ()
  "Make the stack commands known to this process."
  (harness-compose-stack--forget-availability))

(harness-define-module 'stacks
  :doc "Compose stacks that modules and plugins declare: start, stop, state, dynamic ports, the harness server's network, and the log of each stack's last command."
  :init #'harness-stacks--init)

(provide 'harness-stacks)
;;; harness-stacks.el ends here
