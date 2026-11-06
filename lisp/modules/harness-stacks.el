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
;;     :doc "whisper.cpp and Kyutai Unmute, on loopback."
;;     :directory (expand-file-name "scripts/stacks/voice-local" harness-directory)
;;     :project "voice-local"
;;     :network "voice"
;;     :endpoints '((whisper 8080) (unmute 8000))
;;     :profiles '("unmute")
;;     :env (lambda () '(("WHISPER_MODEL" . "ggml-base.en.bin"))))
;;
;; The stack's services publish their ports on loopback with no fixed
;; host port, so two stacks never fight over 8080: the runtime picks a
;; free loopback port, and `harness-compose-stack-endpoint' reads the
;; published one from `compose ps'.  When the harness server runs in a
;; container instead -- a development container, a CI box -- the
;; container is attached to the stack's network with the runtime's
;; `network connect', so the server reaches the services by name too.
;; `HARNESS_SERVER_CONTAINER' names that container; without it, a
;; process inside a container finds itself by `/.dockerenv' and
;; `HOSTNAME'.  The compose network's real name is the project's,
;; `PROJECT_NETWORK' (compose prefixes it), unless
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
:project, :network, :endpoints, :profiles and :env.")

(defvar harness-stacks--states (make-hash-table :test 'eq)
  "Compose stack id -> the last state plist seen for it.")

(defvar harness-stacks--timeout 600
  "Seconds a runtime's compose up may take before the harness notes it.")

;;;; Registry

(cl-defun harness-define-compose-stack (id &key label doc directory file project network
                                           endpoints profiles env)
  "Register compose stack ID.
LABEL and DOC describe it.  DIRECTORY holds the compose file FILE
\(docker-compose.yml by default).  PROJECT is the compose project name,
the id by default.  NETWORK is the compose network its services join.
ENDPOINTS maps a service name to its container port, (SERVICE PORT),
and the published loopback port is discovered from the runtime; the
old (SERVICE HOST-PORT . CONTAINER-PORT) still names a fixed port.
PROFILES names the compose profiles every command enables, so a service
behind one starts and stops with the stack.  ENV is a function
returning an alist of extra environment variables for the stack's
commands, such as a model size.  Defining ID again replaces it."
  (puthash id (list :id id
                    :label (or label (symbol-name id))
                    :doc doc
                    :directory directory
                    :file (or file "docker-compose.yml")
                    :project (or project (symbol-name id))
                    :network network
                    :endpoints endpoints
                    :profiles profiles
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

(defun harness-compose-stack--file (stack)
  "Return the compose file of STACK."
  (expand-file-name (plist-get stack :file) (plist-get stack :directory)))

(defun harness-compose-stack--env-pairs (stack)
  "Return STACK's extra environment as a list of KEY=VALUE strings."
  (let ((env (plist-get stack :env)))
    (when (functionp env) (setq env (funcall env)))
    (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair))) env)))

(defun harness-compose-stack--argv (stack &rest arguments)
  "Return the runtime's compose command of STACK, then ARGUMENTS.
The stack's profiles are enabled on every command: a profile service
must start, report its state and stop with the rest."
  (funcall #'harness-container-runtime-compose-argv
           (harness-compose-stack--file stack)
           (plist-get stack :project)
           (plist-get stack :profiles)
           arguments))

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

(defun harness-stacks--one-line (text)
  "Return TEXT as one short line, without a trailing newline."
  (let ((line (or (and (stringp text) (string-trim text)) "")))
    (setq line (car (split-string line "\n")))
    (if (> (length line) 160) (concat (substring line 0 157) "...") line)))

(defun harness-stacks--exec (argv &optional env)
  "Run runtime ARGV, with ENV, and return (EXIT-CODE . OUTPUT)."
  (harness-container-runtime-exec argv env))

(defun harness-stacks--run (argv env callback)
  "Run runtime ARGV asynchronously, with ENV; CALLBACK gets (EXIT . OUTPUT).
The compose command can pull images for minutes, so it never blocks
Emacs; the harness reports it when it ends."
  (harness-container-runtime-run argv env callback))

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
  "Ask the container runtime for the state of compose stack ID."
  (let ((stack (harness-compose-stack-get id)))
    (cond
     ((null stack)
      (list :state 'error :detail (format "Unknown compose stack · %s" id)))
     ((not (harness-compose-stack-available-p))
      (list :state 'error
            :detail (or (harness-compose-stack--runtime-reason)
                        "Runtime unavailable")))
     (t
      (let ((reply (harness-stacks--exec
                    (harness-compose-stack--argv stack "ps" "--format" "json")
                    (harness-compose-stack--env-pairs stack))))
        (if (eql 0 (car reply))
            (harness-compose-stack--parse-ps (cdr reply))
          (harness-compose-stack--parse-ps-quiet stack)))))))

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
  (let ((reply (harness-stacks--exec
                (harness-compose-stack--argv stack "ps" "-q")
                (harness-compose-stack--env-pairs stack))))
    (cond
     ((not (eql 0 (car reply)))
      (list :state 'error
            :detail (or (harness-stacks--one-line (cdr reply)) "Compose failed")))
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
           (let ((state (list :state 'error
                              :detail (or (harness-stacks--one-line (cdr reply))
                                          "Compose failed"))))
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
                        (list :state 'error
                              :detail (or (harness-stacks--one-line (cdr reply))
                                          "Compose failed")))))
           (harness-compose-stack--remember id state)
           (when callback (funcall callback state)))))))))

(defun harness-stacks--command (stack arguments callback)
  "Run STACK's compose command with ARGUMENTS, reporting to CALLBACK.
A command that runs longer than `harness-stacks--timeout' is reported,
not killed: a first pull can be slow without being wrong."
  (let* ((label (harness-compose-stack--label (plist-get stack :id)))
         (timer (run-at-time harness-stacks--timeout nil
                             (lambda () (message "Compose stack · still running · %s" label)))))
    (harness-stacks--run (apply #'harness-compose-stack--argv stack arguments)
                         (harness-compose-stack--env-pairs stack)
                         (lambda (reply)
                           (when (timerp timer) (cancel-timer timer))
                           (funcall callback reply)))))

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
            "  "
            (propertize detail 'face 'shadow)
            "  ")
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
    (insert "\n")
    (dolist (entry (plist-get stack :endpoints))
      (insert "      "
              (propertize (format "%s · %s" (car entry)
                                  (or (harness-compose-stack-endpoint id (car entry))
                                      "unavailable"))
                          'face 'shadow)
              "\n"))))

(defun harness-stacks--redraw (&optional _state)
  "Redraw the stacks page, when a window shows it."
  (when (get-buffer-window "*harness stacks*")
    (with-current-buffer "*harness stacks*"
      (harness-stacks--render))))

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
  :doc "Compose stacks that modules and plugins declare: start, stop, state, dynamic ports and the harness server's network."
  :init #'harness-stacks--init)

(provide 'harness-stacks)
;;; harness-stacks.el ends here
