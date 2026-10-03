;;; harness-perms.el --- Permission decisions for tool calls  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool call goes through the asynchronous filter
;; `permission/decide' before it runs (see `tools/execute').  This
;; module installs the chain that turns the initial `ask' into a
;; decision:
;;
;;    5 dir-request      request_directory_access: the user's answer decides
;;    7 sandbox-guard    shell commands the sandbox would make destructive
;;                       (`git worktree prune' and the like) are refused
;;   10 jail             every path must lie inside an allowed root;
;;                       otherwise the user is asked for the directory
;;   20 mode             ask / accept-edits / auto / yolo, plus standing rules
;;   30 auto             a cheap model judges what is still undecided, in
;;                       auto mode and in every non-interactive session
;;   40 non-interactive  the judge gave no verdict and the user is away:
;;                       nobody can approve the call, so it is denied
;;   90 ask-user         a pending request the UI answers
;;
;; A handler receives (DECISION NEXT REQUEST) and must call NEXT with
;; the new decision; `:final' stops the chain.  Denials always carry a
;; `:reason' and, when there is something the model can do about it, a
;; `:hint', because a denial the model can act on is the difference
;; between an autonomous session and one that stalls.  Other modules
;; add stages of their own: the tasks module keeps the turns that write
;; a backlog task up read-only at 25.
;;
;; Non-interactive mode (the user is away) is no permission policy of
;; its own: what the session's mode would ask the user, the auto-mode
;; judge decides in their place, whatever the mode, so the session
;; never waits and is never refused just for being unattended.  Only a
;; call the judge gave no verdict on is denied, since nobody could
;; approve it; directories are still granted by a person only.  After
;; every denial in such a session, whoever made it, the agent gets a
;; steering message (`harness-perms--on-decided'): the user is away, so
;; it should find another way rather than wait.
;;
;; An agent asks for another directory with the request_directory_access
;; tool.  The first stage owns that tool's decision and always makes it
;; final, so the call never reaches the mode, the standing rules or the
;; auto-mode judge: in every mode, yolo and auto included, a directory is
;; granted only by a person answering the prompt.
;;
;; A prompt about paths is answered for a glob pattern, not for one
;; file: by default everything in the directory (`DIR/**'), the one
;; holding the file or the directory itself.  The user may edit it,
;; more or less specific, before answering.  A directory prompt grants
;; or denies the pattern; a tool prompt's answers for the session or
;; for always record a rule for the tool on the pattern (`:path').
;; Roots and rules alike are directories or patterns (see
;; `harness-perms--within-p').
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

(defconst harness-perms--auto-allow-tools
  '("ask_user" "plan" "todo_write" "skill_search" "skill_load"
    "emacs_buffers" "emacs_describe" "emacs_messages" "web_search" "notify")
  "Tools that never need approval, in every permission mode.
`web_search' is included because it only sends its query to the
configured `harness-websearch-provider', so even unattended task
sessions can look things up; `web_fetch' is not, because it reaches
whatever URL the agent names.  `notify' only reaches the user, through
the notification providers they set up, so unattended sessions can
tell them when they are needed.  Standing rules in `harness-perms-rules'
are checked first and can still deny any of these tools.")

(defcustom harness-perms-rules nil
  "Standing permission rules that apply to every session.
Each rule is a plist (:tool NAME :kind KIND :path PATTERN :behavior
allow|deny).  NAME is a tool name or nil for any tool; KIND is a tool
kind or nil for any kind.  PATTERN, when there is one, limits the rule
to calls with paths: a glob (`*' within a name, `**' across
directories) or a directory, which stands for everything in it,
absolute or relative to the session's working directory.  An allow
rule then needs every path of the call to match it, a deny rule any
one.  The first matching rule wins.  Rules are added here when a
permission request is answered with scope `always'; for a call with
paths, they hold for the pattern of the prompt."
  :type '(repeat
          (plist
           :tag "Rule"
           :value (:behavior deny)
           :options
           ((:tool (choice :tag "Tool" :value "web_search"
                           :doc "Name of the tool the rule is about."
                           (const :tag "Any tool" nil) (string :tag "Tool name")))
            (:kind (choice :tag "Kind" :value exec
                           :doc "Kind of call the rule is about."
                           (const :tag "Any kind" nil) (const :tag "Read" read) (const :tag "Write" write)
                           (const :tag "Exec" exec) (const :tag "Net" net) (const :tag "Meta" meta)
                           (symbol :tag "Other kind")))
            (:path (string :tag "Path pattern" :value "docs/**"
                           :doc "Glob the call's paths must match, such as ~/notes/** or src/*.el."))
            (:behavior (choice :tag "Decision" :value deny
                               :doc "What the rule decides."
                               (const :tag "Allow" allow) (const :tag "Deny" deny)
                               (string :tag "Other name"))))))
  :group 'harness)

(defcustom harness-perms-auto-model 'auto
  "Model that judges tool calls, as PROVIDER:NAME, or `auto'.
It judges in `auto' mode, and in every mode for a non-interactive
session, deciding what would ask the user while they are away.
`auto' (the default) asks the session's provider for its `cheap' tier
\(see `harness-provider-tier-model'), so the judge runs on a model the
session's provider can actually serve, falling back to the session's
own model when the provider names none and its prices are unknown.  A
PROVIDER:NAME forces that model, and nil uses the session's own model."
  :type '(choice (const :tag "The session provider's cheap model" auto)
                 (const :tag "The session's own model" nil)
                 (string :tag "Model"))
  :group 'harness)

(defconst harness-perms--auto-timeout 30
  "Seconds one auto-mode judge call may take before it counts as giving no verdict.
A call that takes longer asks the user, or is denied in a
non-interactive session.  Each of the judge's two calls gets its own.")

(defconst harness-perms--judge-max-tokens 200
  "Output budget of the auto-mode judge's first call.
It leaves room for the one line of JSON a verdict is and little else,
so an ordinary judge call stays cheap.  A reasoning model spends it on
thinking before it writes anything, so a call that runs out is asked
again with `harness-perms--judge-retry-max-tokens'.")

(defconst harness-perms--judge-retry-max-tokens 2048
  "Output budget of the auto-mode judge's second call.
The first ran out of tokens, which a reasoning model does before its
verdict is written, so the second gives it room to think and answer.")

;;;; Runtime state (survives reloads)

(defvar harness-perms--allowed-dirs (make-hash-table :test 'equal)
  "Session id -> list of directories granted at runtime.")

(defvar harness-perms--session-rules (make-hash-table :test 'equal)
  "Session id -> list of rule plists answered with scope `session'.")

(defvar harness-perms--waiting (make-hash-table :test 'equal)
  "Pending id -> plist (:session-id :request :next) awaiting an answer.")

(defvar harness-perms--steered nil
  "Recent call ids whose denial already steered a non-interactive session.")

(defconst harness-perms-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered to the user for a permission request.
For a call with paths, the rule `allow-session', `allow-always' and
`deny-always' record holds for the prompt's pattern only (see
`permission/answer').")

(defconst harness-perms-dir-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered when a tool call reaches outside the allowed directories.
They are for the prompt's pattern, everything in the directory unless
the user edits it: `allow-once' lets this call reach it,
`allow-session' grants it to the session, `allow-always' adds it to
`harness-allowed-directories' and `deny-always' records a standing rule
that denies it to every tool.")

(defconst harness-perms-dir-tool "request_directory_access"
  "Tool through which an agent asks the user for access to a directory.")

(defconst harness-perms-dir-request-options '(allow-session allow-always deny-once deny-always)
  "Answer options offered when an agent asks for a directory itself.
They are for the prompt's pattern, as in `harness-perms-dir-options'.
There is no single call to allow once, so an `allow-once' answer (a
generic \"Allow\" button) grants the pattern to the session.")

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
  "Non-nil when SESSION should never wait for the user.
A session record's own switch decides, off as much as on: it starts
from `harness-non-interactive' and the user flips it per session.  The
setting alone decides only for a request without a session record."
  (harness-json-true-p
   (if (plist-member session :non-interactive)
       (plist-get session :non-interactive)
     (harness-perms--config 'harness-non-interactive session))))

(defun harness-perms--judge-p (session)
  "Non-nil when the auto-mode judge decides SESSION's undecided calls.
That is in `auto' mode, and in every mode while SESSION is
non-interactive: the user is away, so the judge decides in their place
what would ask them."
  (or (eq (harness-perms--mode-of session) 'auto)
      (harness-perms--non-interactive-p session)))

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

(defconst harness-perms--wildcards "[*?]"
  "Regexp of the characters that make a path a glob pattern.
Brackets are no classes in a pattern: they match themselves, so a
directory such as \"Photos [2024]\" stays a directory.")

(defun harness-perms--glob-p (pattern)
  "Non-nil when PATTERN is a glob pattern rather than a directory.
It is when its local part has a `*' or a `?'."
  (and (string-match-p harness-perms--wildcards (cdr (harness-perms--split pattern))) t))

(defun harness-perms--glob-resolve (pattern local)
  "Return glob PATTERN with the directory before its first wildcard resolved.
PATTERN is a local part.  LOCAL non-nil means it is on this machine:
then symbolic links in that directory are resolved, as the jail
resolves the paths it compares."
  (let* ((wild (string-match harness-perms--wildcards pattern))
         (slash (and wild (cl-position ?/ pattern :end wild :from-end t))))
    (if (not slash)
        pattern
      (let ((base (substring pattern 0 (1+ slash))))
        (concat (file-name-as-directory (if local (harness-path-normalize base) (expand-file-name base "/")))
                (substring pattern (1+ slash)))))))

(defun harness-perms--glob-covers-p (pattern path local)
  "Non-nil when glob PATTERN matches PATH, the local parts on one host.
LOCAL non-nil means both are on this machine, so symbolic links are
resolved first.  A pattern ending in /** also matches its directory,
and one ending in / holds everything below the directories it
matches, as a directory does."
  (let* ((case-fold-search nil)
         (pattern (if (string-suffix-p "/" pattern) (concat pattern "**") pattern))
         (rx (harness-glob-regexp (harness-perms--glob-resolve pattern local) t))
         (path (if local (harness-path-normalize path) (expand-file-name path "/"))))
    (or (string-match-p rx path)
        (string-match-p rx (file-name-as-directory path)))))

(defun harness-perms--within-p (root path)
  "Non-nil when PATH lies inside ROOT.
ROOT is a directory, which holds itself and everything below it, or a
glob pattern (see `harness-perms--glob-p'): `*' matches within a name,
`**' across directories, `?' one character, and the pattern holds the
paths it matches.  Remote paths only match when the hosts are the
same; then the local parts are compared."
  (pcase-let ((`(,rh . ,rl) (harness-perms--split root))
              (`(,ph . ,pl) (harness-perms--split path)))
    (and (equal rh ph)
         (cond
          ((string-match-p harness-perms--wildcards rl) (harness-perms--glob-covers-p rl pl (not rh)))
          (rh
           (let ((dir (file-name-as-directory (expand-file-name rl "/")))
                 (p (expand-file-name pl "/")))
             (or (string= (file-name-as-directory p) dir)
                 (string-prefix-p dir p))))
          (t (harness-path-within-p rl pl))))))

(defun harness-perms--expand-root (root dir)
  "Return ROOT made absolute against DIR.
A directory comes back as a directory name, even one whose name has a
wildcard; a glob pattern, or a grant narrowed to one local file, as it
is.  Only local paths are looked up on disk."
  (let ((abs (expand-file-name root dir)))
    (cond
     ((directory-name-p abs) abs)
     ((file-remote-p abs) (if (harness-perms--glob-p abs) abs (file-name-as-directory abs)))
     ((file-directory-p abs) (file-name-as-directory abs))
     ((or (harness-perms--glob-p abs) (file-regular-p abs)) abs)
     (t (file-name-as-directory abs)))))

(defun harness-perms--granted (session)
  "Return the directories granted to SESSION at runtime.
Grants live on the session record (`:allowed-dirs') so they survive a
restart; without a session module they live in
`harness-perms--allowed-dirs'."
  (cl-remove-duplicates
   (append (plist-get session :allowed-dirs)
           (gethash (plist-get session :id) harness-perms--allowed-dirs))
   :test #'equal :from-end t))

(defun harness-perms--tmp-dir (session)
  "Return SESSION's own temporary directory, made if missing, or nil.
The session module hands it out (`session/tmp-dir'), and only when it
is the user's own; without that module, or for a remote session, there
is none."
  (let ((id (plist-get session :id)))
    (and id (harness-method-exists-p 'session/tmp-dir)
         (condition-case err
             (harness-call 'session/tmp-dir id)
           (error (harness-log 'debug "perms: no temporary directory for %s: %s"
                               id (harness-error-message err))
                  nil)))))

(defun harness-perms-dirs (session)
  "Return the directories SESSION may touch as (:dir DIR :source SOURCE).
SOURCE is `cwd', `worktree', `tmp' (the session's own temporary
directory), `config' (`harness-allowed-directories'), `session'
\(granted at runtime) or `outputs'.  A grant may be a glob pattern
rather than a directory (see `harness-perms--within-p')."
  (let* ((cwd (or (plist-get session :cwd) default-directory))
         (host (plist-get session :host))
         (expand (lambda (d) (harness-perms--with-host (harness-perms--expand-root d cwd) host)))
         (entry (lambda (source) (lambda (d) (list :dir (funcall expand d) :source source))))
         (tmp (harness-perms--tmp-dir session))
         (entries (append (list (funcall (funcall entry 'cwd) cwd))
                          (and (plist-get session :worktree)
                               (list (funcall (funcall entry 'worktree) (plist-get session :worktree))))
                          ;; Always local: a remote session has none.
                          (and tmp (list (list :dir tmp :source 'tmp)))
                          (mapcar (funcall entry 'config)
                                  (harness-perms--config 'harness-allowed-directories session))
                          (mapcar (funcall entry 'session) (harness-perms--granted session))
                          (list (list :dir (file-name-as-directory
                                            (expand-file-name "outputs" harness-state-directory))
                                      :source 'outputs)))))
    (cl-remove-duplicates entries :test #'equal :key (lambda (e) (plist-get e :dir)) :from-end t)))

(defun harness-perms-roots (session)
  "Return the directories SESSION may touch.
That is its cwd, its worktree, its own temporary directory,
`harness-allowed-directories', the directories granted at runtime and
the tool output directory."
  (mapcar (lambda (e) (plist-get e :dir)) (harness-perms-dirs session)))

(defun harness-perms--outside (paths roots)
  "Return the first of PATHS that is not inside any of ROOTS, or nil."
  (cl-find-if (lambda (p) (not (cl-some (lambda (r) (harness-perms--within-p r p)) roots)))
              paths))

(defun harness-perms--dir-of (path)
  "Return the directory to grant so that PATH becomes reachable.
Symbolic links are resolved first: the jail compares resolved paths,
so the prompt has to name the directory a grant really opens."
  ;; Never touch the file system for a remote path: that would open
  ;; a TRAMP connection from inside the permission chain.
  (if (file-remote-p path)
      (or (file-name-directory path) path)
    (let ((path (harness-path-normalize path)))
      (if (file-directory-p path)
          (file-name-as-directory path)
        (or (file-name-directory path) path)))))

(defun harness-perms--scratch-hint (session path)
  "Return a sentence sending SESSION's scratch files at PATH to its own dir.
When PATH lies in the system's temporary directory but outside the
session's own temporary directory, the agent most likely wanted a
scratch file, which belongs in its own directory, already allowed, so
it carries on there instead of stopping.  Otherwise return \"\"."
  (let ((tmp (and (not (file-remote-p path)) (harness-perms--tmp-dir session))))
    (if (and tmp
             (harness-perms--within-p temporary-file-directory path)
             (not (harness-perms--within-p tmp path)))
        (format " For scratch files use your own temporary directory, %s: it is already allowed, bash included."
                (abbreviate-file-name tmp))
      "")))

;;;; Patterns a prompt about paths is answered for
;;
;; A prompt about paths (the jail's, an agent's directory request, a
;; tool call with paths) is answered for a glob pattern rather than one
;; file: by default everything in the directory (`DIR/**'), the
;; directory holding a file or the directory itself.  The prompt's
;; payload carries it as `:pattern' and the user may answer with
;; another one, more or less specific, in the answer's `:pattern'.

(defun harness-perms--default-pattern (dir)
  "Return the pattern a prompt about DIR offers: everything in DIR."
  (concat (file-name-as-directory dir) "**"))

(defun harness-perms--common-dir (a b)
  "Return the deepest directory holding both directory names A and B."
  (let* ((same (compare-strings a nil nil b nil nil))
         (prefix (if (eq same t) a (substring a 0 (1- (abs same))))))
    (substring prefix 0 (1+ (or (cl-position ?/ prefix :from-end t) -1)))))

(defun harness-perms--paths-dir (paths)
  "Return the deepest directory that holds every one of PATHS.
A path stands for its directory (`harness-perms--dir-of'); paths on
another host than the first one's are left out."
  (let* ((dirs (mapcar #'harness-perms--dir-of paths))
         (host (car (harness-perms--split (car dirs)))))
    (cl-reduce (lambda (a b)
                 (if (equal host (car (harness-perms--split b))) (harness-perms--common-dir a b) a))
               (cdr dirs) :initial-value (car dirs))))

(defun harness-perms--expand-pattern (session pattern)
  "Return PATTERN absolute for SESSION: against its cwd, on its host."
  (harness-perms--with-host (expand-file-name pattern (or (plist-get session :cwd) default-directory))
                            (plist-get session :host)))

(defun harness-perms--answered-pattern (session waiting answer)
  "Return the pattern ANSWER to the prompt WAITING of SESSION is for.
That is the answer's `:pattern', made absolute, or else the pattern
the prompt offered; nil for a prompt about no path."
  (let ((typed (plist-get answer :pattern)))
    (and (plist-get waiting :pattern)
         (if (and (stringp typed) (not (harness-string-blank-p typed)))
             (harness-perms--expand-pattern session (string-trim typed))
           (plist-get waiting :pattern)))))

(defun harness-perms--grant-form (pattern)
  "Return PATTERN as a grant keeps it: `DIR/**' is the directory DIR/."
  (pcase-let ((`(,host . ,local) (harness-perms--split pattern)))
    (if (and (string-suffix-p "/**" local) (not (string-match-p harness-perms--wildcards (substring local 0 -2))))
        (concat (or host "") (substring local 0 -2))
      pattern)))

(defun harness-perms--jail (decision next request)
  "Pass REQUEST on when its paths lie inside the session's roots.
Otherwise ask the user for access to the directory, or deny when
nobody can answer or a rule denies the call anyway.  DECISION is the
current value and NEXT continues the chain.  Roots in the request's
`:jail-once' were allowed for this call only."
  (let ((paths (plist-get request :paths)))
    (if (null paths)
        (funcall next decision)
      (let* ((session (plist-get request :session))
             (roots (append (harness-perms-roots session) (plist-get request :jail-once)))
             (bad (harness-perms--outside paths roots))
             (rule (and bad (harness-perms--find-rule request))))
        (cond
         ((null bad) (funcall next decision))
         ;; A rule denies the call (an "Always deny" of an earlier
         ;; prompt, say): no point asking for the directory.
         ((eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
          (funcall next (plist-put (harness-perms--rule-decision rule) :final t)))
         ((and (not (harness-perms--non-interactive-p session))
               (harness-method-exists-p 'session/pending-add))
          (harness-perms--ask-dir decision next request bad))
         (t
          (funcall next
                   (list :behavior 'deny :final t
                         :reason (format "%s is outside the allowed directories" bad)
                         :hint (format "Allowed roots: %s. Work inside them, or ask the user to grant access to %s with the allow-dir command.%s"
                                       (mapconcat #'abbreviate-file-name roots ", ")
                                       (abbreviate-file-name (harness-perms--dir-of bad))
                                       (harness-perms--scratch-hint session bad))))))))))

(defun harness-perms--pend-dir (request next dir reason options &rest waiting)
  "Ask the user of REQUEST's session for access to DIR.
REASON says why and OPTIONS lists the answers offered.  The prompt is
answered for everything in DIR unless the user edits its pattern.
NEXT continues the chain once `permission/answer' arrives; WAITING adds
properties to the entry kept until then."
  (let* ((sid (plist-get (plist-get request :session) :id))
         (pattern (harness-perms--default-pattern dir))
         (pending (list :kind 'permission
                        :payload (list :tool (plist-get request :tool)
                                       :input (plist-get request :input)
                                       :kind (plist-get request :kind)
                                       :paths (plist-get request :paths)
                                       :call-id (plist-get request :call-id)
                                       :dir dir
                                       :pattern pattern
                                       :title (format "Access %s" (abbreviate-file-name dir))
                                       :reason reason
                                       :options options)))
         (pid (harness-call 'session/pending-add sid pending)))
    (puthash pid (append (list :session-id sid :request request :next next :dir dir :pattern pattern) waiting)
             harness-perms--waiting)
    (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid))))

(defun harness-perms--ask-dir (decision next request bad)
  "Ask the user to grant the directory holding BAD to REQUEST's session.
DECISION and NEXT continue the chain once `permission/answer' arrives."
  (harness-perms--pend-dir request next (harness-perms--dir-of bad)
                           (format "%s wants %s, which is outside the allowed directories"
                                   (harness-tools-label (plist-get request :tool)) (abbreviate-file-name bad))
                           harness-perms-dir-options
                           :decision decision))

(defun harness-perms--answer-dir (session-id waiting answer)
  "Continue the chain for WAITING of SESSION-ID after the user's ANSWER.
The answer is for its pattern (`harness-perms--answered-pattern'): an
allow grants it, `DIR/**' as the directory DIR/; a deny for the
session or always records a rule denying it to every tool.  A jail
prompt goes on through the jail; an agent's own request (see
`harness-perms--dir-request') ends with the answer.  Return the final
decision, or `continue' when the chain goes on."
  (let* ((request (plist-get waiting :request))
         (dir (plist-get waiting :dir))
         (next (plist-get waiting :next))
         (scope (plist-get answer :scope))
         (pattern (or (harness-perms--answered-pattern (harness-perms--session session-id) waiting answer)
                      (harness-perms--default-pattern dir)))
         (grant (harness-perms--grant-form pattern)))
    (cond
     ((not (eq (plist-get answer :behavior) 'allow))
      (when (memq scope '(session always))
        (harness-perms-add-rule session-id (list :path pattern :behavior 'deny) scope))
      (let ((d (list :behavior 'deny :final t
                     :reason (or (plist-get answer :reason)
                                 (format "the user denied access to %s"
                                         (abbreviate-file-name (if (memq scope '(session always)) pattern dir))))
                     :hint (if (plist-get waiting :explicit)
                               "Do not ask for it again; work inside the allowed directories."
                             "Do not retry; work inside the allowed directories."))))
        (funcall next d)
        d))
     ((plist-get waiting :explicit)
      (let ((d (harness-perms--grant-requested session-id grant scope (plist-get request :input))))
        (funcall next d)
        d))
     (t
      (pcase scope
        ('session (harness-call 'permission/allow-dir session-id grant))
        ('always (harness-call 'permission/allow-dir session-id grant 'always))
        (_ (setq request (plist-put (copy-sequence request) :jail-once
                                    (cons grant (plist-get request :jail-once))))))
      ;; Check again with the fresh session: other paths may lie
      ;; elsewhere, or outside a narrower pattern than the prompt's.
      (harness-perms--jail (plist-get waiting :decision) next
                           (plist-put (copy-sequence request) :session (harness-perms--session session-id)))
      'continue))))

;;;; Directory requests from the agent

(defun harness-perms--requested-dir (session path)
  "Return the directory PATH names for SESSION: absolute, with its host.
PATH is relative to SESSION's cwd.  Symbolic links are resolved, so
the user is asked about the directory a grant really opens.  A path
naming a file stands for the directory holding it; anything else is a
directory, so one that does not exist yet is not widened to its
parent."
  (let ((abs (harness-perms--with-host (expand-file-name path (or (plist-get session :cwd) default-directory))
                                       (plist-get session :host))))
    ;; Never touch the file system for a remote path (see `harness-perms--dir-of').
    (if (file-remote-p abs)
        (file-name-as-directory abs)
      (let ((real (harness-path-normalize abs)))
        (if (file-regular-p real)
            (file-name-directory real)
          (file-name-as-directory real))))))

(defun harness-perms--request-reason (session dir why)
  "Return the prompt text for an agent's request of DIR in SESSION.
WHY is the reason the agent gave, or nil."
  (concat (if (or (not (stringp why)) (harness-string-blank-p why))
              "The agent asks for access to this directory."
            (format "The agent asks for access: %s" (string-trim why)))
          (if (harness-perms--within-p dir (or (plist-get session :cwd) default-directory))
              "  Careful: it contains the working directory and everything around it."
            "")))

(defun harness-perms--dir-rule (session dir)
  "Return the first rule of SESSION about access to DIR, or nil.
That is a rule with a `:path' that covers DIR, for no tool and no kind
in particular, such as an \"Always deny\" answer to a directory prompt
records."
  (let ((probe (list :session session :paths (list dir))))
    (cl-find-if (lambda (r) (and (plist-get r :path) (harness-perms--rule-matches-p r probe)))
                (append (gethash (plist-get session :id) harness-perms--session-rules) harness-perms-rules))))

(defun harness-perms--dir-request (decision next request)
  "Decide a call to `harness-perms-dir-tool' from the user's answer alone.
Other calls go on with DECISION.  For the request tool the decision
handed to NEXT is always final, so the mode, the standing rules and
the auto-mode judge never see it: the call is allowed at once only
when REQUEST's directory is already reachable (nothing is granted
then), denied when nobody can answer or a rule denies the directory
\(see `harness-perms--dir-rule'), and otherwise waits for the user, who
grants the directory, or a pattern of their own, or not.  No rule
grants a directory."
  (if (not (equal (plist-get request :tool) harness-perms-dir-tool))
      (funcall next decision)
    (let* ((session (plist-get request :session))
           (input (plist-get request :input))
           (path (plist-get input :path))
           (dir (and (stringp path) (not (harness-string-blank-p path))
                     (harness-perms--requested-dir session path)))
           (roots (harness-perms-roots session))
           (rule (and dir (harness-perms--dir-rule session dir))))
      (cond
       ((null dir)
        (funcall next (list :behavior 'deny :final t
                            :reason (format "%s needs the path of a directory" harness-perms-dir-tool)
                            :hint "Call it again with path set to the directory you need.")))
       ((not (harness-perms--outside (list dir) roots))
        ;; The handler gets the path alone: nothing was granted.
        (funcall next (list :behavior 'allow :final t :input (list :path path)
                            :reason (format "%s is already allowed; nothing to grant" (abbreviate-file-name dir)))))
       ((eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
        (funcall next (plist-put (plist-put (harness-perms--rule-decision rule) :final t)
                                 :hint "Do not ask for it again; work inside the allowed directories.")))
       ((or (harness-perms--non-interactive-p session)
            (not (harness-method-exists-p 'session/pending-add)))
        (funcall next (list :behavior 'deny :final t
                            :reason (format "nobody can grant %s: %s" (abbreviate-file-name dir)
                                            (if (harness-perms--non-interactive-p session)
                                                "the session is non-interactive and the user is away"
                                              "no user is available"))
                            :hint (format "Work inside the allowed directories (%s). If the task cannot be done without %s, finish what you can and say so in your answer; the user can grant it with M-x harness-directories.%s"
                                          (mapconcat #'abbreviate-file-name roots ", ")
                                          (abbreviate-file-name dir)
                                          (harness-perms--scratch-hint session dir)))))
       (t
        ;; The prompt shows the directory and the agent's reason; the
        ;; input keeps only the path so the reason is not shown twice.
        (harness-perms--pend-dir (plist-put (copy-sequence request) :input (list :path path))
                                 next dir
                                 (harness-perms--request-reason session dir (plist-get input :reason))
                                 harness-perms-dir-request-options
                                 :explicit t))))))

(defun harness-perms--grant-requested (session-id grant scope input)
  "Grant GRANT to SESSION-ID as the user allowed it; return the decision.
This is the answer to an agent's own request.  GRANT is a directory or
a glob pattern.  SCOPE `always' adds it to `harness-allowed-directories';
any other scope, `once' included, grants it to the session.  The tool
gets INPUT's path with `:granted' GRANT, so it can tell the agent."
  (let ((always (eq scope 'always)))
    (condition-case err
        (progn
          (harness-call 'permission/allow-dir session-id grant (and always 'always))
          (list :behavior 'allow :final t
                :input (list :path (plist-get input :path) :granted grant)
                :reason (format "the user granted %s to %s" (abbreviate-file-name grant)
                                (if always "every session" "this session"))))
      (error
       (harness-log 'error "perms: granting %s to %s failed: %S" grant session-id err)
       (list :behavior 'deny :final t
             :reason (format "granting %s failed: %s" (abbreviate-file-name grant) (harness-error-message err)))))))

(defun harness-perms--source-label (source)
  "Return how the request tool describes directory SOURCE to the agent."
  (pcase source
    ('cwd "the working directory")
    ('worktree "the worktree")
    ('tmp "this session's own temporary directory")
    ('config "allowed for every session")
    ('session "granted to this session")
    ('outputs "the tool output directory")
    (_ (format "%s" source))))

(defun harness-perms--dir-request-result (input ctx)
  "Handler of `harness-perms-dir-tool': tell the agent what it may reach now.
It runs only once the permission chain allowed the call, that is when
the user granted the directory in INPUT or it was already allowed;
the grant itself happens in `permission/answer', which puts what the
user granted, maybe a pattern of their own, in INPUT's `:granted'.
CTX names the session."
  (let* ((session (harness-perms--session (plist-get ctx :session-id)))
         (path (plist-get input :path))
         (dir (and (stringp path) (not (harness-string-blank-p path))
                   (harness-perms--requested-dir session path)))
         (entries (harness-perms-dirs session))
         (granted (plist-get input :granted))
         (grant (and dir (stringp granted)
                     (cl-find (harness-perms--with-host
                               (harness-perms--expand-root granted (or (plist-get session :cwd) default-directory))
                               (plist-get session :host))
                              entries :key (lambda (e) (plist-get e :dir)) :test #'equal)))
         (entry (and dir (cl-find-if (lambda (e) (harness-perms--within-p (plist-get e :dir) dir)) entries)))
         (shown (and dir (abbreviate-file-name dir))))
    (cond
     ((null dir) (harness-tool-error "Give path, the directory you need."))
     ;; The user edited the prompt's pattern: say what they granted.
     ((and grant (not (equal (plist-get grant :dir) dir)))
      (let ((glob (harness-perms--glob-p (plist-get grant :dir))))
        (harness-tool-ok
         (format "The user granted %s instead of %s: it is now allowed for %s. Tools that take paths can use %s%s."
                 (abbreviate-file-name (plist-get grant :dir)) shown
                 (if (eq (plist-get grant :source) 'config) "every session" "this session")
                 (if glob "the paths it matches" "what it holds")
                 (if glob "" "; to run bash there, set its cwd inside it")))))
     ((null entry)
      (harness-tool-error (format "%s is still outside the allowed directories." shown)))
     (t
      (harness-tool-ok
       (concat
        (pcase (list (plist-get entry :source) (equal (plist-get entry :dir) dir))
          ('(session t) (format "%s is now an allowed directory of this session." shown))
          ('(config t) (format "%s is now an allowed directory of every session." shown))
          (`(,source ,_) (format "%s is already accessible: it lies inside %s (%s)." shown
                                 (abbreviate-file-name (plist-get entry :dir))
                                 (harness-perms--source-label source))))
        " Tools that take paths can use it; to run bash there, set its cwd inside it."))))))

(harness-define-tool harness-perms-dir-tool
  :label "Request access"
  :description "Ask the user for access to a directory outside the allowed directories (the working directory and the directories granted so far), for instance another repository you need to read or change. The user is always asked, in every permission mode, and either grants it to this session, grants it to every session, or denies it; the call waits for the answer. The user may grant a narrower or wider path or glob pattern than you asked for; the result says what was granted. Ask for the narrowest directory that does the job and say why. If the user denies it, do not ask again. A non-interactive session cannot ask and is denied at once."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "The directory, absolute or relative to the working directory.")
                         :reason (:type "string" :description "Why you need it; shown to the user."))
            :required ("path" "reason"))
  :kind 'meta
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-perms--dir-request-result)

;;;; Commands the sandbox makes destructive

(defun harness-perms--sandbox-guard (decision next request)
  "Refuse a shell command that would do damage because it runs sandboxed.
In the sandbox git sees only the session's own directory, so `git
worktree prune' there drops every other worktree; the sandbox module's
`sandbox/check-command' tells which commands are like that.  Its
refusal is final, in every mode.  Other calls go on with DECISION; NEXT
continues the chain with REQUEST's decision."
  (let* ((input (plist-get request :input))
         (command (and (listp input) (plist-get input :command))))
    (if (not (and (stringp command)
                  (eq (harness-perms--sym (plist-get request :kind)) 'exec)
                  (harness-method-exists-p 'sandbox/check-command)))
        (funcall next decision)
      (let* ((session (plist-get request :session))
             (cwd (or (car (plist-get request :paths)) (plist-get session :cwd) default-directory))
             (own (or (plist-get session :worktree) (plist-get session :cwd)))
             (refusal (condition-case err
                          (harness-call 'sandbox/check-command cwd command own)
                        (error (harness-log 'warn "perms: the sandbox guard failed: %S" err) nil))))
        (funcall next (if refusal
                          (list :behavior 'deny :final t
                                :reason (plist-get refusal :reason) :hint (plist-get refusal :hint))
                        decision))))))

;;;; Mode and standing rules

(defun harness-perms--rule-pattern (rule session)
  "Return RULE's `:path' pattern made absolute for SESSION, or nil.
A relative pattern is relative to SESSION's cwd, so a standing rule
can name a part of every project, such as docs/**."
  (let ((path (plist-get rule :path)))
    (and (stringp path) (not (harness-string-blank-p path))
         (harness-perms--with-host
          (harness-perms--expand-root (string-trim path) (or (plist-get session :cwd) default-directory))
          (plist-get session :host)))))

(defun harness-perms--rule-matches-p (rule request)
  "Non-nil when RULE applies to REQUEST.
A rule with a `:path' pattern applies to calls with paths only: an
allow rule when the pattern covers every one of them, a deny rule
when it covers any (see `harness-perms--within-p')."
  (let ((tool (plist-get rule :tool))
        (kind (harness-perms--sym (plist-get rule :kind)))
        (pattern (harness-perms--rule-pattern rule (plist-get request :session)))
        (paths (plist-get request :paths)))
    (and (or (null tool) (equal tool (plist-get request :tool)))
         (or (null kind) (eq kind (harness-perms--sym (plist-get request :kind))))
         (or (null pattern)
             (and paths
                  (funcall (if (eq (harness-perms--sym (plist-get rule :behavior)) 'deny) #'cl-some #'cl-every)
                           (lambda (p) (harness-perms--within-p pattern p))
                           paths))))))

(defun harness-perms--find-rule (request)
  "Return the first session or global rule that applies to REQUEST."
  (let ((sid (plist-get (plist-get request :session) :id)))
    (cl-find-if (lambda (r) (harness-perms--rule-matches-p r request))
                (append (gethash sid harness-perms--session-rules) harness-perms-rules))))

(defun harness-perms--rule-decision (rule)
  "Return the decision RULE makes, with a reason that names what it is for."
  (let* ((tool (plist-get rule :tool))
         (path (plist-get rule :path))
         (path (and (stringp path) (not (harness-string-blank-p path)) (abbreviate-file-name path)))
         (what (cond ((and tool path) (format "%s in %s" tool path))
                     ((or tool path))
                     (t "every tool"))))
    (if (eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
        (list :behavior 'deny :reason (format "denied by a standing rule for %s" what)
              :hint "Do not retry this call; choose a different approach.")
      (list :behavior 'allow :reason (format "allowed by a standing rule for %s" what)))))

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
     ;; Rules come first: the user's explicit answer beats the defaults.
     (rule (harness-perms--rule-decision rule))
     ((member tool harness-perms--auto-allow-tools)
      (list :behavior 'allow :reason (format "%s never needs approval" tool)))
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

;; The judge gets two tries when it runs out of output tokens: a
;; reasoning model spends the first call's small budget thinking and
;; never writes its verdict, so the second call gives it room to
;; answer.  Only a call neither call decided is denied while the user
;; is away.

(defconst harness-perms--judge-system
  "You are the permission judge for an autonomous coding agent running inside Emacs.
The agent wants to run a tool.  Decide whether the call is safe and within the
user's evident intent.  Allow ordinary development work inside the allowed
directories.  Looking things up on the web (documentation, references, issue
trackers, package registries) is ordinary development work too, as long as the
URL does not carry secrets or project data.  Deny anything destructive or
irreversible outside the project (deleting or overwriting unrelated files,
force pushes, changing system configuration, exfiltrating secrets, network
calls to unexpected hosts, or installing software system-wide).  Also deny
anything that would widen the agent's own permissions or weaken the harness's
safeguards: granting itself directories (harness-allowed-directories,
including in .dir-locals.el files), changing the permission mode or the
non-interactive setting, or turning the sandbox off.  Only the user grants
directories; the agent asks for one with the request_directory_access tool.
When unsure, deny with a reason the agent can act on.  Reply with exactly one
line of JSON and nothing else:
{\"decision\":\"allow\"|\"deny\",\"reason\":\"one short sentence\"}"
  "System prompt for the auto-mode judge.")

(defun harness-perms--judge-text (request)
  "Return the user message describing REQUEST for the judge.
The input goes in as text, not bytes: the provider encodes the whole
message as JSON again, and the bytes of non-ASCII input would make
that fail."
  (let* ((tool (plist-get request :tool))
         (spec (and (harness-method-exists-p 'tools/get) (harness-call 'tools/get tool)))
         (session (plist-get request :session)))
    (format "Tool: %s\nKind: %s\nDescription: %s\n\nInput (JSON):\n%s\n\nWorking directory: %s\nAllowed roots:\n%s\n\nAnswer with one line of JSON: {\"decision\":\"allow\"|\"deny\",\"reason\":\"...\"}"
            tool (plist-get request :kind)
            (or (plist-get spec :description) "(no description)")
            (harness-truncate-end (harness-json-encode-text (or (plist-get request :input) :empty)) 4000)
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

(defun harness-perms--no-verdict-message (tool event text)
  "Return the warning for a judge of TOOL whose `done' EVENT brought no verdict.
It names the stop reason and the provider's `:error', when there is
one, and quotes the start of TEXT, what the judge replied."
  (let ((err (plist-get event :error)))
    (concat (format "perms: auto judge gave no verdict for %s (%s)" tool (plist-get event :stop-reason))
            (if err (concat ": " (harness-truncate-end (harness-error-message err) 300)) "")
            (if (harness-string-blank-p text) ""
              (concat "; it replied: " (harness-truncate-end text 200))))))

(defun harness-perms--judge-model (session)
  "Return the model the auto-mode judge uses for SESSION.
`harness-perms-auto-model' names one, `auto' asks the session's own
provider for its cheap tier (falling back to the session's model), and
nil uses the session's model."
  (let* ((session-model (or (plist-get session :model)
                            (harness-perms--config 'harness-model session)))
         (choice harness-perms-auto-model)
         (automatic (or (eq choice 'auto)
                        (and (stringp choice) (equal choice "auto")))))
    (cond
     (automatic
      (or (and session-model (harness-method-exists-p 'provider/tier-model)
               (harness-call 'provider/tier-model session-model 'cheap))
          session-model))
     ((stringp choice) choice)
     (t session-model))))

(defun harness-perms--auto (decision next request)
  "Ask a cheap model to decide REQUEST, in auto mode or for a user away.
The judge decides what is still undecided in `auto' mode, and in every
mode while the session is non-interactive (`harness-perms--judge-p').
A judge call that ends at its output limit before writing a verdict is
asked again with a larger budget (`harness-perms--judge-max-tokens',
then `harness-perms--judge-retry-max-tokens'), since running out of
room is no verdict on the call.  Without a verdict the call goes on
undecided, so it asks the user, with `:no-verdict' saying why for the
stage that denies it when the user is away.  DECISION is the current
value and NEXT continues the chain."
  (let ((session (plist-get request :session)))
    (if (not (and (eq (plist-get decision :behavior) 'ask)
                  (harness-perms--judge-p session)
                  (harness-method-exists-p 'provider/complete)))
        (funcall next decision)
      (let* ((model (harness-perms--judge-model session))
             (attempt 0)                ; judge calls made so far
             (settled nil) (timer nil) (handle nil)
             (failure nil)              ; why the judge gave no verdict
             ;; A verdict is a new decision: DECISION itself comes back
             ;; when the judge gave none.
             (finish (lambda (d)
                       (unless settled
                         (setq settled t)
                         (when timer (cancel-timer timer))
                         (funcall next (if (eq d decision)
                                           (plist-put (copy-sequence decision) :no-verdict
                                                      (or failure "it gave no answer"))
                                         d))))))
        (cl-labels
            ;; Ask once, as call N.  Each call keeps its own reply and
            ;; only speaks while it is the live one, so an event from a
            ;; call that ran out cannot decide for its retry.
            ((ask (n)
                  (let ((text "") (live (setq attempt n)))
                    (setq failure nil)
                    (when timer (cancel-timer timer))
                    (setq timer
                          (run-at-time harness-perms--auto-timeout nil
                                       (lambda ()
                                         (harness-log 'warn "perms: auto judge timed out for %s" (plist-get request :tool))
                                         (setq failure (format "it took longer than %ss" harness-perms--auto-timeout))
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
                                     :tools nil
                                     :max-tokens (if (= n 1)
                                                     harness-perms--judge-max-tokens
                                                   harness-perms--judge-retry-max-tokens)
                                     :on-event
                                     (lambda (ev)
                                       (when (= live attempt)
                                         (when (eq (plist-get ev :type) 'done)
                                           (setq failure (harness-perms--judge-failure ev text)))
                                         (pcase (plist-get ev :type)
                                           ('text
                                            (setq text (concat text (or (plist-get ev :delta) ""))))
                                           ('done
                                            (let ((verdict (harness-perms--parse-verdict text)))
                                              (cond
                                               (verdict (funcall finish verdict))
                                               ((and (= n 1) (eq (plist-get ev :stop-reason) 'max-tokens))
                                                (harness-log
                                                 'info
                                                 "perms: auto judge ran out of output tokens for %s; asking once more"
                                                 (plist-get request :tool))
                                                (ask 2))
                                               (t
                                                (harness-log 'warn "%s" (harness-perms--no-verdict-message
                                                                         (plist-get request :tool) ev text))
                                                (funcall finish decision)))))))))))
                      (error
                       (harness-log 'warn "perms: auto judge failed: %S" err)
                       (setq failure (format "it failed: %s" (harness-error-message err)))
                       (funcall finish decision))))))
          (ask 1))))))

;;;; Non-interactive mode

(defconst harness-perms-non-interactive-hint
  "Find a different approach that stays inside the permitted scope and still achieves the goal; do not wait for the user."
  "Hint attached to denials made because nobody can approve a call.")

(defconst harness-perms-no-verdict-hint
  "This was not a verdict on the call itself, so you may try it once more. If it is denied again, find a different approach that stays inside the permitted scope and still achieves the goal; do not wait for the user."
  "Hint attached to a denial made because the judge gave no verdict.")

(defconst harness-perms-steering-text
  "The call to %s was denied. This session is non-interactive and the user is away, so do not wait for them: respect the denial, whose reason and hint say what is permitted, and do everything in your power to reach the goal another way."
  "Steering message sent after a denial in a non-interactive session.
%s is the name of the denied tool.")

(defun harness-perms--judge-failure (event text)
  "Return why a judge that replied TEXT may give no verdict, from its `done' EVENT.
It is said to the agent and the user when that denies a call."
  (let ((err (plist-get event :error)))
    (cond (err (format "it failed: %s" (harness-truncate-end (harness-error-message err) 200)))
          ((not (eq (plist-get event :stop-reason) 'end-turn))
           (format "it stopped: %s" (plist-get event :stop-reason)))
          ((harness-string-blank-p text) "it gave no answer")
          (t "its answer held no verdict"))))

(defun harness-perms--unapproved (decision)
  "Return the denial of a call left undecided with DECISION while the user is away.
Nobody can approve it: the judge gave no verdict, which DECISION's
`:no-verdict' explains, or no judge could be asked."
  (let ((why (plist-get decision :no-verdict)))
    (if why
        (list :behavior 'deny
              :reason (format "the auto-mode judge gave no verdict (%s), and with the user away nobody could approve the call" why)
              :hint harness-perms-no-verdict-hint)
      (list :behavior 'deny
            :reason "no auto-mode judge could decide the call, and with the user away nobody could approve it"
            :hint harness-perms-non-interactive-hint))))

(defun harness-perms--non-interactive (decision next request)
  "Deny REQUEST when it is still undecided while the user is away.
The judge decides a non-interactive session's calls in the user's
place (see `harness-perms--judge-p'), so one still undecided here got
no verdict from it, or no judge could be asked, and nobody can approve
it.  That is the only denial non-interactive mode makes; its reason
says why there was no verdict.  Steering the agent after a denial is
left to `harness-perms--on-decided'.  DECISION is the current value and
NEXT continues the chain."
  (funcall next (if (and (eq (plist-get decision :behavior) 'ask)
                         (harness-perms--non-interactive-p (plist-get request :session)))
                    (harness-perms--unapproved decision)
                  decision)))

(defun harness-perms--steer (session-id request)
  "Tell SESSION-ID's agent that REQUEST was denied while the user is away.
The steering message reaches the running turn with the call's result;
it goes out once per call, and only while a turn runs to take it."
  (let ((call-id (or (plist-get request :call-id) (harness-short-id))))
    (when (and (harness-method-exists-p 'agent/prompt)
               (or (not (harness-method-exists-p 'agent/running))
                   (harness-call 'agent/running session-id))
               (not (member call-id harness-perms--steered)))
      (push call-id harness-perms--steered)
      (setq harness-perms--steered (seq-take harness-perms--steered 100))
      (condition-case err
          (harness-call 'agent/prompt session-id
                        (list (list :type "text"
                                    :text (format harness-perms-steering-text (plist-get request :tool))))
                        ;; The user is away: the harness steers the agent,
                        ;; and the message says so.
                        (list :from (harness-sender-system "non-interactive mode")))
        (error (harness-log 'warn "perms: steering failed: %S" err))))))

(defun harness-perms--on-decided (session-id request decision)
  "Steer SESSION-ID's agent when DECISION denies REQUEST and the user is away.
This is the `permission/decided' handler: in a non-interactive session
every denial, whoever made it (a rule, the jail, the judge...), is
followed by a steering message telling the agent to find another way
instead of waiting for the user."
  (when (and (not (eq (plist-get decision :behavior) 'allow))
             (harness-perms--non-interactive-p (harness-perms--session session-id)))
    (harness-perms--steer session-id request)))

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
         (sid (plist-get session :id))
         (paths (plist-get request :paths)))
    (cond
     ((not (eq (plist-get decision :behavior) 'ask)) (funcall next decision))
     ((not (harness-method-exists-p 'session/pending-add))
      (funcall next (list :behavior 'deny :reason "no user available")))
     (t
      ;; A call with paths is remembered for a pattern, by default
      ;; everything in the directory that holds them.
      (let* ((pattern (and paths (harness-perms--default-pattern (harness-perms--paths-dir paths))))
             (pending (list :kind 'permission
                            :payload (append (list :tool (plist-get request :tool)
                                                   :input (plist-get request :input)
                                                   :kind (plist-get request :kind)
                                                   :paths paths
                                                   :call-id (plist-get request :call-id))
                                             (and pattern (list :pattern pattern))
                                             (list :title (harness-perms-describe-request request)
                                                   :options harness-perms-options))))
             (pid (harness-call 'session/pending-add sid pending)))
        (puthash pid (list :session-id sid :request request :next next :pattern pattern) harness-perms--waiting)
        (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid)))))))

(defun harness-perms--parse-answer (answer)
  "Normalise ANSWER into a plist of :behavior, :scope, :reason and :pattern.
The result is (:behavior allow|deny :scope once|session|always :reason
R :pattern P).  ANSWER is a plist, or an option id like
\"allow-session\" as a string or under `:option'.  P is the pattern
the user answered for, when they edited the prompt's, else nil."
  (let* ((option (cond ((stringp answer) answer)
                       ((symbolp answer) (symbol-name answer))
                       ((plist-get answer :option) (format "%s" (plist-get answer :option)))))
         (parts (and option (split-string option "-")))
         (behavior (or (and (listp answer) (harness-perms--sym (plist-get answer :behavior)))
                       (and parts (intern (car parts)))
                       'deny))
         (scope (or (and (listp answer) (harness-perms--sym (plist-get answer :scope)))
                    (and (cadr parts) (intern (cadr parts)))
                    'once))
         (pattern (and (listp answer) (plist-get answer :pattern))))
    (list :behavior (if (eq behavior 'allow) 'allow 'deny)
          :scope (if (memq scope '(once session always)) scope 'once)
          :reason (and (listp answer) (plist-get answer :reason))
          :pattern (and (stringp pattern) (not (harness-string-blank-p pattern)) (string-trim pattern)))))

(harness-defmethod permission/answer (session-id pending-id answer)
  "Answer the permission request PENDING-ID of SESSION-ID with ANSWER.
ANSWER is (:behavior allow|deny :scope once|session|always :reason
:pattern), or an option id such as \"allow-session\".  A prompt about
paths is answered for a glob pattern: the payload's `:pattern' unless
ANSWER's names another, absolute or relative to the session's cwd.
Resolves the pending request, records session or standing rules (for
a directory prompt: grants the pattern to the session or, with
`always', to every session, or denies it) and lets the tool call
continue.  This is the only way a directory prompt is granted.  Return
the final decision, or `continue' when a jail prompt hands the call on."
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
Record session or standing rules and let the tool call continue.  For
a call with paths the rule holds for the answer's pattern (see
`harness-perms--answered-pattern') only, not for the tool everywhere."
  (let* ((answer (harness-perms--parse-answer answer))
         (request (plist-get waiting :request))
         (behavior (plist-get answer :behavior))
         (scope (plist-get answer :scope))
         (pattern (harness-perms--answered-pattern (harness-perms--session session-id) waiting answer))
         (decision (list :behavior behavior :final t
                         :reason (or (plist-get answer :reason)
                                     (if (eq behavior 'allow) "allowed by the user"
                                       "denied by the user")))))
    (when (memq scope '(session always))
      (harness-perms-add-rule session-id
                              (append (list :tool (plist-get request :tool))
                                      (and pattern (list :path pattern))
                                      (list :behavior behavior))
                              scope))
    (harness-perms--resolve session-id pending-id answer)
    (funcall (plist-get waiting :next) decision)
    decision))

;;;; Methods for UIs and the agent

(defun harness-perms--expand-dir (session dir)
  "Return DIR expanded against SESSION's cwd, as a directory name.
A glob pattern comes back expanded but otherwise as it is."
  (harness-perms--expand-root dir (plist-get session :cwd)))

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
`harness-allowed-directories'.  The cwd, the worktree, the session's
own temporary directory and directories set in a project's
.dir-locals.el cannot be revoked here.  Return the session's effective
roots."
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
                (list (format "%s is not a grant (it comes from the cwd, the worktree, the session's temporary directory or .dir-locals.el)"
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
          :auto-allow harness-perms--auto-allow-tools
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
                                                :dir (plist-get w :dir) :pattern (plist-get w :pattern)
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
  "Install the `permission/decide' chain and the steering after denials.
Safe to call again."
  (harness-add-filter 'permission/decide #'harness-perms--dir-request 5)
  (harness-add-filter 'permission/decide #'harness-perms--sandbox-guard 7)
  (harness-add-filter 'permission/decide #'harness-perms--jail 10)
  (harness-add-filter 'permission/decide #'harness-perms--mode 20)
  (harness-add-filter 'permission/decide #'harness-perms--auto 30)
  (harness-add-filter 'permission/decide #'harness-perms--non-interactive 40)
  (harness-add-filter 'permission/decide #'harness-perms--ask 90)
  (harness-on 'permission/decided #'harness-perms--on-decided))

(defun harness-perms--shutdown ()
  "Remove the `permission/decide' chain and the steering after denials."
  (dolist (fn '(harness-perms--dir-request harness-perms--sandbox-guard harness-perms--jail harness-perms--mode
                harness-perms--auto harness-perms--non-interactive harness-perms--ask))
    (harness-remove-filter 'permission/decide fn))
  (harness-off (cons 'permission/decided #'harness-perms--on-decided)))

;; A reload does not run `:init' again for a ready module, and the tools
;; above are registered at load time, so the chain is installed here too:
;; a reloaded harness never offers request_directory_access without the
;; stage that decides it.
(harness-perms--init)

(harness-define-module 'perms
  :doc "Directory jail, directory requests, sandbox guard, permission modes, auto judge and user prompts."
  :requires '(config tools)
  :init #'harness-perms--init
  :shutdown #'harness-perms--shutdown)

(provide 'harness-perms)
;;; harness-perms.el ends here
