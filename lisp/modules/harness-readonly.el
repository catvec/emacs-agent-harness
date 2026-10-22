;;; harness-readonly.el --- Read-only sessions: they look, and change nothing  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some sessions are there to read and decide, never to change anything:
;; a supervisor that plans while workers make the changes
;; (harness-supervisor.el), the session that writes a task up or plans it
;; for the backlog (harness-tasks.el).  A prompt that says "only read" is
;; ignored often enough that the harness holds the line itself, the same
;; way for every such session.  A module says which of its sessions are
;; read-only by registering a policy (`harness-readonly-register'); a
;; session a policy governs has
;;
;; - only the tools its policy allows: the reading tools of
;;   `harness-readonly-read-tools', the web's of `harness-readonly-net-tools'
;;   and the policy's own.  `agent/tools' offers it no other (a filter at
;;   90, after the filters that add and remove tools for other reasons),
;;   and the `permission/decide' stage at 8 -- before the jail, the mode
;;   and the judge -- denies, for good, a call to anything else.  The stage
;;   is what holds when the model still has an old tool list, right after a
;;   session became read-only.  It fails closed: a call it cannot check is
;;   denied too, since a handler that signals would be skipped and the
;;   call then decided as if the session were not read-only;
;; - bash only when the sandbox can confine commands in its directory
;;   (`sandbox/confined-p'), and then read-only and offline: the
;;   `tools/sandbox-options' filter at 90 makes every command run with
;;   every directory read-only, no network and no Linux capability (it
;;   takes off the `:capabilities' an earlier filter added, and the
;;   sandbox gives a `:read-only' command none anyway).  Without the
;;   sandbox a read-only session has no bash at all.
;;
;; A policy is a function of a session plist.  It returns nil for a
;; session it does not govern, and for one it does a plist:
;;
;;   :tools  the names of the tools it may use besides the reading and the
;;           web ones (its own tools, a tool to hand its result in)
;;   :except the names of reading or web tools it may not use after all
;;           (web_fetch, for a session whose mode would only refuse it)
;;   :label  what its denials start with, as "supervisor mode"
;;   :doing  what the session does instead, for the denial: "plans and
;;           delegates" reads "this session plans and delegates, so it
;;           may not use write_file"
;;   :hint   what the model is told to do instead
;;
;; The first registered policy that governs a session decides; the stage
;; only refuses, so what a read-only session may do is decided by the
;; stages after it.  A module that also wants its read-only turns kept
;; short counts their tool calls and nudges them at the points
;; `harness-readonly-budget-point-p' names: the budget, then every half
;; budget after it.  That is a nudge, never a stop.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

;;;; The tools

(defconst harness-readonly-read-tools
  '("read_file" "grep" "glob" "list_dir" "file_info" "session_info" "session_history"
    "session_list" "session_read" "session_search" "task_list" "skill_search" "skill_load"
    "notification_providers" "emacs_buffers" "emacs_windows" "emacs_buffer" "emacs_describe"
    "emacs_find_definition" "emacs_messages")
  "Tools a read-only session uses to look at things.  None changes a file.")

(defconst harness-readonly-net-tools '("web_fetch" "web_search")
  "Tools a read-only session uses to read the web.")

(defconst harness-readonly-sandbox-options '(:read-only t :network nil)
  "The sandbox options of a read-only session's commands: look, don't touch.")

(defconst harness-readonly-always-tools '("drop_access")
  "Tools every read-only session keeps, whatever its policy.
They only take access away (the access module's drop_access gives up a
directory, the network or a tool), which a session may always do.")

;;;; Policies

(defvar harness-readonly--policies nil
  "The registered policies, (NAME . FUNCTION) each, in the order registered.
See `harness-readonly-register'.")

(defun harness-readonly-register (name function)
  "Make FUNCTION the read-only policy called NAME, a symbol.
FUNCTION is called with a session plist and returns nil for a session
it does not govern, else the policy for it: a plist of `:tools',
`:except', `:label', `:doing' and `:hint' (see the commentary).  A
policy already registered under NAME is replaced where it stands; a
new one goes last.  Return NAME."
  (if-let* ((cell (assq name harness-readonly--policies)))
      (setcdr cell function)
    (setq harness-readonly--policies (append harness-readonly--policies (list (cons name function)))))
  name)

(defun harness-readonly-unregister (name)
  "Forget the read-only policy called NAME."
  (setq harness-readonly--policies (cl-remove name harness-readonly--policies :key #'car)))

(defun harness-readonly-policy (session)
  "Return the policy that keeps SESSION, a plist, read-only, or nil.
That is what the first registered policy that governs it returns.  A
policy that signals is not caught here: each caller decides what that
means, and the permission stage refuses the call."
  (and session
       (cl-loop for (_name . fn) in harness-readonly--policies
                for policy = (funcall fn session)
                when policy return policy)))

(defun harness-readonly-session-p (session)
  "Non-nil when a policy keeps SESSION, a plist, read-only.
A policy that signals counts as keeping it so: refusing is the safe
side, and the error is logged."
  (condition-case err
      (and (harness-readonly-policy session) t)
    (error (harness-log 'error "readonly: asking the policies about %s failed: %S"
                        (plist-get session :id) err)
           t)))

;;;; Which tools a read-only session may use

(defun harness-readonly-dir (session)
  "Return the directory SESSION, a plist, runs commands in, host prefix and all."
  (let ((cwd (plist-get session :cwd))
        (host (plist-get session :host)))
    (if (and (stringp cwd) (stringp host) (not (string-empty-p host)) (not (file-remote-p cwd)))
        (concat host cwd)
      cwd)))

(defun harness-readonly-confined-p (dir)
  "Non-nil when commands run in DIR can be confined by the sandbox.
Bash runs read-only and offline only then, so without it a read-only
session has no bash.  Anything that goes wrong counts as not confined."
  (and dir
       (harness-method-exists-p 'sandbox/confined-p)
       (condition-case err
           (and (harness-call 'sandbox/confined-p dir) t)
         (error (harness-log 'warn "readonly: asking whether %s is confined failed: %S" dir err)
                nil))))

(defun harness-readonly-allowed-tools (policy)
  "Return the names of the tools a session under POLICY may use besides bash.
They are the reading and web tools, then the policy's own `:tools',
less the ones its `:except' names, and `harness-readonly-always-tools',
which no policy takes away."
  (let ((except (plist-get policy :except)))
    (append (cl-remove-if (lambda (name) (member name except))
                          (append harness-readonly-read-tools harness-readonly-net-tools
                                  (plist-get policy :tools)))
            harness-readonly-always-tools)))

(defun harness-readonly-tool-allowed-p (tool dir allowed)
  "Non-nil when a read-only session may use TOOL, to run in DIR when it is bash.
ALLOWED is the names of the tools it may use besides bash."
  (or (and (member tool allowed) t)
      (and (equal tool "bash") (harness-readonly-confined-p dir))))

(defun harness-readonly--tools (names session)
  "Offer a read-only SESSION only the tools it may use among NAMES.
An `agent/tools' filter at 90, after the filters that add and remove
tools for other reasons.  A session no policy governs keeps NAMES, and
so does a nil SESSION, the catalogue of every tool."
  (if-let* ((policy (and session (harness-readonly-policy session))))
      (let ((dir (harness-readonly-dir session))
            (allowed (harness-readonly-allowed-tools policy)))
        (cl-remove-if-not (lambda (name) (harness-readonly-tool-allowed-p name dir allowed)) names))
    names))

;;;; The permission stage

(defconst harness-readonly--label "read-only session"
  "What a denial starts with when no policy names a label of its own.")

(defun harness-readonly-denial (policy reason)
  "Return the decision that denies a call for good under POLICY, for REASON.
POLICY's `:label' starts the reason and its `:hint' is the hint."
  (append (list :behavior 'deny :final t
                :reason (format "%s: %s" (or (plist-get policy :label) harness-readonly--label) reason))
          (and (plist-get policy :hint) (list :hint (plist-get policy :hint)))))

(defun harness-readonly-refusal (request)
  "Return the decision that denies REQUEST in a read-only session, or nil.
A call is refused when a policy governs the session and the tool is not
one it allows, or is bash and the sandbox cannot confine the command.
Signals when a policy does."
  (let* ((session (plist-get request :session))
         (tool (plist-get request :tool))
         (policy (harness-readonly-policy session)))
    (when policy
      (let ((dir (or (car (plist-get request :paths)) (harness-readonly-dir session))))
        (unless (harness-readonly-tool-allowed-p tool dir (harness-readonly-allowed-tools policy))
          (harness-readonly-denial
           policy
           (if (equal tool "bash")
               (format "bash runs only read-only and offline here, which needs the sandbox, and the sandbox cannot confine commands in %s"
                       (or dir "this session's directory"))
             (format "this session %s, so it may not use %s"
                     (or (plist-get policy :doing) "only reads") tool))))))))

(defun harness-readonly--gate (decision next request)
  "Deny a call a read-only session may not make, then go on with NEXT.
A `permission/decide' stage at 8, before the jail, the mode and the
judge: DECISION is the current value and REQUEST the call.  The denial
is final, so no permission mode, rule or answer lets the call run.
Calls of a session no policy governs go on as they were.  A call this
stage cannot check is denied too: it fails closed, since a handler that
signals would be skipped, and the call would then be decided as if the
session were not read-only.  The stage only refuses: it allows
nothing."
  (funcall next
           (condition-case err
               (or (harness-readonly-refusal request) decision)
             (error
              (harness-log 'error "readonly: checking a call of %s failed, so it is denied: %S"
                           (plist-get request :tool) err)
              (harness-readonly-denial
               (condition-case nil (harness-readonly-policy (plist-get request :session)) (error nil))
               "this call could not be checked, so it is not made")))))

;;;; Bash

(defun harness-readonly--sandbox-options (options session-id)
  "Make the commands of a read-only session read-only and offline.
A `tools/sandbox-options' filter at 90: OPTIONS is what the handlers
before this one made, SESSION-ID the session about to run a command.
Options ask for the sandbox, so a command that cannot have it fails with
an error rather than run unconfined.  A command that changes nothing
is given no Linux capability either: the `:capabilities' an earlier
handler added (the access module's, for a session the user gave some)
are taken off, whoever put them there.  A handler that signals is
skipped, which would leave bash writable, so when anything goes wrong
here -- a policy that signals, a session nobody knows -- the answer is
read-only all the same."
  (condition-case err
      (if (harness-readonly-policy (harness-call 'session/get session-id))
          (harness-plist-merge (harness-plist-remove options :capabilities)
                               harness-readonly-sandbox-options)
        options)
    (error
     (harness-log 'error "readonly: choosing the sandbox options of %s failed, so they are read-only: %S"
                  session-id err)
     (condition-case nil
         (harness-plist-merge (harness-plist-remove options :capabilities)
                              harness-readonly-sandbox-options)
       (error (copy-sequence harness-readonly-sandbox-options))))))

;;;; The system prompt

(defvar harness-tools-agent-planning-section)

(defun harness-readonly-system-prompt (prompt section)
  "Return PROMPT with SECTION, a read-only session's own, in place of Planning.
The Planning section (`harness-tools-agent-planning-section', which the
tools-agent module adds) tells a session to plan its work with the plan
tool and to split it among forks and sub-agents: tools a read-only
session does not have.  SECTION says what the session does instead.  A
PROMPT without the Planning section gets SECTION at its end."
  (let* ((planning (and (boundp 'harness-tools-agent-planning-section)
                        (stringp harness-tools-agent-planning-section)
                        (not (string-empty-p harness-tools-agent-planning-section))
                        harness-tools-agent-planning-section))
         (start (and planning (string-search planning prompt))))
    (if start
        (concat (substring prompt 0 start) section (substring prompt (+ start (length planning))))
      (concat prompt "\n\n" section "\n"))))

;;;; Budgets

(defun harness-readonly-budget-point-p (n budget &optional every)
  "Non-nil when N tool calls of a turn call for a nudge, on a BUDGET.
That is when N reaches BUDGET, and then every EVERY calls after it --
by default half the budget, one at least.  A BUDGET that is not a
positive number never nudges.  A read-only turn is told to wrap up at
these points: a nudge, never a stop."
  (and (integerp budget) (> budget 0) (integerp n) (>= n budget)
       (let ((every (if (and (integerp every) (> every 0)) every (max 1 (/ budget 2)))))
         (zerop (mod (- n budget) every)))))

;;;; Module

(defun harness-readonly--init ()
  "Hook the module into the bus (idempotent)."
  (harness-add-filter 'agent/tools #'harness-readonly--tools 90)
  (harness-add-filter 'permission/decide #'harness-readonly--gate 8)
  ;; Late, so the options of the handlers before it cannot undo its own.
  (harness-add-filter 'tools/sandbox-options #'harness-readonly--sandbox-options 90))

(defun harness-readonly--shutdown ()
  "Take the module off the bus.  The policies stay registered."
  (harness-remove-filter 'agent/tools #'harness-readonly--tools)
  (harness-remove-filter 'permission/decide #'harness-readonly--gate)
  (harness-remove-filter 'tools/sandbox-options #'harness-readonly--sandbox-options))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'readonly)
  (harness-readonly--init))

(harness-define-module 'readonly
  :doc "Read-only sessions: the sessions a module's policy names (a supervisor, a task's write-up or plan) get only reading tools and read-only, offline bash, enforced by the harness."
  :requires '(session tools)
  :init #'harness-readonly--init
  :shutdown #'harness-readonly--shutdown)

(provide 'harness-readonly)
;;; harness-readonly.el ends here
