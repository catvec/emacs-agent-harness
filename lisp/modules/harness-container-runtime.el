;;; harness-container-runtime.el --- Container backends for stacks  -*- lexical-binding: t; -*-

;;; Commentary:

;; A stack runs in a container runtime, and a machine may have more
;; than one: Docker through its socket, or Podman rootless, which needs
;; no daemon and can run inside a jail.  This module is the seam: a
;; backend is declared once with `harness-define-container-runtime',
;; and `harness-container-runtime' chooses which one the stacks use.
;;
;; A backend says how to run its CLI (`:command'), how to run compose
;; (`:compose'), whether it needs a socket (`:socket') and what else it
;; needs (`:needs').  `harness-container-runtime-available-p' runs its
;; version command, so a backend whose daemon or compose provider is
;; missing reports why instead of failing deep in a process.
;;
;; The Docker socket is not assumed to be at one path: Docker's own
;; DOCKER_HOST wins, else /var/run/docker.sock, else /run/docker.sock --
;; a sandbox often shows the last one, and mounting the socket under
;; its real path is what lets the harness use it.  `M-x
;; harness-container-runtimes' lists the backends, their state and the
;; socket, and `[Request]' asks again after the socket has been made
;; available.  Nothing grants the socket itself: it is the user's
;; access decision, and Podman is the backend that needs none.
;;
;; Stacks never call docker or podman directly.  They ask this module
;; for the compose command, the network commands and the environment a
;; backend needs, so adding a backend changes no stack.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'harness-core)
(require 'harness-util)

(defgroup harness-container-runtime nil
  "Container runtimes that compose stacks run on."
  :group 'harness)

(defvar harness-container-runtimes (make-hash-table :test 'eq)
  "Runtime id -> plist of :id, :label, :doc, :command, :compose,
:socket and :needs.")

(defvar harness-container-runtime--available (make-hash-table :test 'eq)
  "Runtime id -> (ANSWER . TIME) of the last availability check.")

(defconst harness-container-runtime--cache-seconds 30
  "Seconds an availability answer is kept before the CLI is asked again.")

(defconst harness-container-runtime--socket-paths
  '("/var/run/docker.sock" "/run/docker.sock")
  "The socket paths a Docker daemon is found at, in order.")

;;;; Registry

(cl-defun harness-define-container-runtime (id &key label doc command compose socket needs)
  "Register container runtime ID.
LABEL and DOC describe it.  COMMAND is the argv prefix of its CLI,
COMPOSE the argv prefix of its compose command, SOCKET the path of the
socket it talks to (or nil for a daemonless runtime), and NEEDS a list
of things it needs: `(executable NAME)', `(socket PATH)' or a function
returning a one-line reason when it cannot run.  Defining ID again
replaces it."
  (puthash id (list :id id
                    :label (or label (symbol-name id))
                    :doc doc
                    :command command
                    :compose compose
                    :socket socket
                    :needs needs)
           harness-container-runtimes)
  id)

(defun harness-container-runtime-get (id)
  "Return the record of container runtime ID, or nil."
  (and id (gethash id harness-container-runtimes)))

(defun harness-container-runtime-ids ()
  "Return the registered container runtime ids, by label."
  (let (ids)
    (maphash (lambda (id _record) (push id ids)) harness-container-runtimes)
    (sort ids (lambda (a b)
                (string< (harness-container-runtime-label a)
                         (harness-container-runtime-label b))))))

(defun harness-container-runtime-label (&optional id)
  "Return the label of container runtime ID, or of the selected one."
  (let ((id (or id (harness-container-runtime-resolve))))
    (or (plist-get (harness-container-runtime-get id) :label)
        (and id (format "%s" id))
        "None")))

;;;; Choosing a backend

(defcustom harness-container-runtime 'auto
  "The container runtime the stacks run on.
`auto' picks Docker when its socket answers and Podman otherwise;
`docker' and `podman' name a backend outright.  A backend that is not
available does not fall back: the stacks page says what it still
needs, so the choice stays the one that was made."
  :type '(choice (const :tag "Automatic · first available" auto)
                 (const :tag "Docker · shared daemon over its socket" docker)
                 (const :tag "Podman · rootless, no daemon" podman))
  :group 'harness-container-runtime)

(defun harness-container-runtime--order ()
  "Return the backend ids `auto' tries, best first."
  (let ((ids (harness-container-runtime-ids)))
    (append (cl-remove-if-not (lambda (id) (eq id 'docker)) ids)
            (cl-remove-if-not (lambda (id) (eq id 'podman)) ids)
            (cl-remove-if (lambda (id) (memq id '(docker podman))) ids))))

(defun harness-container-runtime-resolve ()
  "Return the backend id to use, or nil when none is available."
  (let ((chosen harness-container-runtime))
    (cond
     ((and chosen (not (eq chosen 'auto)))
      chosen)
     ((cl-find-if #'harness-container-runtime-available-p
                  (harness-container-runtime--order)))
     (t (car (harness-container-runtime--order))))))

(defun harness-container-runtime-selected ()
  "Return the record of the backend in use, or nil."
  (harness-container-runtime-get (harness-container-runtime-resolve)))

(defun harness-container-runtime-select (id)
  "Select container runtime ID, or `auto'."
  (interactive
   (list (intern (completing-read "Container runtime: "
                                  (cons "auto"
                                        (mapcar #'symbol-name
                                                (harness-container-runtime-ids)))
                                  nil t))))
  (unless (or (eq id 'auto) (harness-container-runtime-get id))
    (user-error "Unknown container runtime · %s" id))
  (setq harness-container-runtime id)
  (setq harness-container-runtime--available (make-hash-table :test 'eq))
  (message "Container runtime · %s"
           (if (eq id 'auto)
               (format "Automatic · %s" (harness-container-runtime-label))
             (harness-container-runtime-label id)))
  id)

;;;; What a backend needs

(defun harness-container-runtime-socket-path (&optional id)
  "Return the socket path of backend ID, or nil when it has none.
DOCKER_HOST wins over the declared path when it names a Unix socket;
when the declared path is missing, a socket at one of the known paths
is used instead, as a sandbox often shows /run/docker.sock.  A backend
that declares no socket -- Podman, say -- has none whatever the
environment says."
  (let* ((record (harness-container-runtime-get (or id (harness-container-runtime-resolve))))
         (declared (plist-get record :socket))
         (host (getenv "DOCKER_HOST")))
    (cond
     ((null declared) nil)
     ((and host (string-prefix-p "unix://" host))
      (string-remove-prefix "unix://" host))
     ((file-exists-p declared) declared)
     ((harness-container-runtime--found-socket))
     (t declared))))

(defun harness-container-runtime--found-socket ()
  "Return a usable Docker socket path, or nil."
  (or (let ((host (getenv "DOCKER_HOST")))
        (and host (string-prefix-p "unix://" host)
             (file-exists-p (string-remove-prefix "unix://" host))
             (string-remove-prefix "unix://" host)))
      (cl-find-if #'file-exists-p harness-container-runtime--socket-paths)))

(defun harness-container-runtime--need-reason (need)
  "Return why NEED is unmet, or nil."
  (cond
   ((functionp need) (funcall need))
   ((and (consp need) (eq (car need) 'executable))
    (unless (executable-find (cadr need))
      (format "Executable unavailable · %s" (cadr need))))
   ((and (consp need) (eq (car need) 'socket))
    (unless (file-exists-p (cadr need))
      (format "Socket unavailable · %s" (cadr need))))))

(defun harness-container-runtime-need-reason (&optional id)
  "Return why container runtime ID cannot run, or nil.
The reason is one line, for a status column, never a sentence."
  (let* ((id (or id (harness-container-runtime-resolve)))
         (record (harness-container-runtime-get id)))
    (cond
     ((null record) "Runtime unconfigured")
     (t
      (or (cl-find-if #'identity
                      (mapcar #'harness-container-runtime--need-reason
                              (plist-get record :needs)))
          (let ((socket (harness-container-runtime-socket-path id)))
            (when (and socket (not (file-exists-p socket)))
              (format "Socket unavailable · %s" socket))))))))

(defun harness-container-runtime--env (&optional id)
  "Return the environment backend ID needs for its commands.
A backend that talks over a socket gets DOCKER_HOST when the socket
was found somewhere other than its declared path."
  (let* ((id (or id (harness-container-runtime-resolve)))
         (record (harness-container-runtime-get id))
         (declared (plist-get record :socket)))
    (when declared
      (let ((host (getenv "DOCKER_HOST")))
        (unless host
          (let ((socket (harness-container-runtime--found-socket)))
            (when (and socket (not (equal socket declared)))
              (list (format "DOCKER_HOST=unix://%s" socket)))))))))

(defun harness-container-runtime--version-argv (record)
  "Return the argv that asks RECORD's CLI for its version."
  (let ((compose (plist-get record :compose)))
    (if compose
        (append compose '("version"))
      (append (plist-get record :command) '("--version")))))

(defun harness-container-runtime-available-p (&optional id)
  "Non-nil when container runtime ID can run its compose command."
  (let* ((id (or id (harness-container-runtime-resolve)))
         (record (harness-container-runtime-get id))
         (cached (gethash id harness-container-runtime--available))
         (now (float-time)))
    (cond
     ((null record) nil)
     ((and cached (< (- now (cdr cached)) harness-container-runtime--cache-seconds))
      (car cached))
     (t
      (let* ((reason (harness-container-runtime-need-reason id))
             (answer
              (and (null reason)
                   (let ((reply (harness-container-runtime--exec
                                 (harness-container-runtime--version-argv record)
                                 (harness-container-runtime--env id))))
                     (eql 0 (car reply))))))
        (puthash id (cons answer now) harness-container-runtime--available)
        answer)))))

(defun harness-container-runtime-forget-availability ()
  "Forget every cached availability answer."
  (setq harness-container-runtime--available (make-hash-table :test 'eq)))

;;;; Running commands

(defun harness-container-runtime--exec (argv &optional env)
  "Run ARGV with ENV, returning (EXIT-CODE . OUTPUT).
The program is never run through a shell; a missing program is exit
127 with a one-line reason rather than a signal."
  (if (not (executable-find (car argv)))
      (cons 127 (format "%s: not found" (car argv)))
    (with-temp-buffer
      (let* ((process-environment (append env process-environment))
             (status (condition-case err
                         (apply #'call-process (car argv) nil t nil (cdr argv))
                       (file-missing
                        (insert (error-message-string err))
                        127)
                       (error
                        (insert (error-message-string err))
                        1))))
        (cons status (buffer-string))))))

(defun harness-container-runtime-exec (argv &optional env)
  "Run ARGV on the selected runtime, with ENV, returning (EXIT . OUTPUT)."
  (harness-container-runtime--exec
   argv (append env (harness-container-runtime--env))))

(defun harness-container-runtime-run (argv env callback)
  "Run ARGV asynchronously with ENV; CALLBACK gets (EXIT . OUTPUT).
The command can pull images for minutes, so it never blocks Emacs."
  (let ((buffer (generate-new-buffer " *harness-container-runtime*"))
        (process-environment (append env (harness-container-runtime--env)
                                     process-environment)))
    (condition-case err
        (make-process
         :name "harness-container-runtime"
         :command argv
         :buffer buffer
         :coding 'utf-8-unix
         :noquery t
         :sentinel (lambda (process _event)
                     (when (memq (process-status process) '(exit signal))
                       (let ((exit (process-exit-status process))
                             (output (with-current-buffer (process-buffer process)
                                       (buffer-string))))
                         (when (buffer-live-p (process-buffer process))
                           (kill-buffer (process-buffer process)))
                         (funcall callback (cons exit output))))))
      (error
       (kill-buffer buffer)
       (funcall callback (cons 127 (error-message-string err)))))))

(defun harness-container-runtime-command (&optional id)
  "Return the CLI argv prefix of backend ID, or of the selected one."
  (append (plist-get (harness-container-runtime-get (or id (harness-container-runtime-resolve)))
                     :command)))

(defun harness-container-runtime-compose-command (&optional id)
  "Return the compose argv prefix of backend ID, or of the selected one."
  (append (plist-get (harness-container-runtime-get (or id (harness-container-runtime-resolve)))
                     :compose)))

(defun harness-container-runtime-compose-argv (file project profiles arguments &optional id)
  "Return the compose command of backend ID for FILE and PROJECT.
PROFILES are enabled before ARGUMENTS, so a profile service starts and
stops with the rest of the stack."
  (append (harness-container-runtime-compose-command id)
          (list "-p" project "-f" file)
          (mapcan (lambda (profile) (list "--profile" profile)) profiles)
          arguments))

(defun harness-container-runtime-network-connect (network container &optional id)
  "Join CONTAINER to NETWORK on backend ID; return (EXIT . OUTPUT)."
  (harness-container-runtime-exec
   (append (harness-container-runtime-command id)
           (list "network" "connect" network container))))

;;;; The socket

(defun harness-container-runtime-socket-usable-p (&optional id)
  "Non-nil when the socket of container runtime ID answers."
  (harness-container-runtime-available-p id))

(defun harness-container-runtime-request-socket ()
  "Ask again for the container runtime's socket.
When the socket is elsewhere -- /run/docker.sock in a sandbox, say --
DOCKER_HOST is set for this session so the CLI finds it.  Nothing here
grants access: a socket the process cannot see needs the user's
sandbox or group permission, and Podman is the backend that needs no
socket at all."
  (interactive)
  (harness-container-runtime-forget-availability)
  (let* ((id (harness-container-runtime-resolve))
         (record (harness-container-runtime-get id))
         (declared (plist-get record :socket))
         (path (or (harness-container-runtime-socket-path id) declared))
         (found (harness-container-runtime--found-socket)))
    (cond
     ((null declared)
      (message "Runtime socket · none · %s"
               (harness-container-runtime-label id)))
     ((harness-container-runtime-available-p id)
      (message "Socket ready · %s" path))
     ((and found (not (equal found declared)))
      (setenv "DOCKER_HOST" (format "unix://%s" found))
      (harness-container-runtime-forget-availability)
      (message "Socket found · %s" found))
     (t
      (message "Socket unavailable · %s" path)))
    path))

;;;; The runtimes page

(defvar harness-container-runtime-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-container-runtimes-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Key map of `harness-container-runtime-mode'.")

(define-derived-mode harness-container-runtime-mode special-mode "Runtimes"
  "Major mode of the container runtimes page."
  (setq truncate-lines nil)
  (buffer-disable-undo))

;;;###autoload
(defun harness-container-runtimes ()
  "Show the container runtimes, which one stacks use, and their state."
  (interactive)
  (let ((buffer (get-buffer-create "*harness runtimes*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (harness-container-runtime-mode)
        (harness-container-runtime--render)))
    (pop-to-buffer buffer)
    (harness-container-runtimes-refresh)))

(defun harness-container-runtime--render ()
  "Draw the runtimes page in the current buffer."
  (let ((inhibit-read-only t)
        (chosen (harness-container-runtime-resolve)))
    (erase-buffer)
    (insert (propertize "Container runtimes" 'face 'bold) "\n\n")
    (insert "  "
            (propertize (if (eq harness-container-runtime 'auto) "●" "○")
                        'face (if (eq harness-container-runtime 'auto) 'success 'shadow))
            " "
            (propertize "Automatic" 'face 'bold)
            "  "
            (propertize (if (eq harness-container-runtime 'auto)
                            (harness-container-runtime-label chosen)
                          "first available")
                      'face 'shadow)
            "  ")
    (insert-text-button (if (eq harness-container-runtime 'auto) "[Selected]" "[Select]")
                        'action (lambda (_button) (harness-container-runtime-select 'auto))
                        'follow-link t
                        'help-echo "Container runtime · automatic")
    (insert "\n")
    (dolist (id (harness-container-runtime-ids))
      (let ((selected (eq id harness-container-runtime))
            (reason (harness-container-runtime-need-reason id)))
        (insert "  "
                (propertize (if selected "●" "○")
                            'face (if selected 'success 'shadow))
                " "
                (propertize (harness-container-runtime-label id) 'face 'bold)
                "  "
                (propertize (or reason "ready")
                            'face (if reason 'error 'shadow))
                "  ")
        (insert-text-button (if selected "[Selected]" "[Select]")
                            'action (lambda (_button) (harness-container-runtime-select id))
                            'follow-link t
                            'help-echo (format "Container runtime · %s" id))
        (insert "\n")))
    (let* ((record (harness-container-runtime-get chosen))
           (socket (and record (or (harness-container-runtime-socket-path chosen)
                                   (plist-get record :socket))))
           (usable (and socket (harness-container-runtime-socket-usable-p chosen))))
      (when socket
        (insert "  "
                (propertize "Socket" 'face 'bold)
                "  "
                (propertize (if usable (concat "● " socket) (concat "✕ " socket))
                            'face (if usable 'success 'error))
                "  ")
        (insert-text-button "[Request]"
                            'action (lambda (_button)
                                      (harness-container-runtime-request-socket)
                                      (harness-container-runtime--render))
                            'follow-link t
                            'help-echo "Container runtime socket · ask again")))
    (insert "\n")
    (unless chosen
      (insert (propertize "  No container runtime available\n" 'face 'error)))))

(defun harness-container-runtimes-refresh ()
  "Ask again for every runtime's state."
  (interactive)
  (harness-container-runtime-forget-availability)
  (when (get-buffer-window "*harness runtimes*")
    (with-current-buffer "*harness runtimes*"
      (harness-container-runtime--render))))

;;;; The bundled backends

(harness-define-container-runtime 'docker
  :label "Docker"
  :doc "The shared Docker daemon, over its Unix socket."
  :command '("docker")
  :compose '("docker" "compose")
  :socket "/var/run/docker.sock"
  :needs '((executable "docker")))

(harness-define-container-runtime 'podman
  :label "Podman"
  :doc "Rootless Podman: no daemon and no socket, so it can run in a jail."
  :command '("podman")
  :compose '("podman" "compose")
  :socket nil
  :needs '((executable "podman")))

;;;; Module

(defun harness-container-runtime--init ()
  "Forget cached answers, so a new start asks again."
  (harness-container-runtime-forget-availability))

(harness-define-module 'container-runtime
  :doc "Container runtimes for stacks: Docker over its socket, or rootless Podman, with a selectable backend."
  :init #'harness-container-runtime--init)

(provide 'harness-container-runtime)
;;; harness-container-runtime.el ends here
