;;; harness-perms.el --- Permission decisions for tool calls  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool call goes through the asynchronous filter
;; `permission/decide' before it runs (see `tools/execute').  This
;; module installs the chain that turns the initial `ask' into a
;; decision:
;;
;;   10 jail             every path must lie inside an allowed root;
;;                       otherwise the user is asked for the directory
;;   20 mode             ask / accept-edits / auto / yolo, plus standing rules
;;   30 auto             a cheap model judges what is still undecided
;;   40 non-interactive  the user is away: deny and steer the agent
;;   90 ask-user         a pending request the UI answers
;;
;; A handler receives (DECISION NEXT REQUEST) and must call NEXT with
;; the new decision; `:final' stops the chain.  Denials always carry a
;; `:reason' and, when there is something the model can do about it, a
;; `:hint', because a denial the model can act on is the difference
;; between an autonomous session and one that stalls.
;;
;; The module works without the session and agent modules: methods it
;; needs from them are looked up with `harness-method-exists-p'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-config)
(require 'harness-tools)

(defvar harness-state-directory)

;;;; Customisation

(defcustom harness-perms-auto-allow-tools
  '("ask_user" "plan" "todo_write" "skill_search" "skill_load"
    "emacs_buffers" "emacs_describe" "emacs_messages")
  "Tools that never need approval, in every permission mode."
  :type '(repeat string) :group 'harness)

(defcustom harness-perms-rules nil
  "Standing permission rules that apply to every session.
Each rule is a plist (:tool NAME :kind KIND :behavior allow|deny).
NAME is a tool name or nil for any tool; KIND is a tool kind or nil
for any kind.  The first matching rule wins.  Rules are added here
when a permission request is answered with scope `always'."
  :type '(repeat (plist :key-type (choice (const :tool) (const :kind) (const :behavior))
                        :value-type sexp))
  :group 'harness)

(defcustom harness-perms-auto-model "claude:claude-haiku-4-5-20251001"
  "Model that judges tool calls in `auto' mode, as PROVIDER:NAME.
When nil the session's own model is used."
  :type '(choice (const nil) string) :group 'harness)

(defcustom harness-perms-auto-timeout 30
  "Seconds the auto-mode judge may take before the call falls back to asking."
  :type 'number :group 'harness)

;;;; Runtime state (survives reloads)

(defvar harness-perms--allowed-dirs (make-hash-table :test 'equal)
  "Session id -> list of directories granted at runtime.")

(defvar harness-perms--session-rules (make-hash-table :test 'equal)
  "Session id -> list of rule plists answered with scope `session'.")

(defvar harness-perms--waiting (make-hash-table :test 'equal)
  "Pending id -> plist (:session-id :request :next) awaiting an answer.")

(defvar harness-perms--steered nil
  "Recent call ids that already received a non-interactive steering message.")

(defconst harness-perms-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered to the user for a permission request.")

(defconst harness-perms-dir-options '(allow-once allow-session allow-always deny-once)
  "Answer options offered when a tool call reaches outside the allowed directories.
`allow-session' grants the directory to the session, `allow-always'
adds it to `harness-allowed-directories'.")

;;;; Small helpers

(defun harness-perms--sym (value)
  "Return VALUE as a symbol; strings from the wire are interned."
  (cond ((null value) nil)
        ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))

(defun harness-perms--session (session-id)
  "Return the session plist for SESSION-ID, or a minimal stand-in."
  (or (and session-id (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get session-id)))
      (list :id session-id :cwd (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-perms--config (key session)
  "Return config KEY for SESSION, through `config/get' when available."
  (let ((cwd (or (plist-get session :cwd) default-directory)))
    (if (harness-method-exists-p 'config/get)
        (condition-case nil (harness-call 'config/get key cwd)
          (error (symbol-value key)))
      (symbol-value key))))

(defun harness-perms--mode-of (session)
  "Return the effective permission mode symbol for SESSION."
  (or (harness-perms--sym (plist-get session :permission-mode))
      (harness-perms--sym (harness-perms--config 'harness-permission-mode session))
      'ask))

(defun harness-perms--non-interactive-p (session)
  "Non-nil when SESSION should never wait for the user."
  (or (harness-json-true-p (plist-get session :non-interactive))
      (harness-json-true-p (harness-perms--config 'harness-non-interactive session))))

;;;; Roots and the jail

(defun harness-perms--split (path)
  "Return (HOST . LOCAL) for PATH; HOST is nil for a local path."
  (let ((host (file-remote-p path)))
    (if host
        (cons host (or (file-remote-p path 'localname) "/"))
      (cons nil path))))

(defun harness-perms--with-host (path host)
  "Return PATH prefixed with HOST unless it is already remote or HOST is nil."
  (if (and host (not (file-remote-p path))) (concat host path) path))

(defun harness-perms--within-p (root path)
  "Non-nil when PATH lies inside ROOT.
Remote paths only match when the hosts are the same; then the local
parts are compared."
  (pcase-let ((`(,rh . ,rl) (harness-perms--split root))
              (`(,ph . ,pl) (harness-perms--split path)))
    (and (equal rh ph)
         (if rh
             (let ((dir (file-name-as-directory (expand-file-name rl "/")))
                   (p (expand-file-name pl "/")))
               (or (string= (file-name-as-directory p) dir)
                   (string-prefix-p dir p)))
           (harness-path-within-p rl pl)))))

(defun harness-perms--granted (session)
  "Return the directories granted to SESSION at runtime.
Grants live on the session record (`:allowed-dirs') so they survive a
restart; without a session module they live in
`harness-perms--allowed-dirs'."
  (cl-remove-duplicates
   (append (plist-get session :allowed-dirs)
           (gethash (plist-get session :id) harness-perms--allowed-dirs))
   :test #'equal :from-end t))

(defun harness-perms-dirs (session)
  "Return the directories SESSION may touch as (:dir DIR :source SOURCE).
SOURCE is `cwd', `worktree', `config' (`harness-allowed-directories'),
`session' (granted at runtime) or `outputs'."
  (let* ((cwd (or (plist-get session :cwd) default-directory))
         (host (plist-get session :host))
         (expand (lambda (d) (harness-perms--with-host
                              (file-name-as-directory (expand-file-name d cwd)) host)))
         (entry (lambda (source) (lambda (d) (list :dir (funcall expand d) :source source))))
         (entries (append (list (funcall (funcall entry 'cwd) cwd))
                          (and (plist-get session :worktree)
                               (list (funcall (funcall entry 'worktree) (plist-get session :worktree))))
                          (mapcar (funcall entry 'config)
                                  (harness-perms--config 'harness-allowed-directories session))
                          (mapcar (funcall entry 'session) (harness-perms--granted session))
                          (list (list :dir (file-name-as-directory
                                            (expand-file-name "outputs" harness-state-directory))
                                      :source 'outputs)))))
    (cl-remove-duplicates entries :test #'equal :key (lambda (e) (plist-get e :dir)) :from-end t)))

(defun harness-perms-roots (session)
  "Return the directories SESSION may touch.
That is its cwd, its worktree, `harness-allowed-directories', the
directories granted at runtime and the tool output directory."
  (mapcar (lambda (e) (plist-get e :dir)) (harness-perms-dirs session)))

(defun harness-perms--outside (paths roots)
  "Return the first of PATHS that is not inside any of ROOTS, or nil."
  (cl-find-if (lambda (p) (not (cl-some (lambda (r) (harness-perms--within-p r p)) roots)))
              paths))

(defun harness-perms--dir-of (path)
  "Return the directory to grant so that PATH becomes reachable."
  ;; Never touch the file system for a remote path: that would open
  ;; a TRAMP connection from inside the permission chain.
  (if (and (not (file-remote-p path)) (file-directory-p path))
      (file-name-as-directory path)
    (or (file-name-directory path) path)))

(defun harness-perms--jail (decision next request)
  "Pass REQUEST on when its paths lie inside the session's roots.
Otherwise ask the user for access to the directory, or deny when
nobody can answer.  DECISION is the current value and NEXT continues
the chain.  Directories in the request's `:jail-once' were allowed
for this call only."
  (let ((paths (plist-get request :paths)))
    (if (null paths)
        (funcall next decision)
      (let* ((session (plist-get request :session))
             (roots (append (harness-perms-roots session) (plist-get request :jail-once)))
             (bad (harness-perms--outside paths roots)))
        (cond
         ((null bad) (funcall next decision))
         ((and (not (harness-perms--non-interactive-p session))
               (harness-method-exists-p 'session/pending-add))
          (harness-perms--ask-dir decision next request bad))
         (t
          (funcall next
                   (list :behavior 'deny :final t
                         :reason (format "%s is outside the allowed directories" bad)
                         :hint (format "Allowed roots: %s. Work inside them, or ask the user to grant access to %s with the allow-dir command."
                                       (mapconcat #'abbreviate-file-name roots ", ")
                                       (abbreviate-file-name (harness-perms--dir-of bad)))))))))))

(defun harness-perms--ask-dir (decision next request bad)
  "Ask the user to grant the directory holding BAD to REQUEST's session.
DECISION and NEXT continue the chain once `permission/answer' arrives."
  (let* ((sid (plist-get (plist-get request :session) :id))
         (dir (harness-perms--dir-of bad))
         (pending (list :kind 'permission
                        :payload (list :tool (plist-get request :tool)
                                       :input (plist-get request :input)
                                       :kind (plist-get request :kind)
                                       :paths (plist-get request :paths)
                                       :call-id (plist-get request :call-id)
                                       :dir dir
                                       :title (format "Access %s" (abbreviate-file-name dir))
                                       :reason (format "%s wants %s, which is outside the allowed directories"
                                                       (plist-get request :tool) (abbreviate-file-name bad))
                                       :options harness-perms-dir-options)))
         (pid (harness-call 'session/pending-add sid pending)))
    (puthash pid (list :session-id sid :request request :next next :dir dir :decision decision)
             harness-perms--waiting)
    (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid))))

(defun harness-perms--answer-dir (session-id waiting answer)
  "Continue the jail for WAITING of SESSION-ID after the user's ANSWER.
Return the denial, or `continue' when the chain goes on."
  (let ((request (plist-get waiting :request))
        (dir (plist-get waiting :dir))
        (next (plist-get waiting :next)))
    (if (not (eq (plist-get answer :behavior) 'allow))
        (let ((d (list :behavior 'deny :final t
                       :reason (or (plist-get answer :reason)
                                   (format "the user denied access to %s" (abbreviate-file-name dir)))
                       :hint "Do not retry; work inside the allowed directories.")))
          (funcall next d)
          d)
      (pcase (plist-get answer :scope)
        ('session (harness-call 'permission/allow-dir session-id dir))
        ('always (harness-call 'permission/allow-dir session-id dir 'always))
        (_ (setq request (plist-put (copy-sequence request) :jail-once
                                    (cons dir (plist-get request :jail-once))))))
      ;; Check again with the fresh session: other paths may lie elsewhere.
      (harness-perms--jail (plist-get waiting :decision) next
                           (plist-put (copy-sequence request) :session (harness-perms--session session-id)))
      'continue)))

;;;; Mode and standing rules

(defun harness-perms--rule-matches-p (rule request)
  "Non-nil when RULE applies to REQUEST."
  (let ((tool (plist-get rule :tool))
        (kind (harness-perms--sym (plist-get rule :kind))))
    (and (or (null tool) (equal tool (plist-get request :tool)))
         (or (null kind) (eq kind (harness-perms--sym (plist-get request :kind)))))))

(defun harness-perms--find-rule (request)
  "Return the first session or global rule that applies to REQUEST."
  (let ((sid (plist-get (plist-get request :session) :id)))
    (cl-find-if (lambda (r) (harness-perms--rule-matches-p r request))
                (append (gethash sid harness-perms--session-rules) harness-perms-rules))))

(defun harness-perms--save-rules ()
  "Persist `harness-perms-rules' in the user's custom file."
  (harness-save-user-option 'harness-perms-rules harness-perms-rules))

(defun harness-perms-add-rule (session-id rule scope)
  "Record RULE for SESSION-ID with SCOPE (`session' or `always')."
  (pcase scope
    ('session
     (puthash session-id (cons rule (cl-remove rule (gethash session-id harness-perms--session-rules)
                                               :test #'equal))
              harness-perms--session-rules))
    ('always
     (setq harness-perms-rules (cons rule (cl-remove rule harness-perms-rules :test #'equal)))
     (harness-perms--save-rules)))
  rule)

(defun harness-perms--mode-decision (decision request)
  "Return the decision for REQUEST from the mode and the standing rules.
DECISION is returned unchanged when the mode leaves the question open."
  (let* ((session (plist-get request :session))
         (tool (plist-get request :tool))
         (kind (harness-perms--sym (plist-get request :kind)))
         (mode (harness-perms--mode-of session))
         (rule (harness-perms--find-rule request)))
    (cond
     ((member tool harness-perms-auto-allow-tools)
      (list :behavior 'allow :reason (format "%s never needs approval" tool)))
     (rule
      (if (eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
          (list :behavior 'deny :reason (format "denied by a standing rule for %s" (or (plist-get rule :tool) "every tool"))
                :hint "Do not retry this call; choose a different approach.")
        (list :behavior 'allow :reason (format "allowed by a standing rule for %s" (or (plist-get rule :tool) "every tool")))))
     ((eq mode 'yolo) (list :behavior 'allow :reason "yolo mode"))
     ((and (eq mode 'accept-edits) (memq kind '(read write)))
      (list :behavior 'allow :reason (format "%ss inside the allowed directories are accepted" kind)))
     ;; Auto mode is a superset of ask: jailed reads need no judge.
     ((and (memq mode '(ask auto)) (eq kind 'read))
      (list :behavior 'allow :reason "reads inside the allowed directories are allowed"))
     (t decision))))

(defun harness-perms--mode (decision next request)
  "Apply the permission mode and standing rules to REQUEST.
DECISION is the current value and NEXT continues the chain."
  (funcall next (if (eq (plist-get decision :behavior) 'ask)
                    (harness-perms--mode-decision decision request)
                  decision)))

;;;; Auto mode: a cheap model judges

(defconst harness-perms--judge-system
  "You are the permission judge for an autonomous coding agent running inside Emacs.
The agent wants to run a tool.  Decide whether the call is safe and within the
user's evident intent.  Allow ordinary development work inside the allowed
directories.  Deny anything destructive or irreversible outside the project
(deleting or overwriting unrelated files, force pushes, changing system
configuration, exfiltrating secrets, network calls to unexpected hosts, or
installing software system-wide).  When unsure, deny with a reason the agent
can act on.  Reply with exactly one line of JSON and nothing else:
{\"decision\":\"allow\"|\"deny\",\"reason\":\"one short sentence\"}"
  "System prompt for the auto-mode judge.")

(defun harness-perms--judge-text (request)
  "Return the user message describing REQUEST for the judge."
  (let* ((tool (plist-get request :tool))
         (spec (and (harness-method-exists-p 'tools/get) (harness-call 'tools/get tool)))
         (session (plist-get request :session)))
    (format "Tool: %s\nKind: %s\nDescription: %s\n\nInput (JSON):\n%s\n\nWorking directory: %s\nAllowed roots:\n%s\n\nAnswer with one line of JSON: {\"decision\":\"allow\"|\"deny\",\"reason\":\"...\"}"
            tool (plist-get request :kind)
            (or (plist-get spec :description) "(no description)")
            (harness-truncate-end (harness-json-encode (or (plist-get request :input) :empty)) 4000)
            (or (plist-get session :cwd) default-directory)
            (mapconcat (lambda (r) (concat "- " r)) (harness-perms-roots session) "\n"))))

(defun harness-perms--parse-verdict (text)
  "Return (:behavior allow|deny :reason R) from the first JSON object in TEXT.
Return nil when TEXT holds no usable verdict."
  (when (and text (string-match "{[^{}]*}" text))
    (let* ((obj (condition-case nil (harness-json-parse (match-string 0 text)) (error nil)))
           (decision (and (listp obj) (plist-get obj :decision)))
           (reason (and (listp obj) (plist-get obj :reason))))
      (pcase (and (stringp decision) (downcase decision))
        ("allow" (list :behavior 'allow :reason (or reason "allowed by the auto-mode judge")))
        ("deny" (list :behavior 'deny :reason (or reason "denied by the auto-mode judge")
                      :hint "Choose a different approach that stays within the allowed scope."))))))

(defun harness-perms--auto (decision next request)
  "In `auto' mode ask a cheap model to decide REQUEST; fall back to asking.
DECISION is the current value and NEXT continues the chain."
  (let ((session (plist-get request :session)))
    (if (not (and (eq (plist-get decision :behavior) 'ask)
                  (eq (harness-perms--mode-of session) 'auto)
                  (harness-method-exists-p 'provider/complete)))
        (funcall next decision)
      (let* ((model (or harness-perms-auto-model (plist-get session :model)
                        (harness-perms--config 'harness-model session)))
             (text "") (settled nil) (timer nil) (handle nil)
             (finish (lambda (d)
                       (unless settled
                         (setq settled t)
                         (when timer (cancel-timer timer))
                         (funcall next d)))))
        (setq timer (run-at-time harness-perms-auto-timeout nil
                                 (lambda ()
                                   (harness-log 'warn "perms: auto judge timed out for %s" (plist-get request :tool))
                                   (funcall finish decision)
                                   (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
        (condition-case err
            (setq handle
                  (harness-call
                   'provider/complete
                   (list :model model
                         :session (list :id (format "%s-perms" (plist-get session :id))
                                        :cwd (plist-get session :cwd) :host (plist-get session :host))
                         :system harness-perms--judge-system
                         :messages (list (list :role 'user
                                               :content (list (list :type "text"
                                                                    :text (harness-perms--judge-text request)))))
                         :tools nil :max-tokens 200
                         :on-event (lambda (ev)
                                     (pcase (plist-get ev :type)
                                       ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                                       ('done
                                        (let ((verdict (and (eq (plist-get ev :stop-reason) 'end-turn)
                                                            (harness-perms--parse-verdict text))))
                                          (unless verdict
                                            (harness-log 'warn "perms: auto judge gave no verdict (%s): %s"
                                                         (plist-get ev :stop-reason) (harness-truncate-end text 200)))
                                          (funcall finish (or verdict decision)))))))))
          (error
           (harness-log 'warn "perms: auto judge failed: %S" err)
           (funcall finish decision)))))))

;;;; Non-interactive mode

(defconst harness-perms-non-interactive-hint
  "Find a different approach that stays inside the permitted scope and still achieves the goal; do not wait for the user."
  "Hint attached to denials made because the user is away.")

(defun harness-perms--steer (session request)
  "Send SESSION a steering message about the denied REQUEST, once per call."
  (let ((sid (plist-get session :id))
        (call-id (or (plist-get request :call-id) (harness-short-id))))
    (when (and (harness-method-exists-p 'agent/prompt)
               (not (member call-id harness-perms--steered)))
      (push call-id harness-perms--steered)
      (setq harness-perms--steered (seq-take harness-perms--steered 100))
      (condition-case err
          (harness-call 'agent/prompt sid
                        (list (list :type "text"
                                    :text (format "The call to %s was denied because the session runs in non-interactive mode and the user is away. %s"
                                                  (plist-get request :tool) harness-perms-non-interactive-hint))))
        (error (harness-log 'warn "perms: steering failed: %S" err))))))

(defun harness-perms--non-interactive (decision next request)
  "Deny an undecided REQUEST when the user is away, and steer the agent.
DECISION is the current value and NEXT continues the chain."
  (let ((session (plist-get request :session)))
    (if (and (eq (plist-get decision :behavior) 'ask)
             (harness-perms--non-interactive-p session))
        (progn
          (harness-perms--steer session request)
          (funcall next (list :behavior 'deny
                              :reason "non-interactive mode: the user is away"
                              :hint harness-perms-non-interactive-hint)))
      (funcall next decision))))

;;;; Asking the user

(defun harness-perms-describe-request (request)
  "Return a one-line human title for permission REQUEST."
  (harness-first-line (harness-tool-title (plist-get request :tool) (plist-get request :input)) 100))

(defun harness-perms--ask (decision next request)
  "Turn an undecided REQUEST into a pending request the user answers.
DECISION is the current value and NEXT continues the chain once
`permission/answer' arrives.  Without a session module the call is
denied because nobody can answer."
  (let* ((session (plist-get request :session))
         (sid (plist-get session :id)))
    (cond
     ((not (eq (plist-get decision :behavior) 'ask)) (funcall next decision))
     ((not (harness-method-exists-p 'session/pending-add))
      (funcall next (list :behavior 'deny :reason "no user available")))
     (t
      (let* ((pending (list :kind 'permission
                            :payload (list :tool (plist-get request :tool)
                                           :input (plist-get request :input)
                                           :kind (plist-get request :kind)
                                           :paths (plist-get request :paths)
                                           :call-id (plist-get request :call-id)
                                           :title (harness-perms-describe-request request)
                                           :options harness-perms-options)))
             (pid (harness-call 'session/pending-add sid pending)))
        (puthash pid (list :session-id sid :request request :next next) harness-perms--waiting)
        (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid)))))))

(defun harness-perms--parse-answer (answer)
  "Normalise ANSWER into (:behavior allow|deny :scope once|session|always :reason).
Accepts a plist, or an option id like \"allow-session\" as a string or
under `:option'."
  (let* ((option (cond ((stringp answer) answer)
                       ((symbolp answer) (symbol-name answer))
                       ((plist-get answer :option) (format "%s" (plist-get answer :option)))))
         (parts (and option (split-string option "-")))
         (behavior (or (and (listp answer) (harness-perms--sym (plist-get answer :behavior)))
                       (and parts (intern (car parts)))
                       'deny))
         (scope (or (and (listp answer) (harness-perms--sym (plist-get answer :scope)))
                    (and (cadr parts) (intern (cadr parts)))
                    'once)))
    (list :behavior (if (eq behavior 'allow) 'allow 'deny)
          :scope (if (memq scope '(once session always)) scope 'once)
          :reason (and (listp answer) (plist-get answer :reason)))))

(harness-defmethod permission/answer (session-id pending-id answer)
  "Answer the permission request PENDING-ID of SESSION-ID with ANSWER.
ANSWER is (:behavior allow|deny :scope once|session|always :reason).
Resolves the pending request, records session or standing rules and
lets the tool call continue.  Return the final decision."
  (let ((waiting (gethash pending-id harness-perms--waiting)))
    (unless waiting
      (signal 'harness-error (list (format "no pending permission %s" pending-id))))
    (remhash pending-id harness-perms--waiting)
    (if (plist-get waiting :dir)
        (let ((answer (harness-perms--parse-answer answer)))
          (harness-perms--resolve session-id pending-id answer)
          (harness-perms--answer-dir session-id waiting answer))
      (harness-perms--answer-tool session-id pending-id waiting answer))))

(defun harness-perms--resolve (session-id pending-id answer)
  "Mark PENDING-ID of SESSION-ID resolved with ANSWER."
  (when (harness-method-exists-p 'session/pending-resolve)
    (condition-case err
        (harness-call 'session/pending-resolve session-id pending-id answer)
      (error (harness-log 'warn "perms: pending-resolve failed: %S" err)))))

(defun harness-perms--answer-tool (session-id pending-id waiting answer)
  "Answer the tool permission WAITING (PENDING-ID of SESSION-ID) with ANSWER.
Record session or standing rules and let the tool call continue."
  (let* ((answer (harness-perms--parse-answer answer))
         (request (plist-get waiting :request))
         (behavior (plist-get answer :behavior))
         (scope (plist-get answer :scope))
         (decision (list :behavior behavior :final t
                         :reason (or (plist-get answer :reason)
                                     (if (eq behavior 'allow) "allowed by the user"
                                       "denied by the user")))))
    (when (memq scope '(session always))
      (harness-perms-add-rule session-id (list :tool (plist-get request :tool) :behavior behavior) scope))
    (harness-perms--resolve session-id pending-id answer)
    (funcall (plist-get waiting :next) decision)
    decision))

;;;; Methods for UIs and the agent

(defun harness-perms--expand-dir (session dir)
  "Return DIR expanded against SESSION's cwd, as a directory name."
  (file-name-as-directory (expand-file-name dir (plist-get session :cwd))))

(defun harness-perms--set-granted (session-id dirs)
  "Make DIRS the runtime grants of SESSION-ID.
They are stored on the session record when there is one."
  (if (and (harness-method-exists-p 'session/update)
           (ignore-errors (harness-call 'session/get session-id)))
      (progn (remhash session-id harness-perms--allowed-dirs)
             (harness-call 'session/update session-id :allowed-dirs dirs :silent t))
    (puthash session-id dirs harness-perms--allowed-dirs)))

(defun harness-perms--global-dirs (session)
  "Return the global `harness-allowed-directories', expanded for SESSION."
  (mapcar (lambda (d) (harness-perms--expand-dir session d))
          (default-value 'harness-allowed-directories)))

(harness-defmethod permission/allow-dir (session-id dir &optional scope)
  "Grant SESSION-ID access to DIR.
With SCOPE `always' DIR is added to the global
`harness-allowed-directories'; otherwise the grant is kept with the
session.  Return the session's effective roots."
  (let* ((session (harness-perms--session session-id))
         (dir (harness-perms--expand-dir session dir)))
    (if (eq (harness-perms--sym scope) 'always)
        (unless (member dir (harness-perms--global-dirs session))
          (harness-save-user-option 'harness-allowed-directories
                                    (append (default-value 'harness-allowed-directories) (list dir))))
      (let ((granted (harness-perms--granted session)))
        (unless (member dir granted)
          (harness-perms--set-granted session-id (append granted (list dir))))))
    (harness-emit 'permission/dir-allowed session-id dir)
    (harness-perms-roots (harness-perms--session session-id))))

(harness-defmethod permission/revoke-dir (session-id dir)
  "Withdraw DIR from SESSION-ID.
Removes a session grant, or else the entry in the global
`harness-allowed-directories'.  The cwd, the worktree and directories
set in a project's .dir-locals.el cannot be revoked here.  Return the
session's effective roots."
  (let* ((session (harness-perms--session session-id))
         (dir (harness-perms--expand-dir session dir))
         (granted (harness-perms--granted session))
         (global (default-value 'harness-allowed-directories)))
    (cond
     ((member dir granted)
      (harness-perms--set-granted session-id (remove dir granted)))
     ((member dir (harness-perms--global-dirs session))
      (harness-save-user-option
       'harness-allowed-directories
       (cl-remove-if (lambda (d) (equal dir (harness-perms--expand-dir session d))) global)))
     (t (signal 'harness-error
                (list (format "%s is not a grant (it comes from the cwd, the worktree or .dir-locals.el)"
                              (abbreviate-file-name dir))))))
    (harness-emit 'permission/dir-revoked session-id dir)
    (harness-perms-roots (harness-perms--session session-id))))

(harness-defmethod permission/allowed-dirs (session-id)
  "Return every directory SESSION-ID may touch."
  (harness-perms-roots (harness-perms--session session-id)))

(harness-defmethod permission/dirs (session-id)
  "Return the directories SESSION-ID may touch as (:dir :source :revocable).
SOURCE is as in `harness-perms-dirs'.  An entry is revocable when it
is a session grant or comes from the global `harness-allowed-directories'."
  (let* ((session (harness-perms--session session-id))
         (global (harness-perms--global-dirs session)))
    (mapcar (lambda (e)
              (append e (list :revocable
                              (and (or (eq (plist-get e :source) 'session)
                                       (and (eq (plist-get e :source) 'config)
                                            (member (plist-get e :dir) global)))
                                   t))))
            (harness-perms-dirs session))))

(harness-defmethod permission/rules (session-id)
  "Return the effective permission rules of SESSION-ID for display.
The result is (:mode MODE :non-interactive BOOL :auto-allow TOOLS
:session RULES :always RULES :roots DIRS)."
  (let ((session (harness-perms--session session-id)))
    (list :mode (harness-perms--mode-of session)
          :non-interactive (and (harness-perms--non-interactive-p session) t)
          :auto-allow harness-perms-auto-allow-tools
          :session (gethash session-id harness-perms--session-rules)
          :always harness-perms-rules
          :roots (harness-perms-roots session))))

(harness-defmethod permission/pending (session-id)
  "Return the permission requests of SESSION-ID still waiting for an answer."
  (if (harness-method-exists-p 'session/pending)
      (cl-remove-if-not (lambda (p) (eq (harness-perms--sym (plist-get p :kind)) 'permission))
                        (harness-call 'session/pending session-id))
    (let (out)
      (maphash (lambda (pid w)
                 (when (equal (plist-get w :session-id) session-id)
                   (let ((r (plist-get w :request)))
                     (push (list :id pid :kind 'permission
                                 :payload (list :tool (plist-get r :tool) :input (plist-get r :input)
                                                :kind (plist-get r :kind) :paths (plist-get r :paths)
                                                :title (harness-perms-describe-request r)
                                                :options harness-perms-options))
                           out))))
               harness-perms--waiting)
      out)))

;;;; Module

(harness-declare-event 'permission/requested
                       "(SESSION-ID PENDING) when a tool call waits for the user's answer.")
(harness-declare-event 'permission/dir-allowed
                       "(SESSION-ID DIR) after `permission/allow-dir' widened the jail.")
(harness-declare-event 'permission/dir-revoked
                       "(SESSION-ID DIR) after `permission/revoke-dir' narrowed the jail.")

(defun harness-perms--init ()
  "Install the `permission/decide' chain.  Safe to call again."
  (harness-add-filter 'permission/decide #'harness-perms--jail 10)
  (harness-add-filter 'permission/decide #'harness-perms--mode 20)
  (harness-add-filter 'permission/decide #'harness-perms--auto 30)
  (harness-add-filter 'permission/decide #'harness-perms--non-interactive 40)
  (harness-add-filter 'permission/decide #'harness-perms--ask 90))

(defun harness-perms--shutdown ()
  "Remove the `permission/decide' chain."
  (dolist (fn '(harness-perms--jail harness-perms--mode harness-perms--auto
                harness-perms--non-interactive harness-perms--ask))
    (harness-remove-filter 'permission/decide fn)))

(harness-define-module 'perms
  :doc "Directory jail, permission modes, auto judge and user prompts."
  :requires '(config tools)
  :init #'harness-perms--init
  :shutdown #'harness-perms--shutdown)

(provide 'harness-perms)
;;; harness-perms.el ends here
