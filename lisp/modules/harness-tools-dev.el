;;; harness-tools-dev.el --- Open a checkout's harness in an Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifying work on the harness itself means trying it in a running
;; Emacs.  The project's live development loop (scripts/dev.sh) starts
;; a dedicated `emacs -Q' daemon from a checkout -- a task's worktree,
;; say -- under a socket and state directory of its own, and drives it
;; with emacsclient; harness-dev.el in that checkout provides the
;; eval / keys / shot / errors commands.
;;
;; This module makes that instance one call away:
;;
;; - the agent's `open_harness' tool (with `path' defaulting to the
;;   session's worktree), and
;; - the `harness-dev/open' method, which the task board calls from the
;;   [Open harness] button on a card waiting for review.
;;
;; The tool is for this project only: sessions whose working directory
;; or worktree is a checkout of the harness (`harness.el' and
;; scripts/dev.sh side by side) are offered it, and any other directory
;; is refused.  Starting the instance is repeatable and touches nothing
;; of the session's own; the tool is in
;; `harness-perms-auto-allow-tools', so it needs no approval.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defconst harness-tools-dev-tool "open_harness"
  "Name of the tool that opens a checkout's harness in an Emacs.")

(defconst harness-tools-dev--script "scripts/dev.sh"
  "A checkout's live development loop, run to open its harness.")

(defconst harness-tools-dev--marker "harness.el"
  "File that, with `harness-tools-dev--script', marks a harness checkout.")

(defcustom harness-tools-dev-timeout 180
  "Seconds `scripts/dev.sh start' may take before the tool gives up.
The first start of a checkout byte-compiles every module, so it takes
longer than later ones."
  :type 'number :group 'harness)

;;;; Checkouts

(defun harness-tools-dev-checkout-p (dir)
  "Non-nil when DIR is a checkout of the harness itself.
That is a directory holding harness.el and the live development loop
scripts/dev.sh side by side; the main checkout and every task worktree
of this project are."
  (and dir
       (let ((dir (file-name-as-directory (expand-file-name dir))))
         (and (file-exists-p (expand-file-name harness-tools-dev--marker dir))
              (file-exists-p (expand-file-name harness-tools-dev--script dir))))))

(defun harness-tools-dev--root (dir)
  "Return the project root of DIR, or DIR itself."
  (if (and dir (harness-method-exists-p 'project/root))
      (or (ignore-errors (harness-call 'project/root dir)) dir)
    dir))

(defun harness-tools-dev--session-p (session)
  "Non-nil when SESSION works in a checkout of the harness."
  (cl-some (lambda (dir) (and dir (harness-tools-dev-checkout-p (harness-tools-dev--root dir))))
           (list (plist-get session :worktree) (plist-get session :cwd))))

(defun harness-tools-dev--session (ctx)
  "Return the session plist of CTX, or a minimal stand-in."
  (or (and (plist-get ctx :session-id)
           (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get (plist-get ctx :session-id))))
      (list :cwd (plist-get ctx :cwd))))

(defun harness-tools-dev--default-dir (ctx)
  "Return the directory the tool of CTX opens the harness from by default."
  (let ((session (harness-tools-dev--session ctx)))
    (or (plist-get session :worktree)
        (plist-get session :cwd)
        (plist-get ctx :cwd)
        default-directory)))

;;;; The instance

(defun harness-tools-dev-socket (dir)
  "Return the emacsclient socket the harness of DIR is opened under.
It derives from DIR's true name, so opening the same checkout again
reaches the same instance and two worktrees never share one."
  (concat "harness-dev-"
          (substring (secure-hash 'sha1 (file-truename (file-name-as-directory
                                                        (expand-file-name dir))))
                     0 12)))

(defun harness-tools-dev-state (dir socket)
  "Return where the instance of DIR under SOCKET keeps its state.
That is the directory scripts/dev.sh defaults to, beside the checkout."
  (file-name-as-directory (expand-file-name (concat "scripts/.dev/state-" socket) dir)))

(defun harness-tools-dev--run (dir args &optional timeout)
  "Run DIR's scripts/dev.sh with ARGS; return a promise of the result.
TIMEOUT bounds the run, in seconds (default `harness-tools-dev-timeout').
HARNESS_DEV_SOCKET names the checkout's instance, so every call of a
checkout drives the same Emacs."
  (let ((process-environment (cons (concat "HARNESS_DEV_SOCKET=" (harness-tools-dev-socket dir))
                                   process-environment)))
    (harness-run-command (cons (expand-file-name harness-tools-dev--script dir) args)
                         :cwd dir
                         :timeout (or timeout harness-tools-dev-timeout)
                         :name "harness-dev")))

(defun harness-tools-dev--describe (info)
  "Return what the model is told about the instance INFO."
  (let ((dir (abbreviate-file-name (plist-get info :path)))
        (socket (plist-get info :socket)))
    (format (concat "Harness from %s is running in an Emacs of its own (emacsclient socket %s), "
                    "with its state and compiled files in %s.%s\n"
                    "Drive it from %s with:\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh shot [PATH]   # screenshot its frame\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh keys \"C-c h a\"   # send real keys\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh eval \"(harness-call '(session/list))\"\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh errors   # recent *Messages* and warnings\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh reload   # load the source as it is now\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh stop\n"
                    "Opening it again reuses this instance.")
            dir socket (abbreviate-file-name (plist-get info :state))
            (if (plist-get info :focused)
                "  Its frame was raised and focused."
              "  Its frame stays lowered, so it does not steal focus.")
            dir socket socket socket socket socket socket)))

(defun harness-tools-dev-start (dir &optional focus)
  "Start the Emacs instance running DIR's harness; return a promise.
DIR must be a local checkout of the harness.  With FOCUS non-nil its
frame is raised and focused once it is up; otherwise it stays lowered,
so unattended starts never steal the user's focus.  The promise
resolves to (:path DIR :socket SOCKET :state STATE :focused BOOL
:output STRING); opening a checkout that is already open just ensures
its frame exists."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (when (file-remote-p dir)
      (error "Cannot open the harness of a remote directory: %s" (abbreviate-file-name dir)))
    (unless (harness-tools-dev-checkout-p dir)
      (error "%s is not a checkout of the harness: no %s and %s"
             (abbreviate-file-name dir) harness-tools-dev--marker harness-tools-dev--script))
    (harness-then
     (harness-tools-dev--run dir '("start"))
     (lambda (r)
       (if (not (eql (plist-get r :exit) 0))
           (error "Starting the harness in %s failed: %s"
                  (abbreviate-file-name dir)
                  (string-trim (concat (plist-get r :stdout) "\n" (plist-get r :stderr))))
         (let* ((socket (harness-tools-dev-socket dir))
                (info (list :path dir :socket socket
                            :state (harness-tools-dev-state dir socket)
                            :focused (and focus t)
                            :output (string-trim (plist-get r :stdout)))))
           (if focus
               (harness-then (harness-tools-dev--run dir '("eval" "(harness-dev-focus)"))
                             (lambda (_) info))
             (harness-resolved info))))))))

;;;; The tool

(defun harness-tools-dev--open (input ctx)
  "Handler of the `open_harness' tool with INPUT under CTX."
  (let* ((given (plist-get input :path))
         (path (if (and (stringp given) (not (harness-string-blank-p given)))
                   (harness-tools-resolve-path given ctx)
                 (harness-tools-dev--default-dir ctx)))
         (focus (harness-json-true-p (plist-get input :focus))))
    (condition-case err
        (harness-then (harness-tools-dev-start path focus)
                      (lambda (info) (harness-tool-ok (harness-tools-dev--describe info)))
                      (lambda (e) (harness-tool-error (harness-error-message e))))
      (error (harness-tool-error (harness-error-message err))))))

(harness-define-tool harness-tools-dev-tool
  :label "Open harness in Emacs"
  :description "Start a separate Emacs instance running the harness (this program) from a checkout or task worktree of it, so harness changes can be tried and seen live. The instance gets a socket and state directory of its own, so it does not disturb the harness you run in; opening the same directory again reuses its instance. The result lists the commands that drive it through that checkout's scripts/dev.sh: screenshot its frame, send real keys, evaluate Lisp in it, read its messages, reload it, stop it. Only directories that are checkouts of the harness work (harness.el and scripts/dev.sh side by side); path defaults to the session's worktree, else its working directory."
  :schema '(:type "object"
            :properties (:path (:type "string"
                                :description "The harness checkout or task worktree to open, absolute or relative to the working directory. Default: the session's worktree, else its working directory.")
                         :focus (:type "boolean"
                                 :description "Raise and focus the instance's frame. Default false, so an unattended start does not steal the user's focus."))
            :required ())
  :kind 'exec
  :timeout 300
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-tools-dev--open)

;;;; The method the task board calls

(harness-defmethod harness-dev/open (path &optional focus)
  "Start an Emacs instance running the harness of PATH; return a promise.
The promise resolves to the instance's info plist (see
`harness-tools-dev-start').  FOCUS raises and focuses its frame.  This
is what the task board's [Open harness] button calls; the agent uses
the `open_harness' tool, which shares the same start."
  (harness-tools-dev-start path (harness-json-true-p focus)))

;;;; Project gating

(defun harness-tools-dev--tools (names session)
  "Keep `open_harness' in NAMES only for a session in a harness checkout.
The catalogue (SESSION nil) keeps every tool."
  (if (and session (not (harness-tools-dev--session-p session)))
      (remove harness-tools-dev-tool names)
    names))

(defun harness-tools-dev--init ()
  "Offer `open_harness' only to this project's sessions."
  (harness-add-filter 'agent/tools #'harness-tools-dev--tools 50))

(harness-define-module 'tools-dev
  :doc "The open_harness tool: run a checkout's harness in an Emacs of its own."
  :requires '(tools)
  :init #'harness-tools-dev--init)

(provide 'harness-tools-dev)
;;; harness-tools-dev.el ends here
