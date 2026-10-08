;;; harness-perms.el --- Permission decisions for tool calls  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool call goes through the asynchronous filter
;; `permission/decide' before it runs (see `tools/execute').  This
;; module installs the chain that turns the initial `ask' into a
;; decision:
;;
;;    5 dir-request      request_directory_access: the user's answer decides
;;    6 away-request     set_non_interactive: turning it on, the user's
;;                       answer decides; turning it off needs none
;;    7 sandbox-guard    shell commands the sandbox would make destructive
;;                       (`git worktree prune' and the like) are refused
;;   10 jail             every path must lie inside an allowed root, or,
;;                       for a call that only reads, in the harness itself
;;                       or a skills directory; otherwise the user is asked
;;                       for the directory
;;   20 mode             ask / accept-edits / auto / yolo, plus standing rules
;;                       and the tools and reads that never need approval
;;   30 auto             a cheap model judges what is still undecided, in
;;                       auto mode and in every non-interactive session;
;;                       a denial is put to the user when one is present
;;   40 non-interactive  the judge gave no verdict and the user is away:
;;                       nobody can approve the call, so it is denied
;;   90 ask-user         a pending request the UI answers
;;
;; A handler receives (DECISION NEXT REQUEST) and must call NEXT with
;; the new decision; `:final' stops the chain.  Denials always carry a
;; `:reason' and, when there is something the model can do about it, a
;; `:hint', because a denial the model can act on is the difference
;; between an autonomous session and one that stalls.  Other modules
;; add stages of their own: the session tools have the user confirm
;; session_move at 6 (`harness-perms-confirm', see Confirmations), and
;; the tasks module keeps the turns that write a backlog task up
;; read-only at 25.
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
;; The judge is a safety check, not the agent's manager.  It is shown
;; one call (the tool, what it does, the input and where the agent
;; works) and decides only whether that call risks serious harm,
;; leaning to allow, since a needless denial stops work the user wants
;; done.  Its request is `:ephemeral', so the provider brings no earlier
;; verdicts and no project instructions (CLAUDE.md) along: it never
;; rules on the task, its review or the project's workflow.
;;
;; What it does follow is what Claude Code's own auto mode follows: the
;; autoMode rules of Claude Code's user and managed settings (see "The
;; rules Claude Code's own auto mode follows").  The organization's
;; trusted infrastructure is no place "off the machine" to it, and the
;; organization's denials hold, so with the same settings it is no
;; stricter than Claude Code.  No entry lifts its own rules.
;;
;; Its verdict is a verdict on one call, never on the work: an `auto'
;; session whose user is present turns a judge denial into a permission
;; prompt (`harness-perms--judge-decision') that says what the judge
;; objected to, so the user can allow a call the judge was wrong about
;; instead of the work stopping (or the user having to leave auto mode).
;; A non-interactive session has nobody to ask: it takes the verdict and
;; steers the agent to another approach.
;;
;; An agent asks for another directory with the request_directory_access
;; tool.  The first stage owns that tool's decision and always makes it
;; final, so the call never reaches the mode, the standing rules or the
;; auto-mode judge: in every mode, yolo and auto included, a directory is
;; granted only by a person answering the prompt.  Its prompt offers the
;; answers of every other prompt; allowing it once grants the directory
;; until the session's turn ends, as there is no single call to allow.
;;
;; A prompt about a path outside the allowed directories (the jail's,
;; or an agent's own request for a directory) is answered for a glob
;; pattern, not for one file: by default everything in a directory
;; (`DIR/**').  For the jail's that is the root of the repository the
;; path lies in, unless that would open too much (see
;; `harness-perms--prompt-dir'), else the directory holding the file or
;; the directory itself; for an agent's request, the directory it asked
;; for.  The user may edit it, more or less specific, before answering,
;; and the answer grants or denies the pattern.  No other prompt has one: the
;; mode asking, or the judge objecting, is about the call itself, whose
;; paths the jail already let through, so its answers for the session
;; or for always record a rule for the tool.
;; Roots and rules alike are directories or patterns (see
;; `harness-perms--within-p').
;;
;; A shell command's only path is where it runs, which is all the jail
;; checks; what it reaches is read off the command line (see "What a
;; shell command reaches").  Its prompt is about the paths it names
;; outside the session's directories, so `ls ~/.claude/projects' run in
;; the project names ~/.claude/projects, not the project, and says where
;; it runs; the rules about paths weigh the same paths.  A command that
;; names nothing outside is about where it runs, as before.
;;
;; Inspecting the harness itself is one of the things that make it
;; powerful, so no mode, no judge and no jail stands in its way: the
;; tools that only look at the harness or the user's live Emacs
;; (`harness-perms--inspection-tools') never need approval, and a call
;; that only reads may read the harness's code and its state directory
;; wherever they lie (`harness-perms-inspection-dirs').  They are no
;; roots: writing there, or running a command there, stays jailed.  The
;; credentials in the state directory (`harness-perms--private-files')
;; are left out, since what a tool reads goes to the model's provider.
;; The judge's prompt says the same for the calls it sees, such as Emacs
;; Lisp that reads the state directory.  Standing rules still come
;; first, so a user's deny rule holds.  The file emacs_find_definition
;; showed a definition in may be read the same way, and only that file
;; (see "Files the user's Emacs showed a definition in").
;;
;; Skills are read the same way (see "Skills, which every session may
;; read"): a call that only reads may read every directory skill
;; discovery reads (`harness-perms-skill-dirs'), in every mode, before
;; the judge or the user is asked, and the sandbox shows them to bash
;; read-only.  Writing there stays jailed.  Where reading one does not
;; fit, such as a symbolic link out of a skills directory or a remote
;; session's host, the call is refused at once and the agent pointed to
;; skill_search and skill_load: nobody is asked about a skills
;; directory.
;;
;; An agent can also ask for non-interactive mode, for its own session,
;; another one or every current session and task, with the
;; set_non_interactive tool (when the user asks it to, say, before
;; leaving).  Turning it on takes the user out of every decision, so the
;; away-request stage owns that decision the way the first stage owns a
;; directory request: in every mode the user is asked, with no answer
;; for the session or for always, and neither the judge nor a rule ever
;; sees the call.  A non-interactive session cannot ask, so its request
;; to turn it on is denied at once.  Turning it off only brings the user
;; back in, and is allowed without asking.
;;
;; Switching a session that is waiting on a prompt into yolo mode answers
;; the prompt: the call was open only because the old mode asked, and
;; yolo would have allowed it.  A standing rule still decides, and a
;; directory prompt keeps waiting, because yolo does not grant
;; directories; nor does a confirmation, which only the user gives.
;; Switching it to non-interactive likewise hands its waiting prompts to
;; the judge: each is decided as a new call of a non-interactive session
;; would be, by the stages between the jail and the prompt (the mode and
;; its rules, the judge, the denial of what got no verdict), and a denial
;; steers the agent as usual.  The prompts only the user answers keep
;; waiting: those about directories, confirmations and those asking to
;; turn non-interactive mode on.
;;
;; A policy (see harness-policy.el and docs/policy.md) holds here too.
;; A permission mode or non-interactive switch it sets is every
;; session's, whatever a session record says.  Standing rules it sets
;; come before the session's own, so no answer overrides them, and no
;; answer records a standing rule: the prompts leave out the answers
;; for always, and one given anyway holds for the session.  Allowed
;; directories it sets are not added to: a directory prompt offers no
;; allow-always, and a grant is for the session or the turn.  That a
;; person in front of a prompt may let a session reach a directory
;; outside them, as they may let a call run, the policy leaves as it is.
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
(require 'harness-policy)

(defvar harness-state-directory)
(defvar harness-directory)

;;;; Customisation

(defconst harness-perms--auto-allow-tools
  '("ask_user" "plan" "todo_write" "skill_search" "skill_load"
    "web_search" "notify" "hand_in" "open_harness")
  "Tools that never need approval, in every permission mode.
`web_search' is included because it only sends its query to the
configured `harness-websearch-provider', so even unattended task
sessions can look things up; `web_fetch' is not, because it reaches
whatever URL the agent names.  `notify' only reaches the user, through
the notification providers they set up, so unattended sessions can
tell them when they are needed.  `hand_in' only records a task's
report and ends the turn: whether the work is ready is the user's
call when they review it, never the judge's.  `open_harness' only
starts an Emacs running a checkout of this project's harness, in a
state directory of its own, so verifying harness work live needs no
prompt.  The tools that inspect the harness are in
`harness-perms--inspection-tools'.  Standing rules in
`harness-perms-rules' are checked first and can still deny any of
these tools.")

(defconst harness-perms--inspection-tools
  '("emacs_buffers" "emacs_buffer" "emacs_windows" "emacs_describe" "emacs_find_definition" "emacs_messages"
    "session_info" "session_list" "session_read" "session_search" "session_history" "session_wait"
    "task_list" "task_wait" "notification_providers")
  "Tools that only inspect the harness itself or the user's live Emacs.
Inspecting its own harness is one of the things that make the harness
powerful, so these never need approval, in every permission mode and
whether the user is present or not: they read the buffers, windows,
messages, documentation and definitions of the user's Emacs, the
sessions with their transcripts, the task boards and the notification
setup, and change nothing.  Reading the harness's files is allowed by
`harness-perms-inspection-dirs'.  Standing rules in
`harness-perms-rules' are checked first and can still deny any of
these tools.")

(defconst harness-perms--private-files '("acp-token" "server-config.el")
  "Files in `harness-state-directory' that hold credentials.
acp-token is the token of the harness's ACP server (see
harness-acp.el), and server-config.el the settings the UI forwards to
the harness process (see harness-server.el), API keys among them.
Inspecting the harness never covers them: what a tool reads goes to
the model's provider, so reading them would hand the user's secrets
over.  A call that reads them is jailed like any other outside the
allowed directories.")

(defconst harness-perms--listing-tools '("list_dir" "glob" "file_info")
  "Tools that, given a directory, only read the names and metadata in it.
They may look at a directory of the harness that holds one of
`harness-perms--private-files'; a tool that may read the contents of
the files below a directory, such as grep, may not.")

(defcustom harness-perms-rules nil
  "Standing permission rules that apply to every session.
Each rule is a plist (:tool NAME :kind KIND :path PATTERN :behavior
allow|deny).  NAME is a tool name or nil for any tool; KIND is a tool
kind or nil for any kind.  PATTERN, when there is one, limits the rule
to calls with paths: a glob (`*' within a name, `**' across
directories) or a directory, which stands for everything in it,
absolute or relative to the session's working directory.  An allow
rule then needs every path of the call to match it, a deny rule any
one.  A shell command's paths, for an allow rule, are the ones its
command line names outside the session's directories, or where it
runs when it names none there; a deny rule weighs every path it names
and where it runs.  The first matching rule wins.  Rules are added
here when a permission request is answered with scope `always': a tool
prompt's answer holds for its tool, and \"Always deny\" for a path
outside the allowed directories holds for the prompt's pattern,
whatever the tool.  The note the session's transcript gets then can
take such a rule back (`permission/undo')."
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
                 (string :tag "Model" :names model))
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

(defconst harness-perms--judge-input-chars 12000
  "Characters of a call's input the auto-mode judge is shown.
A longer input is cut, and the judge is told so above it: the judge
weighs what the call would do, never whether an input looks complete.")

;;;; Runtime state (survives reloads)

(defvar harness-perms--allowed-dirs (make-hash-table :test 'equal)
  "Session id -> list of directories granted at runtime.")

(defvar harness-perms--session-rules (make-hash-table :test 'equal)
  "Session id -> list of rule plists answered with scope `session'.")

(defvar harness-perms--turn-dirs (make-hash-table :test 'equal)
  "Session id -> directories or patterns granted until its turn ends.
An agent's own request for a directory answered allow-once grants it
for the rest of the turn it asked in; they are dropped when a turn of
the session ends or starts (see `harness-perms--grant-for-turn').")

(defvar harness-perms--waiting (make-hash-table :test 'equal)
  "Pending id -> plist (:session-id :request :next) awaiting an answer.
A prompt about a directory has `:dir'; one only the user may answer,
whatever the session's mode, has `:user-only' too (see
`harness-perms--user-only-p').")

(defvar harness-perms--judging (make-hash-table :test 'equal)
  "Pending ids of waiting prompts the judge decides again right now.
See `harness-perms--judge-waiting'.")

(defvar harness-perms--steered nil
  "Recent call ids whose denial already steered a non-interactive session.")

(defconst harness-perms-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered to the user for a permission request.
The prompt is about the call, not about where it reaches: the rule
`allow-session', `allow-always' and `deny-always' record holds for the
tool (see `permission/answer').")

(defconst harness-perms-dir-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered when a tool call reaches outside the allowed directories.
They are for the prompt's pattern, everything in the directory unless
the user edits it: `allow-once' lets this call reach it,
`allow-session' grants it to the session, `allow-always' adds it to
`harness-allowed-directories' and `deny-always' records a standing rule
that denies it to every tool.")

(defconst harness-perms-dir-tool "request_directory_access"
  "Tool through which an agent asks the user for access to a directory.")

(defconst harness-perms-dir-request-options '(allow-once allow-session allow-always deny-once deny-always)
  "Answer options offered when an agent asks for a directory itself.
They are the options of every other prompt, for the prompt's pattern
as in `harness-perms-dir-options'.  There is no single call to allow,
so `allow-once' grants the pattern until the session's turn ends: the
agent can do what it asked for, and nothing is remembered (see
`harness-perms--turn-dirs').")

(defconst harness-perms-away-tool "set_non_interactive"
  "Tool through which an agent turns non-interactive mode on or off.
Turning it on is decided by the user alone; see
`harness-perms--away-request'.")

(defconst harness-perms-away-options '(allow-once deny-once)
  "Answer options offered when an agent asks to turn non-interactive mode on.
Each request is the user's to confirm, so no answer is remembered: no
rule may approve the next one.")

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
  "Return the effective permission mode symbol for SESSION.
A mode the policy sets is every session's (see harness-policy.el)."
  (if-let* ((pinned (harness-policy-entry 'harness-permission-mode)))
      (harness-perms--sym (cdr pinned))
    (or (harness-perms--sym (plist-get session :permission-mode))
        (harness-perms--sym (harness-perms--config 'harness-permission-mode session))
        'ask)))

(defun harness-perms--non-interactive-p (session)
  "Non-nil when SESSION should never wait for the user.
A session record's own switch decides, off as much as on: it starts
from `harness-non-interactive' and the user flips it per session.  The
setting alone decides only for a request without a session record.  A
switch the policy sets is every session's (see harness-policy.el)."
  (harness-json-true-p
   (cond ((harness-policy-entry 'harness-non-interactive)
          (cdr (harness-policy-entry 'harness-non-interactive)))
         ((plist-member session :non-interactive)
          (plist-get session :non-interactive))
         (t (harness-perms--config 'harness-non-interactive session)))))

(defun harness-perms--scope-allowed (scope option)
  "Return SCOPE of an answer, or `session' when the policy rules it out.
An answer for `always' changes OPTION -- `harness-allowed-directories'
or `harness-perms-rules' -- which the policy may set; then it holds for
the session instead."
  (if (and (eq scope 'always) (harness-policy-pinned-p option))
      (progn (harness-log 'info "perms: %s is set by policy; the answer holds for the session" option)
             'session)
    scope))

(defun harness-perms--tool-options ()
  "Return the answers a tool prompt offers.
Those of `harness-perms-options', but for the ones for always, which
record a standing rule, when the policy sets `harness-perms-rules'."
  (if (harness-policy-pinned-p 'harness-perms-rules)
      (cl-remove-if (lambda (o) (memq o '(allow-always deny-always))) harness-perms-options)
    harness-perms-options))

(defun harness-perms--dir-prompt-options (options)
  "Return OPTIONS, the answers a directory prompt offers, as the policy allows.
`allow-always' goes when the policy sets `harness-allowed-directories',
which it would add to, and `deny-always' when it sets
`harness-perms-rules', where it would record a rule."
  (cl-remove-if (lambda (o)
                  (or (and (eq o 'allow-always) (harness-policy-pinned-p 'harness-allowed-directories))
                      (and (eq o 'deny-always) (harness-policy-pinned-p 'harness-perms-rules))))
                options))

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
\(granted at runtime), `turn' (granted until its turn ends, see
`harness-perms--turn-dirs') or `outputs'.  A grant may be a glob
pattern rather than a directory (see `harness-perms--within-p')."
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
                          (mapcar (funcall entry 'turn) (gethash (plist-get session :id) harness-perms--turn-dirs))
                          (list (list :dir (file-name-as-directory
                                            (expand-file-name "outputs" harness-state-directory))
                                      :source 'outputs)))))
    (cl-remove-duplicates entries :test #'equal :key (lambda (e) (plist-get e :dir)) :from-end t)))

(defun harness-perms-roots (session)
  "Return the directories SESSION may touch.
That is its cwd, its worktree, its own temporary directory,
`harness-allowed-directories', the directories granted at runtime, for
the session or until its turn ends, and the tool output directory."
  (mapcar (lambda (e) (plist-get e :dir)) (harness-perms-dirs session)))

(defun harness-perms--outside (paths roots)
  "Return the first of PATHS that is not inside any of ROOTS, or nil."
  (cl-find-if (lambda (p) (not (cl-some (lambda (r) (harness-perms--within-p r p)) roots)))
              paths))

;;;; The harness itself, which every session may inspect

(defun harness-perms--harness-code-dirs ()
  "Return the directories the running harness's code lives in.
That is `harness-directory', and the checkout its harness.el leads to
when that is a symbolic link, as in a straight.el build directory,
whose files link into the package's repository."
  (when (and (boundp 'harness-directory) (stringp harness-directory))
    (let* ((dir (file-name-as-directory (expand-file-name harness-directory)))
           (self (expand-file-name "harness.el" dir))
           (real (and (not (file-remote-p dir)) (file-exists-p self)
                      (file-name-directory (file-truename self)))))
      (if (and real (not (equal real dir))) (list dir real) (list dir)))))

(defun harness-perms-inspection-dirs ()
  "Return the directories of the harness itself as (:dir DIR :source SOURCE).
SOURCE is `harness' for the directories of its code (see
`harness-perms--harness-code-dirs') and `state' for
`harness-state-directory', which holds the sessions with their
transcripts, the task boards and the usage records.  Every session may
read them, in every mode, since inspecting the harness is part of what
it is for (see `harness-perms--inspectable-p'); they are no roots, so
writing there or running a command there stays jailed, and the
credentials in `harness-perms--private-files' stay out of reach."
  (cl-remove-duplicates
   (append (mapcar (lambda (d) (list :dir d :source 'harness)) (harness-perms--harness-code-dirs))
           (and (stringp harness-state-directory)
                (list (list :dir (file-name-as-directory (expand-file-name harness-state-directory))
                            :source 'state))))
   :test #'equal :key (lambda (e) (plist-get e :dir)) :from-end t))

(defun harness-perms--private-paths ()
  "Return the absolute paths of `harness-perms--private-files'."
  (and (stringp harness-state-directory)
       (mapcar (lambda (f) (expand-file-name f harness-state-directory)) harness-perms--private-files)))

(defun harness-perms--private-p (tool path)
  "Non-nil when TOOL at PATH would reach the harness's credentials.
That is when PATH is one of `harness-perms--private-files', or, for a
tool that may read the files below a directory (any tool but those of
`harness-perms--listing-tools'), when PATH holds one of them."
  (let ((listing (member tool harness-perms--listing-tools)))
    (cl-some (lambda (private)
               (or (harness-perms--within-p private path)
                   (and (not listing) (harness-perms--within-p path private))))
             (harness-perms--private-paths))))

(defun harness-perms--inspectable-p (request path)
  "Non-nil when REQUEST may read PATH because it is part of the harness itself.
REQUEST must only read (its kind is `read'), PATH must lie in one of
`harness-perms-inspection-dirs' and the call must not reach the
harness's credentials (`harness-perms--private-p').  Symbolic links
are resolved first, as the jail resolves them, so a link elsewhere
does not lead into the harness, nor one in the harness out of it."
  (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
       (stringp path)
       (not (file-remote-p path))
       (cl-some (lambda (e) (harness-perms--within-p (plist-get e :dir) path))
                (harness-perms-inspection-dirs))
       (not (harness-perms--private-p (plist-get request :tool) path))))

(defun harness-perms--inspection-hint (request path)
  "Return what REQUEST's agent may still do with PATH in the harness, or \"\".
PATH is outside the session's roots.  When it lies in the harness
itself (see `harness-perms-inspection-dirs'), a call that does more
than read, or a request for the directory, learns that reading it
needs no grant, and a read refused for reaching the credentials
learns which files those are.  Elsewhere the hint is that of a skills
directory (`harness-perms--skills-hint')."
  (cond
   ((or (file-remote-p path)
        (not (cl-some (lambda (e) (harness-perms--within-p (plist-get e :dir) path))
                      (harness-perms-inspection-dirs))))
    (harness-perms--skills-hint request path))
   ((not (eq (harness-perms--sym (plist-get request :kind)) 'read))
    (if (harness-perms--inspectable-p (list :kind 'read :tool "list_dir") path)
        " It is part of the harness itself, which the tools that only read (read_file, list_dir, glob, grep, file_info) may read without a grant."
      ""))
   (t
    (format " No tool may read the harness's credentials (%s); the rest of the harness needs no grant, so read or search the files and directories beside them instead."
            (mapconcat #'abbreviate-file-name (harness-perms--private-paths) ", ")))))

(defun harness-perms--unreachable (request roots)
  "Return the first path of REQUEST it may not reach, or nil.
A path is reachable when it lies inside one of ROOTS, or, for a call
that only reads, inside the harness itself (`harness-perms--inspectable-p'),
a skills directory (`harness-perms--skill-readable-p') or a file the
user's Emacs showed a definition in (`harness-perms--revealed-p')."
  (cl-find-if (lambda (p) (and (harness-perms--outside (list p) roots)
                               (not (harness-perms--inspectable-p request p))
                               (not (harness-perms--skill-readable-p request p))
                               (not (harness-perms--revealed-p request p))))
              (plist-get request :paths)))

(defun harness-perms--reads-harness-p (request)
  "Non-nil when REQUEST reads the harness itself outside the session's roots.
That is a call the jail lets through (see `harness-perms--unreachable')
with a path outside the roots, and the mode stage allows it in every
mode."
  (let ((paths (plist-get request :paths)))
    (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
         paths
         (let ((roots (append (harness-perms-roots (plist-get request :session))
                              (plist-get request :jail-once))))
           (and (not (harness-perms--unreachable request roots))
                (harness-perms--outside paths roots)
                t)))))

;;;; Files the user's Emacs showed a definition in
;;
;; emacs_find_definition, which inspects the user's Emacs and so never
;; needs approval, names the file a definition was loaded from and shows
;; the definition's source.  An agent that wants the code around it then
;; reads that file, which mostly lies outside the session's roots (the
;; user's configuration, a package): asking the user about it would ask
;; again about what the inspection already showed.  So the tool reports
;; the file (`permission/reveal-file'), and a call that only reads may
;; read it for the rest of the session, in every mode.  Only that file:
;; its directory, and writing the file, stay jailed, and the harness's
;; credentials stay out of reach.  A definition's file is Lisp the
;; user's Emacs loaded, whose definitions and values the inspection
;; tools show anyway.

(defvar harness-perms--revealed (make-hash-table :test 'equal)
  "Session id -> the files the user's Emacs showed a definition in.
Each is local and has its symbolic links resolved; see
`permission/reveal-file'.")

(defun harness-perms--revealed-p (request path)
  "Non-nil when REQUEST may read PATH because the user's Emacs showed it.
REQUEST must only read, PATH must be on this machine and be, symbolic
links resolved, one of the files `permission/reveal-file' recorded for
REQUEST's session, and the call must not reach the harness's
credentials."
  (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
       (stringp path)
       (not (file-remote-p path))
       (let ((files (gethash (plist-get (plist-get request :session) :id) harness-perms--revealed)))
         (and files (member (harness-path-normalize path) files)))
       (not (harness-perms--private-p (plist-get request :tool) path))
       t))

(defun harness-perms--reads-revealed-p (request)
  "Non-nil when REQUEST reads, outside the session's roots, only revealed files.
Those are the files the user's Emacs showed a definition in (see
`harness-perms--revealed-p'); the mode stage allows such a call in
every mode."
  (let ((paths (plist-get request :paths)))
    (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
         paths
         (let* ((roots (append (harness-perms-roots (plist-get request :session))
                               (plist-get request :jail-once)))
                (outside (cl-remove-if-not (lambda (p) (harness-perms--outside (list p) roots)) paths)))
           (and outside
                (cl-every (lambda (p) (harness-perms--revealed-p request p)) outside)
                t)))))

(harness-defmethod permission/reveal-file (session-id file)
  "Let SESSION-ID's calls that only read read FILE from now on.
FILE is the source file the user's Emacs showed a definition in, as an
inspection tool (emacs_find_definition) reports it.  Only FILE itself
becomes readable, not its directory; see \"Files the user's Emacs
showed a definition in\".  Return FILE as recorded, its symbolic links
resolved, or nil when it is no local, existing regular file."
  (when (and (stringp session-id) (stringp file)
             (file-name-absolute-p file) (not (file-remote-p file)))
    (let ((real (harness-path-normalize file)))
      (when (file-regular-p real)
        (let ((files (gethash session-id harness-perms--revealed)))
          (unless (member real files)
            (puthash session-id (cons real files) harness-perms--revealed)))
        real))))

(defun harness-perms--forget-revealed (session-id &rest _)
  "Forget the files revealed to SESSION-ID, which is gone."
  (remhash session-id harness-perms--revealed))

;;;; Skills, which every session may read
;;
;; Agents read skills directly as well as through skill_load: the files
;; a loaded skill lists, a SKILL.md whose place they know.  Those
;; directories mostly lie outside the session's roots, and a prompt
;; about one would stop an unattended task over nothing, so a call that
;; only reads may read every directory skill discovery reads, in every
;; mode, as it may read the harness itself.  The skills module says
;; which (`skills/directories'); without it there are none.  They are
;; no roots: writing there, or running a command there, stays jailed,
;; and the sandbox shows them to bash read-only.
;;
;; Where reading one does not fit, the call is refused at once, in
;; every mode, and the user is not asked: a path in a skills directory
;; that symbolic links lead out of it (or out of the project or plugin
;; that provides it), the skills directories of a remote session's host,
;; which are not the ones the harness serves, and, from bash in the
;; sandbox, a path in one that the sandbox does not show.  The refusal
;; points the agent to skill_search and skill_load, which read the
;; skills on this machine and never need approval.

(defconst harness-perms-skills-hint
  "Skills have tools of their own, which never need approval: skill_search lists them, skill_load NAME returns a skill's instructions and the list of its files, and skill_load with file set to one of those returns that file."
  "Hint attached to a refusal over a skills directory.")

(defun harness-perms-skill-dirs (session)
  "Return the skills directories of SESSION as (:dir DIR :source S :contained B).
They are what `skills/directories' returns for SESSION's cwd, or, for
a remote session, for no cwd at all: the skills the harness serves are
on this machine, and the permission chain never reaches out to another
host.  A call that only reads may read the `:contained' ones (see
`harness-perms--skill-readable-p').  Without the skills module there
are none."
  (when (harness-method-exists-p 'skills/directories)
    (let ((cwd (plist-get session :cwd)))
      (condition-case err
          (harness-call 'skills/directories
                        (and (stringp cwd) (not (plist-get session :host)) (not (file-remote-p cwd)) cwd))
        (error (harness-log 'warn "perms: could not list the skills directories: %S" err)
               nil)))))

(defun harness-perms--skill-readable-p (request path &optional dirs)
  "Non-nil when REQUEST may read PATH because it lies in a skills directory.
REQUEST must only read, PATH must be on this machine and lie, symbolic
links resolved, in one of the `:contained' directories of
`harness-perms-skill-dirs' (or of DIRS, a list of them), and the call
must not reach the harness's credentials."
  (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
       (stringp path)
       (not (file-remote-p path))
       (cl-some (lambda (e) (and (plist-get e :contained) (harness-perms--within-p (plist-get e :dir) path)))
                (or dirs (harness-perms-skill-dirs (plist-get request :session))))
       (not (harness-perms--private-p (plist-get request :tool) path))))

(defun harness-perms--reads-skills-p (request)
  "Non-nil when REQUEST reads skills outside the session's roots, and nothing else.
That is a call that only reads, whose every path outside the roots
lies in a skills directory it may read (see
`harness-perms--skill-readable-p'); the mode stage allows it in every
mode."
  (let ((paths (plist-get request :paths)))
    (and (eq (harness-perms--sym (plist-get request :kind)) 'read)
         paths
         (let* ((session (plist-get request :session))
                (roots (append (harness-perms-roots session) (plist-get request :jail-once)))
                (outside (cl-remove-if-not (lambda (p) (harness-perms--outside (list p) roots)) paths))
                (dirs (and outside (harness-perms-skill-dirs session))))
           (and outside
                (cl-every (lambda (p) (harness-perms--skill-readable-p request p dirs)) outside)
                t)))))

(defun harness-perms--skills-dir-of (path dirs)
  "Return the skills directory of DIRS that PATH lies in as written, or nil.
DIRS are `harness-perms-skill-dirs'.  Symbolic links are not resolved:
this is where PATH says it is.  A remote PATH names one of them,
which are on this machine, when its local part is the same path, or
the same place in a home directory on its host, such as
/home/USER/.claude/skills/x for ~/.claude/skills."
  (let* ((remote (file-remote-p path))
         (local (file-name-as-directory (if remote (or (file-remote-p path 'localname) "/") path)))
         (home (file-name-as-directory (expand-file-name "~"))))
    (cl-find-if (lambda (dir)
                  (or (string-prefix-p dir local)
                      (and remote (string-prefix-p home dir)
                           (string-match-p (concat "\\`\\(?:~\\|/root\\|/\\(?:home\\|Users\\)/[^/]+\\)/"
                                                   (regexp-quote (substring dir (length home))))
                                           local))))
                (mapcar (lambda (e) (file-name-as-directory (plist-get e :dir))) dirs))))

(defun harness-perms--confined-p (request)
  "Non-nil when REQUEST's shell command runs in the sandbox."
  (and (harness-method-exists-p 'sandbox/confined-p)
       (condition-case nil
           (harness-call 'sandbox/confined-p (harness-perms--command-dir request))
         (error nil))))

(defun harness-perms--skills-refusal (request roots)
  "Return the decision refusing REQUEST at once over a skills directory, or nil.
A call that only reads is refused for a path outside ROOTS that lies
in a skills directory as written but may not be read there (see
`harness-perms--skill-readable-p'): symbolic links lead it out, or it
is on a remote session's host.  A shell command that runs in the
sandbox is refused for a path it names in a skills directory that the
sandbox does not show.  The refusal is final and points the agent to
skill_search and skill_load (`harness-perms-skills-hint'), so nobody is
asked about a directory the agent has a tool for."
  (let* ((session (plist-get request :session))
         (kind (harness-perms--sym (plist-get request :kind)))
         (exec (and (eq kind 'exec) (harness-perms--command request) (harness-perms--confined-p request)))
         (candidates (cond ((eq kind 'read) (plist-get request :paths))
                           (exec (harness-perms--named-paths request))))
         (outside (cl-remove-if-not (lambda (p) (harness-perms--outside (list p) roots)) candidates))
         (dirs (and outside (harness-perms-skill-dirs session)))
         (as-read (if exec (list :kind 'read :tool "read_file" :session session) request))
         (path (cl-find-if (lambda (p) (and (harness-perms--skills-dir-of p dirs)
                                            (not (harness-perms--inspectable-p as-read p))
                                            (not (harness-perms--skill-readable-p as-read p dirs))))
                           outside)))
    (when path
      (let* ((dir (abbreviate-file-name (harness-perms--skills-dir-of path dirs)))
             (host (file-remote-p path))
             (target (and (not host) (harness-path-normalize path))))
        (list :behavior 'deny :final t
              :reason (cond
                       (host (format "%s is a skills directory on %s, not the skills the harness serves, which are on this machine"
                                     path host))
                       (exec (format "the command names %s, in the skills directory %s, but that leads to %s, which the sandbox does not show"
                                     (abbreviate-file-name path) dir (abbreviate-file-name target)))
                       (t (format "%s is in the skills directory %s, but leads to %s, outside what may be read without approval"
                                  (abbreviate-file-name path) dir (abbreviate-file-name target))))
              :hint (concat harness-perms-skills-hint
                            (if host
                                (format " Ask for the directory with request_directory_access only if the task is about the files of %s itself."
                                        host)
                              (format " If the task needs %s itself, ask for it with request_directory_access."
                                      (abbreviate-file-name (harness-perms--dir-of target))))))))))

(defun harness-perms--skills-hint (request path)
  "Return what REQUEST's agent may still do with PATH in a skills directory, or \"\".
PATH is outside the session's roots.  When a call that does more than
read, or a request for the directory, is about a skills directory that
every call that only reads may read, the agent learns so."
  (if (and (not (eq (harness-perms--sym (plist-get request :kind)) 'read))
           (harness-perms--skill-readable-p (list :kind 'read :tool "list_dir" :session (plist-get request :session))
                                            path))
      " It holds skills, which the tools that only read (read_file, list_dir, glob, grep, file_info) may read without a grant; skill_load loads one."
    ""))

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

(defconst harness-perms--repository-markers '(".git" ".hg" ".jj" ".svn" ".bzr" "_darcs" ".fslckout")
  "Names whose presence makes a directory the root of a repository.")

(defun harness-perms--repository-root (dir)
  "Return the root of the repository DIR lies in, as a directory name, or nil.
That is the closest directory holding DIR, DIR included, with one of
`harness-perms--repository-markers': a project, a package's checkout,
a configuration kept in git.  A remote DIR has none here: looking would
open a TRAMP connection from inside the permission chain."
  (unless (file-remote-p dir)
    (when-let* ((root (locate-dominating-file
                       dir (lambda (d)
                             (cl-some (lambda (m) (file-exists-p (expand-file-name m d)))
                                      harness-perms--repository-markers)))))
      (file-name-as-directory (expand-file-name root)))))

(defun harness-perms--prompt-dir (session dir)
  "Return the directory a prompt about DIR, outside SESSION's roots, offers.
That is the root of the repository DIR lies in (see
`harness-perms--repository-root'), so one answer opens the project or
package a file belongs to, not just the directory holding it: an agent
finding its way around one asked about each directory it reached in
turn.  It is DIR itself when DIR lies in no repository, and when that
root would open too much: the root directory, the home directory or a
directory holding it, or one holding SESSION's working directory or
worktree, such as the main checkout of a worktree.  The user may still
edit the prompt's pattern to something narrower."
  (let ((root (harness-perms--repository-root dir))
        (home (expand-file-name "~"))
        (own (delq nil (list (plist-get session :cwd) (plist-get session :worktree)))))
    (if (and root
             (not (equal root "/"))
             (not (harness-path-within-p root home))
             (not (cl-some (lambda (d) (and (stringp d) (not (file-remote-p d)) (harness-path-within-p root d)))
                           own)))
        root
      dir)))

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

;;;; What a shell command reaches
;;
;; The jail knows where a shell command runs, its `:paths' (the bash
;; tool's working directory), not what the command does there: `ls
;; ~/.claude' runs in the project and reads elsewhere.  A prompt about
;; it and the rules about paths need what it reaches, so that is read
;; off the command line: the words that are paths, as
;; `harness-perms--command-paths' finds them.  It is a best-effort
;; reading, not a shell parser, and the jail does not use it: a command
;; is confined by the sandbox and decided by the mode and the judge,
;; which read it whole.
;;
;; What the call is about, its subject (`harness-perms--subject-paths'),
;; is then the paths it names outside the session's directories, or,
;; when it names none there, where it runs, as for every other call.  A
;; prompt shows those, as a prompt about the call itself, without a
;; pattern (see `harness-perms--ask'), and an allow rule must hold every
;; one of them; a deny rule applies to any path the call names or runs
;; in.

(defconst harness-perms--shell-keywords
  '("!" "{" "}" "if" "then" "else" "elif" "fi" "do" "done" "while" "until"
    "for" "in" "case" "esac" "select" "function" "time")
  "Shell words after which a command, not an argument, comes.")

(defconst harness-perms--shell-prefixes
  '("sudo" "doas" "env" "exec" "command" "builtin" "nohup" "nice" "ionice" "xargs"
    "stdbuf" "chronic" "unbuffer")
  "Programs that run the command following them and their options.")

(defconst harness-perms--pseudo-files
  "\\`/\\(?:dev/\\(?:null\\|zero\\|full\\|random\\|urandom\\|tty\\|stdin\\|stdout\\|stderr\\|fd/[0-9]+\\)\\|proc/self/fd/[0-9]+\\)\\'"
  "Regexp of the files a command names that hold nothing of anyone's.")

(defun harness-perms--shell-words (command)
  "Return the words of shell COMMAND as (WORD . PROGRAM) pairs, in order.
Quotes and backslashes are undone and comments left out.  PROGRAM is
non-nil for the word a command starts with, the program it runs: the
first word of the line or after an operator (`;', `&', `|', `(', `$(',
`<(', an opening backquote), after NAME=VALUE assignments and keywords
such as `then', and after a prefix such as `sudo' or `xargs' and its
options.  A word after a redirection (`>', `<') is no program, and
neither is one after the end of a substitution or a subshell.  It is
a best-effort reading, not a parser: $HOME and other expansions stay
as written, and a here-document's lines are read as commands."
  (let ((i 0) (n (length command))
        (word nil)                      ; the word being read
        (program t)                     ; t, `prefix' or nil: a command comes next
        (target nil)                    ; the next word follows a redirection
        (backquoted nil)                ; inside `...`
        (words nil))
    (cl-labels ((finish ()
                  (when word
                    (cond
                     (target (push (cons word nil) words) (setq target nil))
                     ((not program) (push (cons word nil) words))
                     ((or (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" word)
                          (and (eq program 'prefix) (string-prefix-p "-" word)))
                      ;; An assignment, or an option of a prefix: the
                      ;; command is still to come.
                      (push (cons word nil) words))
                     ((member word harness-perms--shell-keywords) (push (cons word t) words))
                     (t (push (cons word t) words)
                        (setq program (and (member word harness-perms--shell-prefixes) 'prefix))))
                    (setq word nil)))
                (add (s) (setq word (concat word s)))
                (peek (k) (and (< (+ i k) n) (aref command (+ i k))))
                (command-starts () (finish) (setq program t target nil)))
      (while (< i n)
        (let ((c (aref command i)))
          (cond
           ((memq c '(?\s ?\t)) (finish))
           ((eq c ?\n) (command-starts))
           ((eq c ?\\)
            (unless (eq (peek 1) ?\n) (add (string (or (peek 1) ?\\))))
            (setq i (1+ i)))
           ((eq c ?')
            (let ((end (or (cl-position ?' command :start (1+ i)) n)))
              (add (substring command (1+ i) end))
              (setq i end)))
           ((eq c ?\")
            (setq i (1+ i))
            (add "")
            (while (and (< i n) (not (eq (aref command i) ?\")))
              (if (and (eq (aref command i) ?\\) (memq (peek 1) '(?\" ?\\ ?$ ?` ?\n)))
                  (progn (unless (eq (peek 1) ?\n) (add (string (peek 1))))
                         (setq i (+ i 2)))
                (add (string (aref command i)))
                (setq i (1+ i)))))
           ((and (eq c ?#) (null word))
            (setq i (1- (or (cl-position ?\n command :start i) n))))
           ((or (memq c '(?> ?<)) (and (eq c ?&) (eq (peek 1) ?>)))
            ;; A redirection: >, >>, >|, >&, &>, &>>, <, <<, <<<, <&.
            ;; <( and >( are process substitutions, which run a command.
            (finish)
            (if (eq (peek 1) ?\()
                (setq program t i (1+ i))
              (when (eq c ?&) (setq i (1+ i)))
              (while (memq (peek 1) '(?> ?< ?| ?&)) (setq i (1+ i)))
              (setq target t)))
           ((and (eq c ?$) (eq (peek 1) ?\())
            (command-starts)
            (setq i (1+ i)))
           ;; What follows a substitution or a subshell is an argument,
           ;; or an operator that starts a command again.
           ((or (eq c ?\)) (and (eq c ?`) backquoted))
            (finish)
            (setq program nil target nil backquoted nil))
           ((eq c ?`) (command-starts) (setq backquoted t))
           ((memq c '(?\; ?& ?| ?\()) (command-starts))
           (t (add (string c)))))
        (setq i (1+ i)))
      (finish))
    (nreverse words)))

(defun harness-perms--path-word (word)
  "Return the path shell WORD names, as written, or nil.
That is WORD, or the value of a NAME=VALUE or --option=VALUE word, when
it is absolute, starts with ~ or $HOME, or is . or .. or starts with ./
or ../: other relative words could as well be no path at all."
  (let ((value (if (string-match "\\`-*[A-Za-z0-9_.-]*=" word) (substring word (match-end 0)) word)))
    (cond ((string-match "\\`\\(?:\\$HOME\\|\\${HOME}\\)\\(/\\|\\'\\)" value)
           (concat "~" (substring value (match-beginning 1))))
          ((string-match-p "\\`\\(?:/\\|~\\|\\.\\.?/\\|\\.\\.?\\'\\)" value) value))))

(defun harness-perms--command (request)
  "Return the shell command REQUEST runs, or nil.
That is the `:command' of an exec call, such as the bash tool's."
  (let* ((input (plist-get request :input))
         (command (and (listp input) (plist-get input :command))))
    (and (stringp command)
         (eq (harness-perms--sym (plist-get request :kind)) 'exec)
         command)))

(defun harness-perms--command-dir (request)
  "Return the directory REQUEST's shell command runs in."
  (or (car (plist-get request :paths))
      (harness-perms--with-host (or (plist-get (plist-get request :session) :cwd) default-directory)
                                (plist-get (plist-get request :session) :host))))

(defun harness-perms--command-paths (request)
  "Return the paths REQUEST's shell command names, absolute, or nil.
They are the words `harness-perms--path-word' takes for paths, other
than the programs the command runs (see `harness-perms--shell-words')
and files such as /dev/null; relative ones are relative to where the
command runs.  On this machine an absolute word counts only when its
first directory exists, so a pattern such as /api/v1 in a grep is no
path; on a remote host none is looked up, and words starting with ~
are left out, since only that host knows its home."
  (when-let* ((command (harness-perms--command request)))
    (condition-case err
        (let* ((dir (harness-perms--command-dir request))
               ;; The host the command runs on: its directory's, which
               ;; for the ssh tool is not the session's, else the
               ;; session's.
               (remote (or (file-remote-p dir) (plist-get (plist-get request :session) :host)))
               (local-dir (or (file-remote-p dir 'localname) dir))
               paths)
          (pcase-dolist (`(,word . ,program) (harness-perms--shell-words command))
            (let ((value (and (not program) (harness-perms--path-word word))))
              (when (and value (not (string-match-p "\n" value)))
                (let ((path (cond ((not remote) (expand-file-name value dir))
                                  ((string-prefix-p "~" value) nil)
                                  (t (harness-perms--with-host (expand-file-name value local-dir) remote)))))
                  (when (and path
                             (not (string-match-p harness-perms--pseudo-files (cdr (harness-perms--split path))))
                             (or remote
                                 (not (string-prefix-p "/" value))
                                 (file-exists-p (concat "/" (car (split-string path "/" t)))))
                             (not (member path paths)))
                    (push path paths))))))
          (nreverse paths))
      (error (harness-log 'warn "perms: could not read the paths of a command: %S" err)
             nil))))

(defun harness-perms--named-paths (request)
  "Return the paths REQUEST's command names (see `harness-perms--command-paths').
A request `harness-perms--with-reach' worked them out for carries them."
  (if (plist-member request :named-paths)
      (plist-get request :named-paths)
    (harness-perms--command-paths request)))

(defun harness-perms--subject-paths (request)
  "Return the paths REQUEST's call is about, for its prompt and its rules.
A shell command is about the paths it names (`harness-perms--named-paths')
outside the session's directories; when it names none there, it is about
where it runs, its `:paths', as every other call is."
  (if (plist-member request :subject-paths)
      (plist-get request :subject-paths)
    (let* ((named (harness-perms--named-paths request))
           (roots (and named (harness-perms-roots (plist-get request :session)))))
      (or (cl-remove-if (lambda (p) (cl-some (lambda (r) (harness-perms--within-p r p)) roots)) named)
          (plist-get request :paths)))))

(defun harness-perms--every-path (request)
  "Return every path REQUEST's call runs in or names."
  (cl-remove-duplicates (append (plist-get request :paths) (harness-perms--named-paths request))
                        :test #'equal :from-end t))

(defun harness-perms--with-reach (request)
  "Return REQUEST with what its call reaches worked out once.
The copy carries `:named-paths' and `:subject-paths', which the
functions above take instead of reading the command again for every
rule."
  (if (plist-member request :subject-paths)
      request
    (let ((named (harness-perms--command-paths request)))
      (append (list :named-paths named
                    :subject-paths (harness-perms--subject-paths (append (list :named-paths named) request)))
              request))))

;;;; Patterns a prompt about a directory is answered for
;;
;; A prompt about a path outside the allowed directories (the jail's,
;; an agent's directory request) is answered for a glob pattern rather
;; than one file: by default everything in a directory (`DIR/**').  The
;; jail offers the root of the repository the path lies in, so one
;; answer covers the project or package an agent is finding its way
;; around, rather than one directory of it at a time; the directory
;; holding a file, or the directory itself, when there is no such root
;; or it would open too much (`harness-perms--prompt-dir').  An agent's
;; request offers the directory it asked for.  The prompt's payload
;; carries the pattern as `:pattern' and the user may answer with
;; another one, more or less specific, in the answer's `:pattern'.
;; Only these prompts carry one (see `harness-perms--ask').

(defun harness-perms--default-pattern (dir)
  "Return the pattern a prompt about DIR offers: everything in DIR."
  (concat (file-name-as-directory dir) "**"))

(defun harness-perms--expand-pattern (session pattern)
  "Return PATTERN absolute for SESSION: against its cwd, on its host."
  (harness-perms--with-host (expand-file-name pattern (or (plist-get session :cwd) default-directory))
                            (plist-get session :host)))

(defun harness-perms--answered-pattern (session waiting answer)
  "Return the pattern ANSWER to the prompt WAITING of SESSION is for.
That is the answer's `:pattern', made absolute, or else the pattern
the prompt offered; nil for a prompt that offered none."
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
A call that only reads may also read the harness itself (see
`harness-perms--inspectable-p') and the skills directories (see
`harness-perms--skill-readable-p').  Otherwise ask the user for access
to the directory, or deny when nobody can answer or a rule denies the
call anyway; a call about a skills directory it may not reach is
refused at once (`harness-perms--skills-refusal').  DECISION is the
current value and NEXT continues the chain.  Roots in the request's
`:jail-once' were allowed for this call only."
  (let ((paths (plist-get request :paths)))
    (if (null paths)
        (funcall next decision)
      (let* ((session (plist-get request :session))
             (roots (append (harness-perms-roots session) (plist-get request :jail-once)))
             (bad (harness-perms--unreachable request roots))
             (rule (and bad (harness-perms--find-rule request)))
             (refusal (harness-perms--skills-refusal request roots)))
        (cond
         ((and (null bad) (null refusal)) (funcall next decision))
         ;; A rule denies the call (an "Always deny" of an earlier
         ;; prompt, say): no point asking for the directory.
         ((eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
          (funcall next (plist-put (harness-perms--rule-decision rule) :final t)))
         ;; The agent has tools for skills: nobody is asked.
         (refusal (funcall next refusal))
         ((and (not (harness-perms--non-interactive-p session))
               (harness-method-exists-p 'session/pending-add))
          (harness-perms--ask-dir decision next request bad))
         (t
          (funcall next
                   (list :behavior 'deny :final t
                         :reason (format "%s is outside the allowed directories" bad)
                         :hint (format "Allowed roots: %s. Work inside them, or ask the user to grant access to %s with the allow-dir command.%s%s"
                                       (mapconcat #'abbreviate-file-name roots ", ")
                                       (abbreviate-file-name (harness-perms--dir-of bad))
                                       (harness-perms--scratch-hint session bad)
                                       (harness-perms--inspection-hint request bad))))))))))

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
The prompt offers the root of the repository BAD lies in, when that is
not too wide (see `harness-perms--prompt-dir').  DECISION and NEXT
continue the chain once `permission/answer' arrives."
  (harness-perms--pend-dir request next
                           (harness-perms--prompt-dir (plist-get request :session) (harness-perms--dir-of bad))
                           (format "%s wants %s, which is outside the allowed directories"
                                   (harness-tools-label (plist-get request :tool)) (abbreviate-file-name bad))
                           (harness-perms--dir-prompt-options harness-perms-dir-options)
                           :decision decision))

(defun harness-perms--answer-dir (session-id waiting answer)
  "Continue the chain for WAITING of SESSION-ID after the user's ANSWER.
The answer is for its pattern (`harness-perms--answered-pattern'): an
allow grants it, `DIR/**' as the directory DIR/; a deny for the
session or always records a rule denying it to every tool.  What an
answer for the session or always records is noted in the session's
transcript, where it can be undone (`harness-perms--note-recorded').
A jail prompt goes on through the jail; an agent's own request (see
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
        (harness-perms--add-rule-noted session-id (list :path pattern :behavior 'deny) scope))
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
      (if (memq scope '(session always))
          (harness-perms--allow-dir-noted session-id grant scope)
        (setq request (plist-put (copy-sequence request) :jail-once
                                 (cons grant (plist-get request :jail-once)))))
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
                (harness-perms--rules (plist-get session :id)))))

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
                            :hint (format "Work inside the allowed directories (%s). If the task cannot be done without %s, finish what you can and say so in your answer; the user can grant it with M-x harness-directories.%s%s"
                                          (mapconcat #'abbreviate-file-name roots ", ")
                                          (abbreviate-file-name dir)
                                          (harness-perms--scratch-hint session dir)
                                          (harness-perms--inspection-hint request dir)))))
       (t
        ;; The prompt shows the directory and the agent's reason; the
        ;; input keeps only the path so the reason is not shown twice.
        (harness-perms--pend-dir (plist-put (copy-sequence request) :input (list :path path))
                                 next dir
                                 (harness-perms--request-reason session dir (plist-get input :reason))
                                 (harness-perms--dir-prompt-options harness-perms-dir-request-options)
                                 :explicit t))))))

(defun harness-perms--grant-requested (session-id grant scope input)
  "Grant GRANT to SESSION-ID as the user allowed it; return the decision.
This is the answer to an agent's own request.  GRANT is a directory or
a glob pattern.  SCOPE `always' adds it to `harness-allowed-directories',
`session' grants it to the session (both noted in the transcript, see
`harness-perms--allow-dir-noted'), and `once' grants it until the
session's turn ends (`harness-perms--grant-for-turn').  The tool gets
INPUT's path with `:granted' GRANT, so it can tell the agent.  When the
policy sets `harness-allowed-directories', `always' grants to the
session."
  (condition-case err
      (let ((scope (harness-perms--scope-allowed scope 'harness-allowed-directories)))
        (if (memq scope '(session always))
            (harness-perms--allow-dir-noted session-id grant scope)
          (harness-perms--grant-for-turn session-id grant))
        (list :behavior 'allow :final t
              :input (list :path (plist-get input :path) :granted grant)
              :reason (format "the user granted %s %s" (abbreviate-file-name grant)
                              (pcase scope
                                ('always "to every session")
                                ('session "to this session")
                                (_ "to this session until this turn ends")))))
    (error
     (harness-log 'error "perms: granting %s to %s failed: %S" grant session-id err)
     (list :behavior 'deny :final t
           :reason (format "granting %s failed: %s" (abbreviate-file-name grant) (harness-error-message err))))))

(defun harness-perms--grant-for-turn (session-id grant)
  "Grant GRANT, a directory or a glob pattern, to SESSION-ID until its turn ends.
That is what allow-once means for an agent's own request for a
directory: the agent can do what it asked for in the turn it asked in,
and nothing is remembered.  The grant joins the session's roots (source
`turn') until `harness-perms--end-turn-grants' drops it.  Return it."
  (let* ((dir (harness-perms--expand-dir (harness-perms--session session-id) grant))
         (dirs (gethash session-id harness-perms--turn-dirs)))
    (unless (member dir dirs)
      (puthash session-id (append dirs (list dir)) harness-perms--turn-dirs))
    (harness-emit 'permission/dir-allowed session-id dir)
    dir))

(defun harness-perms--end-turn-grants (session-id &rest _)
  "Drop what SESSION-ID was granted until its turn ends.
On `agent/turn-ended', and on `agent/turn-started' too: a grant made
while no turn ran (the turn that asked was cancelled before the answer
came) must not reach the next turn."
  (when-let* ((dirs (gethash session-id harness-perms--turn-dirs)))
    (remhash session-id harness-perms--turn-dirs)
    (dolist (dir dirs)
      (harness-emit 'permission/dir-revoked session-id dir))))

(defun harness-perms--source-label (source)
  "Return how the request tool describes directory SOURCE to the agent."
  (pcase source
    ('cwd "the working directory")
    ('worktree "the worktree")
    ('tmp "this session's own temporary directory")
    ('config "allowed for every session")
    ('session "granted to this session")
    ('turn "granted to this session until this turn ends")
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
                 (pcase (plist-get grant :source)
                   ('config "every session")
                   ('turn "the rest of this turn (ask again in a later turn if you need it then)")
                   (_ "this session"))
                 (if glob "the paths it matches" "what it holds")
                 (if glob
                     "; bash may not see them, since its sandbox shows whole directories only"
                   ", and bash sees it at the same path")))))
     ((null entry)
      (harness-tool-error (format "%s is still outside the allowed directories." shown)))
     (t
      (harness-tool-ok
       (concat
        (pcase (list (plist-get entry :source) (equal (plist-get entry :dir) dir))
          ('(session t) (format "%s is now an allowed directory of this session." shown))
          ('(turn t) (format "%s is now allowed for the rest of this turn (ask again in a later turn if you need it then)."
                             shown))
          ('(config t) (format "%s is now an allowed directory of every session." shown))
          (`(,source ,_) (format "%s is already accessible: it lies inside %s (%s)." shown
                                 (abbreviate-file-name (plist-get entry :dir))
                                 (harness-perms--source-label source))))
        " Tools that take paths can use it, and bash sees it at the same path."))))))

(harness-define-tool harness-perms-dir-tool
  :label "Request access"
  :description "Ask the user for access to a directory outside the allowed directories (the working directory and the directories granted so far), for instance another repository you need to read or change. The user is always asked, in every permission mode, and either grants it for the rest of this turn, to this session or to every session, or denies it; the call waits for the answer. The user may grant a narrower or wider path or glob pattern than you asked for; the result says what was granted. Ask for the narrowest directory that does the job and say why. If the user denies it, do not ask again. A non-interactive session cannot ask and is denied at once."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "The directory, absolute or relative to the working directory.")
                         :reason (:type "string" :description "Why you need it; shown to the user."))
            :required ("path" "reason"))
  :kind 'meta
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-perms--dir-request-result)

;;;; Requests to turn non-interactive mode on

(defun harness-perms--away-target (input)
  "Return what a call of `harness-perms-away-tool' with INPUT changes, as text."
  (let ((ref (plist-get input :session_id)))
    (cond ((harness-json-true-p (plist-get input :all))
           "every current session and task, of every project")
          ((and (stringp ref) (not (harness-string-blank-p ref)))
           (format "session %s" (string-trim ref)))
          (t "this session"))))

(defun harness-perms--away-request (decision next request)
  "Decide a call to `harness-perms-away-tool' as only the user may.
REQUEST is the call; any other goes on with DECISION, handed to NEXT
as it is.  Turning non-interactive mode off brings the user back in,
so it is allowed at once.  Turning it on takes the user out of every
decision, so the decision handed to NEXT is final, and the mode, the
standing rules and the auto-mode judge never see it: the call is
denied when nobody can answer (a non-interactive session is denied at
once), and otherwise waits for the user, whose answer holds for this
call alone."
  (if (not (equal (plist-get request :tool) harness-perms-away-tool))
      (funcall next decision)
    (let* ((session (plist-get request :session))
           (input (plist-get request :input))
           (away (harness-perms--non-interactive-p session))
           (target (harness-perms--away-target input)))
      (cond
       ((not (harness-json-true-p (plist-get input :enabled)))
        (funcall next (list :behavior 'allow :final t
                            :reason "turning non-interactive mode off only brings the user back in")))
       ((or away (not (harness-method-exists-p 'session/pending-add)))
        (funcall next (list :behavior 'deny :final t
                            :reason (format "nobody can confirm turning non-interactive mode on for %s: %s"
                                            target
                                            (if away "this session is non-interactive and the user is away"
                                              "no user is available"))
                            :hint "Only the user can turn non-interactive mode on. Do not ask again: carry on as you are, and say in your answer that the user can turn it on with M-x harness-set-non-interactive-all.")))
       (t
        (let* ((sid (plist-get session :id))
               (why (plist-get input :reason))
               (pending (list :kind 'permission
                              :payload (list :tool (plist-get request :tool)
                                             :input (plist-get request :input)
                                             :kind (plist-get request :kind)
                                             :call-id (plist-get request :call-id)
                                             :title (format "Turn non-interactive mode on for %s" target)
                                             :reason (concat
                                                      (if (and (stringp why) (not (harness-string-blank-p why)))
                                                          (format "The agent asks: %s.  "
                                                                  (string-remove-suffix "." (string-trim why)))
                                                        "")
                                                      "Nobody is asked anything there until it is turned off again: the auto-mode judge decides what would ask you.")
                                             :options harness-perms-away-options)))
               (pid (harness-call 'session/pending-add sid pending)))
          (puthash pid (list :session-id sid :request request :next next :user-only t)
                   harness-perms--waiting)
          (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid))))))))

(defun harness-perms--answer-user-only (session-id pending-id waiting answer)
  "Answer the prompt WAITING (PENDING-ID of SESSION-ID) only the user answers.
ANSWER decides this call and nothing else: whatever its scope, no rule
is recorded.  Return the final decision."
  (let* ((answer (harness-perms--parse-answer answer))
         (allow (eq (plist-get answer :behavior) 'allow))
         (decision (append (list :behavior (if allow 'allow 'deny) :final t
                                 :reason (or (plist-get answer :reason)
                                             (if allow "the user confirmed it" "the user refused it")))
                           (unless allow
                             (list :hint "Do not ask again; carry on as you are.")))))
    (harness-perms--resolve session-id pending-id answer)
    (funcall (plist-get waiting :next) decision)
    decision))

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
allow rule when the pattern covers every path the call is about (see
`harness-perms--subject-paths'), a deny rule when it covers any path
the call runs in or names (see `harness-perms--within-p').  For a shell
command an allow rule so holds the paths it names outside the
session's directories, or where it runs when it names none there; a
deny rule also stops it for a path it names inside them."
  (let* ((tool (plist-get rule :tool))
         (kind (harness-perms--sym (plist-get rule :kind)))
         (deny (eq (harness-perms--sym (plist-get rule :behavior)) 'deny))
         (pattern (harness-perms--rule-pattern rule (plist-get request :session))))
    (and (or (null tool) (equal tool (plist-get request :tool)))
         (or (null kind) (eq kind (harness-perms--sym (plist-get request :kind))))
         (or (null pattern)
             (let ((paths (if deny (harness-perms--every-path request) (harness-perms--subject-paths request))))
               (and paths
                    (funcall (if deny #'cl-some #'cl-every)
                             (lambda (p) (harness-perms--within-p pattern p))
                             paths)))))))

(defun harness-perms--rules (session-id)
  "Return the rules of SESSION-ID in the order they are weighed, first first.
Its own rules (answers for the session) come before the standing ones
\(`harness-perms-rules'), unless the policy sets those: then they come
first, so no answer overrides them."
  (let ((own (gethash session-id harness-perms--session-rules)))
    (if (harness-policy-pinned-p 'harness-perms-rules)
        (append harness-perms-rules own)
      (append own harness-perms-rules))))

(defun harness-perms--find-rule (request)
  "Return the first session or global rule that applies to REQUEST.
See `harness-perms--rules' for the order."
  (let* ((sid (plist-get (plist-get request :session) :id))
         (rules (harness-perms--rules sid))
         ;; A command is read once, not once per rule about paths.
         (request (if (cl-some (lambda (r) (plist-get r :path)) rules)
                      (harness-perms--with-reach request)
                    request)))
    (cl-find-if (lambda (r) (harness-perms--rule-matches-p r request)) rules)))

(defun harness-perms--rule-subject (rule)
  "Return what RULE is for, in a few words: its tool, its path, or both."
  (let* ((tool (plist-get rule :tool))
         (path (plist-get rule :path))
         (path (and (stringp path) (not (harness-string-blank-p path)) (abbreviate-file-name path))))
    (cond ((and tool path) (format "%s in %s" tool path))
          ((or tool path))
          (t "every tool"))))

(defun harness-perms--rule-decision (rule)
  "Return the decision RULE makes, with a reason that names what it is for."
  (let ((what (harness-perms--rule-subject rule)))
    (if (eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
        (list :behavior 'deny :reason (format "denied by a standing rule for %s" what)
              :hint "Do not retry this call; choose a different approach.")
      (list :behavior 'allow :reason (format "allowed by a standing rule for %s" what)))))

(defun harness-perms--announce-option (symbol)
  "Tell the views that option SYMBOL was saved here, as `config/set' does.
An answer or its undo saves `harness-perms-rules' or
`harness-allowed-directories' without the settings page: its
`config/changed' brings an open page the value now saved, so that
saving the page later does not put back what it showed before."
  (harness-emit 'config/changed symbol (default-value symbol) 'global nil))

(defun harness-perms--save-rules ()
  "Persist `harness-perms-rules' in the user's custom file, and announce it."
  (harness-save-user-option 'harness-perms-rules harness-perms-rules)
  (harness-perms--announce-option 'harness-perms-rules))

(defun harness-perms--save-dirs (dirs)
  "Make DIRS the global `harness-allowed-directories', saved and announced."
  (harness-save-user-option 'harness-allowed-directories dirs)
  (harness-perms--announce-option 'harness-allowed-directories))

(defun harness-perms-add-rule (session-id rule scope)
  "Record RULE for SESSION-ID with SCOPE (`session' or `always').
When the policy sets `harness-perms-rules', `always' records it for the
session."
  (pcase (harness-perms--scope-allowed scope 'harness-perms-rules)
    ('session
     (puthash session-id (cons rule (cl-remove rule (gethash session-id harness-perms--session-rules)
                                               :test #'equal))
              harness-perms--session-rules))
    ('always
     (setq harness-perms-rules (cons rule (cl-remove rule harness-perms-rules :test #'equal)))
     (harness-perms--save-rules)))
  rule)

(defun harness-perms--scope-rules (session-id scope)
  "Return the rules SCOPE keeps: SESSION-ID's, or with `always' the saved ones."
  (if (eq scope 'always)
      harness-perms-rules
    (gethash session-id harness-perms--session-rules)))

(defun harness-perms--add-rule-noted (session-id rule scope)
  "Record RULE for SESSION-ID with SCOPE as an answer does, and note it.
See `harness-perms-add-rule'.  The note in the session's transcript
\(`harness-perms--note-recorded') offers to undo the rule when the
answer added it: a rule equal to it that is already there (another
prompt for the same tool was answered first) is no new rule.  When the
policy sets `harness-perms-rules', `always' records it for the
session, and the note says so.  Return RULE."
  (let* ((scope (harness-perms--scope-allowed scope 'harness-perms-rules))
         (new (not (member rule (harness-perms--scope-rules session-id scope)))))
    (harness-perms-add-rule session-id rule scope)
    (harness-perms--note-recorded session-id (list :scope scope :rule rule) new)
    rule))

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
     ;; Inspecting the harness itself never needs approval, whatever
     ;; the mode: its tools, and reads of its code and state.
     ((member tool harness-perms--inspection-tools)
      (list :behavior 'allow
            :reason (format "%s only inspects the harness or the user's Emacs, which never needs approval" tool)))
     ;; So does reading skills, before the harness: the jail lets both
     ;; through, and this names the reason.
     ((harness-perms--reads-skills-p request)
      (list :behavior 'allow :reason "reading skills never needs approval"))
     ;; And reading the file the user's Emacs showed a definition in.
     ((harness-perms--reads-revealed-p request)
      (list :behavior 'allow
            :reason "the user's Emacs showed a definition in this file; reading it never needs approval"))
     ((harness-perms--reads-harness-p request)
      (list :behavior 'allow :reason "reading the harness itself never needs approval"))
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

;; The judge asks for no extended thinking (`:no-thinking'): a model
;; that thinks by default spends its output on thinking and stops at
;; max-tokens with no verdict, or half of one.  The Claude CLI provider
;; takes no output budget at all, so there turning thinking off is what
;; lets the verdict finish.  A complete verdict decides whatever the
;; stop reason; a reply without one is no verdict.  The judge gets two
;; tries when it runs out of output tokens, the second with room to
;; answer.  Only a call neither call decided is denied while the user
;; is away.

(defconst harness-perms--judge-system
  "You are the permission judge for an autonomous coding agent running inside Emacs.
You see one tool call and nothing else: not the conversation, the task, the
plan or the project's instructions, and you must not guess at them.  Decide
one thing: could this call do serious harm that is hard to undo?  Whether the
call is needed, fits the task, comes at the right time or follows the
project's workflow (reviews, handing work in, committing, merging, landing,
tests, conventions) is not your question; never deny a call for such reasons.

Allow ordinary development work: reading anything, editing and creating files,
building, running tests and scripts, local git operations, making scratch
files and directories anywhere (temporary directories included), and looking
things up on the web (documentation, references, issue trackers, package
registries) as long as the URL carries no secrets or project data.  The
allowed roots are where the agent's own work lives; reading outside them, or
creating new files outside them, is fine.

Deny only what clearly risks serious harm:
- deleting or overwriting existing data outside the allowed roots (system
  files, the user's files, other repositories), or wiping a repository or a
  home directory;
- force pushes, deleting remote branches, or other irreversible changes to
  shared remotes;
- changing system configuration, installing software system-wide, or killing
  unrelated processes (the user's Emacs, say);
- sending secrets or private data off the machine;
- widening the agent's own permissions or weakening the harness's safeguards:
  granting itself directories (harness-allowed-directories, including in
  .dir-locals.el files), changing the permission mode or the non-interactive
  setting, turning the sandbox off, or writing autoMode rules into Claude
  Code's settings (~/.claude/settings.json, its managed settings), which this
  judge follows too.  Only the user grants directories; the agent asks for
  one with the request_directory_access tool.

The harness's own tools are ordinary work: spawning and answering sub-agents,
reading, messaging and controlling other sessions of the harness, reading and
writing the task board, and reading or writing the harness's own files inside
the allowed roots.  So is inspecting the harness itself wherever it lives,
inside the allowed roots or not: reading its code, its state directory
(sessions and their transcripts, task boards, usage) and the user's live Emacs
(buffers, the harness's log among them, windows, messages, variables,
documentation), with any tool, Emacs Lisp included.  Its credentials are the
one exception: deny reading the files acp-token and server-config.el in its
state directory, which hold its secrets.

When in doubt, allow: a needless denial stops work the user wants done.  Reply
with exactly one line of JSON and nothing else:
{\"decision\":\"allow\"|\"deny\",\"reason\":\"one short sentence\"}"
  "System prompt for the auto-mode judge.
The judge is a safety check, not the agent's manager: it sees the one
call, decides only whether that call risks serious harm, and leans to
allowing, since a needless denial stops an unattended task.  It never
rules on the task, its scope or the project's workflow, and it is given
nothing to rule on them with: `harness-perms--judge-text' describes the
call alone, and the request is `:ephemeral', so the provider brings no
earlier conversation and no project instructions (CLAUDE.md and the
like) either.  Inspecting the harness is ordinary work to it, as it is
to the rules that allow it before the judge is asked (see
`harness-perms--inspection-tools' and `harness-perms-inspection-dirs'):
the judge only sees such inspection done by other means, such as Emacs
Lisp, and is told where the harness lives.  The rules of Claude Code's
auto-mode settings, which Claude Code's own auto mode follows, come
after it (`harness-perms--judge-system-prompt').")

(defun harness-perms--what-it-does (description)
  "Return what a tool does: the first sentence of its DESCRIPTION.
The rest of a description tells the agent how to use the tool (prefer
this tool to that command, call it once, when to stop), which is not
the judge's to enforce."
  (let ((text (and (stringp description) (string-trim description)))
        (case-fold-search nil))           ; else [:upper:] matches any letter
    (cond ((or (null text) (string-empty-p text)) "(no description)")
          ((string-match "[.!?]\\([ \t\n]+\\)[[:upper:]]" text) (substring text 0 (match-beginning 1)))
          (t text))))

(defun harness-perms--judge-input (input)
  "Return the input block of the judge's message for a call's INPUT.
A long input is cut so the judge call stays small, and the block says
so above the JSON: the judge used to be shown a trailing ellipsis
instead, and read it as the agent's own incomplete value (\"the
replacement string is truncated ... that would corrupt the file\")."
  (let* ((json (harness-json-encode-text (or input :empty)))
         (limit harness-perms--judge-input-chars))
    (if (<= (length json) limit)
        (format "Input (JSON):\n%s" json)
      (format (concat "Input (JSON, longer than %d characters: the harness shows"
                      " its first %d and cut the rest; the call is not missing anything):\n%s")
              (length json) limit (substring json 0 limit)))))

(defun harness-perms--judge-harness ()
  "Return the block of the judge's message that says where the harness lives.
The judge sees inspection of the harness only when it is done by other
means than the tools and reads the rules allow, such as Emacs Lisp;
told where the harness is, it can tell such a call for what it is."
  (let ((dirs (harness-perms-inspection-dirs)))
    (if (null dirs)
        ""
      (format "\nThe harness itself (inspecting it is ordinary work; reading its credentials, %s, is not):\n%s\n"
              (mapconcat #'identity (harness-perms--private-paths) " and ")
              (mapconcat (lambda (e)
                           (format "- %s (%s)" (plist-get e :dir)
                                   (if (eq (plist-get e :source) 'state)
                                       "its state: sessions and their transcripts, task boards, usage"
                                     "its code")))
                         dirs "\n")))))

(defun harness-perms--judge-text (request)
  "Return the user message describing REQUEST for the judge.
That is the call alone: the tool, what it does, its input, where the
agent works and where the harness lives (`harness-perms--judge-harness').
The input goes in as text, not bytes: the provider encodes the whole
message as JSON again, and the bytes of non-ASCII input would make
that fail."
  (let* ((tool (plist-get request :tool))
         (spec (and (harness-method-exists-p 'tools/get) (harness-call 'tools/get tool)))
         (session (plist-get request :session)))
    (format "Tool: %s\nKind: %s\nWhat it does: %s\n\n%s\n\nWorking directory: %s\nAllowed roots (where the agent's own work lives):\n%s\n%s\nIs this one call safe?  Answer with one line of JSON: {\"decision\":\"allow\"|\"deny\",\"reason\":\"...\"}"
            tool (plist-get request :kind)
            (harness-perms--what-it-does (plist-get spec :description))
            (harness-perms--judge-input (plist-get request :input))
            (or (plist-get session :cwd) default-directory)
            (mapconcat (lambda (r) (concat "- " r)) (harness-perms-roots session) "\n")
            (harness-perms--judge-harness))))

(defconst harness-perms-judge-deny-hint
  "The permission judge found this call unsafe for the reason given. Reach the goal another way that avoids that risk."
  "Hint attached to a denial by the auto-mode judge.")

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
                      :hint harness-perms-judge-deny-hint))))))

(defun harness-perms--judge-decision (verdict session)
  "Return the decision a judge VERDICT makes for SESSION.
An allow stands.  A deny stands while the user is away.  Interactive,
where the user can answer and the judge is a model that can be wrong,
it is put to the user instead: `:behavior ask' with the judge's reason
and `:judge-deny' kept, so the prompt says where the doubt comes from
and the user decides whether the call may run."
  (if (and (eq (plist-get verdict :behavior) 'deny)
           (not (harness-perms--non-interactive-p session))
           (harness-method-exists-p 'session/pending-add))
      (list :behavior 'ask :judge-deny t
            :reason (plist-get verdict :reason)
            :hint (plist-get verdict :hint))
    verdict))

(defun harness-perms--judge-prompt-reason (decision)
  "Return the prompt line for a judge denial DECISION, or nil.
It says the judge was against the call and why, so the user knows what
they are being asked about."
  (when (plist-get decision :judge-deny)
    (format "The permission judge would deny this call: %s"
            (or (plist-get decision :reason) "no reason given"))))

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
             (system (harness-perms--judge-system-prompt))
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
                                         (harness-perms--judge-decision d session)))))))
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
                                     ;; A verdict on this call alone: no earlier
                                     ;; verdicts, no project instructions.
                                     :ephemeral t
                                     :session (list :id (format "%s-perms" (plist-get session :id))
                                                    :cwd (plist-get session :cwd) :host (plist-get session :host))
                                     :system system
                                     :messages (list (list :role 'user
                                                           :content (list (list :type "text"
                                                                                :text (harness-perms--judge-text request)))))
                                     :tools nil
                                     ;; A verdict needs no extended thinking,
                                     ;; which would spend the output first.
                                     :no-thinking t
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

;;;; Auto mode: the rules Claude Code's own auto mode follows

;; Where the harness has its judge, Claude Code's auto mode has a
;; classifier, and the classifier follows an `autoMode' block in
;; Claude Code's settings: the user's own and the organization's
;; managed settings.  Its `environment' entries say where the
;; organization's boundary lies: the source control, buckets, internal
;; domains and services it trusts, so pushing to its repositories or
;; uploading to its build bucket is routine, and what it holds
;; sensitive.  `hard_deny' entries block whatever else applies;
;; `soft_deny' entries block unless an `allow' entry makes an
;; exception.  A judge that knows none of it is stricter than Claude
;; Code with the same settings.  To it, the organization's own
;; infrastructure is off the machine, so it denies, or puts to the
;; user, calls Claude Code's auto mode allows there.  So the judge
;; reads the same block from the same places
;; (`harness-perms-claude-auto-mode-rules') and is told what each list
;; means to Claude Code, on top of its own rules, which no entry lifts
;; (`harness-perms--auto-mode-block').  Claude Code's classifier reads
;; CLAUDE.md as well, the organization's managed one included.  The
;; judge reads none (its request is `:ephemeral'), because a judge given
;; free-form instructions enforced them as workflow.  The structured
;; rules are the part it can follow as Claude Code does.
;;
;; Like Claude Code it never reads a project's settings: the
;; .claude/settings.json and settings.local.json of a repository are
;; written by whoever writes the repository.  Of the managed sources it
;; applies the highest-ranked one that delivers a policy, or every one
;; when that one says "merge".  The "$defaults" marker, which splices
;; Claude Code's built-in rules into a list, is dropped, since the
;; judge's own rules stand in for those and always apply.  Policies in
;; the Windows registry are not read.

(defcustom harness-perms-claude-auto-mode t
  "Whether the auto-mode judge follows the autoMode rules of Claude Code.
Claude Code's own auto mode reads an `autoMode' block from the
user's settings (settings.json in ~/.claude, or $CLAUDE_CONFIG_DIR)
and from the organization's managed settings.  Its `environment'
says which repositories, buckets, domains and services the
organization trusts, and its `allow', `soft_deny' and `hard_deny'
lists add exceptions and denials.  Non-nil gives the judge the same
rules (`harness-perms-claude-auto-mode-rules').  A session in auto
mode is then no stricter than Claude Code with the same settings,
and it follows the organization's denials as Claude Code does.  The
judge's own rules still apply: no entry lifts them.  nil leaves the
judge with its own rules only."
  :type 'boolean
  :group 'harness)

(defconst harness-perms--auto-mode-lists '(:environment :hard_deny :soft_deny :allow)
  "The rule lists of an autoMode block in Claude Code's settings.
In the order the judge's prompt gives them.")

(defconst harness-perms--claude-control-keys '(:managedSourcesBehavior :wslInheritsWindowsSettings)
  "Keys of Claude Code's managed settings that say how to read the sources.
They are no policy: a source that holds nothing else delivers none.")

(defun harness-perms--claude-config-dir ()
  "Return Claude Code's configuration directory, as a directory name.
That is $CLAUDE_CONFIG_DIR when it is set, else ~/.claude, as Claude
Code decides.  It holds the user's settings.json and the server-managed
settings Claude Code caches, remote-settings.json."
  (let ((env (getenv "CLAUDE_CONFIG_DIR")))
    (file-name-as-directory (expand-file-name (if (harness-string-blank-p env) "~/.claude" env)))))

(defun harness-perms--claude-system-dir ()
  "Return the directory of Claude Code's managed settings files on this system."
  (pcase system-type
    ('darwin "/Library/Application Support/ClaudeCode/")
    ('windows-nt "C:/Program Files/ClaudeCode/")
    (_ "/etc/claude-code/")))

(defun harness-perms--claude-object (value)
  "Return VALUE when it is a parsed JSON object, else nil."
  (and (consp value) (keywordp (car value)) value))

(defun harness-perms--claude-read-settings (file)
  "Return the settings object in FILE, a JSON file of Claude Code's settings.
nil when FILE is missing or unreadable or holds no JSON object."
  (when (and (file-regular-p file) (file-readable-p file))
    (condition-case err
        (harness-perms--claude-object (harness-json-parse (harness-read-file file)))
      (error (harness-log 'warn "perms: ignoring the Claude Code settings in %s: %s"
                          file (harness-error-message err))
             nil))))

(defun harness-perms--claude-profile-settings ()
  "Return the settings of Claude Code's macOS configuration profile, or nil.
That is the managed preferences domain com.anthropic.claudecode, the
user's own profile before the computer's, converted to JSON by plutil."
  (when (eq system-type 'darwin)
    (cl-some
     (lambda (file)
       (when (file-readable-p file)
         (with-temp-buffer
           (let ((default-directory "/")
                 (coding-system-for-read 'utf-8))
             (when (eql 0 (ignore-errors
                            (call-process "plutil" nil '(t nil) nil "-convert" "json" "-o" "-" file)))
               (harness-perms--claude-object (ignore-errors (harness-json-parse (buffer-string)))))))))
     (list (format "/Library/Managed Preferences/%s/com.anthropic.claudecode.plist" (user-login-name))
           "/Library/Managed Preferences/com.anthropic.claudecode.plist"))))

(defun harness-perms--claude-managed-files ()
  "Return Claude Code's managed settings files, in the order it merges them.
managed-settings.json in its system directory first, then the .json
files of managed-settings.d there in alphabetical order, hidden ones
left out (`harness-perms--claude-system-dir')."
  (let* ((dir (harness-perms--claude-system-dir))
         (drop-ins (expand-file-name "managed-settings.d" dir)))
    (cons (expand-file-name "managed-settings.json" dir)
          (and (file-directory-p drop-ins)
               (directory-files drop-ins t "\\`[^.].*\\.json\\'")))))

(defun harness-perms--claude-managed-sources ()
  "Return Claude Code's managed settings sources, highest-ranked first.
Each is the list of settings objects one source delivers: the
server-managed settings Claude Code caches (remote-settings.json in
`harness-perms--claude-config-dir'), the macOS configuration profile
\(`harness-perms--claude-profile-settings'), and the managed settings
files (`harness-perms--claude-managed-files')."
  (list (delq nil (list (harness-perms--claude-read-settings
                         (expand-file-name "remote-settings.json" (harness-perms--claude-config-dir)))))
        (delq nil (list (harness-perms--claude-profile-settings)))
        (delq nil (mapcar #'harness-perms--claude-read-settings (harness-perms--claude-managed-files)))))

(defun harness-perms--claude-policy-p (settings)
  "Non-nil when the Claude Code SETTINGS object holds a policy key.
That is any key set to something other than null, except the control
keys (`harness-perms--claude-control-keys') and metadata such as
$schema."
  (cl-loop for (key value) on settings by #'cddr
           thereis (and value
                        (not (memq key harness-perms--claude-control-keys))
                        (not (string-prefix-p ":$" (symbol-name key))))))

(defun harness-perms--claude-managed-settings ()
  "Return the managed settings objects Claude Code applies, highest-ranked first.
By default (\"first-wins\") those of the highest-ranked source that
holds a policy key.  When the highest-ranked source holding a policy
key or managedSourcesBehavior sets that to \"merge\", those of every
source that holds a policy key."
  (let* ((sources (harness-perms--claude-managed-sources))
         (policy-p (lambda (source) (cl-some #'harness-perms--claude-policy-p source)))
         (behavior-of (lambda (source)
                        (car (last (delq nil (mapcar (lambda (s) (plist-get s :managedSourcesBehavior))
                                                     source))))))
         (top (cl-find-if (lambda (source) (or (funcall policy-p source) (funcall behavior-of source)))
                          sources))
         (applied (cl-remove-if-not policy-p sources)))
    (apply #'append (if (equal (funcall behavior-of top) "merge")
                        applied
                      (and applied (list (car applied)))))))

(defun harness-perms--auto-mode-entries (settings key)
  "Return the entries of autoMode list KEY in the Claude Code SETTINGS object.
Only strings count, and neither blank ones nor the \"$defaults\"
marker, which stands for Claude Code's built-in rules."
  (let ((entries (plist-get (harness-perms--claude-object (plist-get settings :autoMode)) key)))
    (and (listp entries)
         (not (keywordp (car entries)))
         (cl-remove-if-not (lambda (e) (and (stringp e)
                                            (not (harness-string-blank-p e))
                                            (not (equal (string-trim e) "$defaults"))))
                           entries))))

(defun harness-perms-claude-auto-mode-rules ()
  "Return the autoMode rules Claude Code's auto mode follows on this machine.
A plist from the keys of `harness-perms--auto-mode-lists' to their
entries, prose rules, without the lists that are empty.  Each holds
the entries of the managed settings Claude Code applies
\(`harness-perms--claude-managed-settings'), then the user's own
\(settings.json in `harness-perms--claude-config-dir'), duplicates and
the \"$defaults\" marker left out, as Claude Code combines them.  No
project's settings are read.  nil when `harness-perms-claude-auto-mode'
is nil."
  (when harness-perms-claude-auto-mode
    (let ((all (append (harness-perms--claude-managed-settings)
                       (delq nil (list (harness-perms--claude-read-settings
                                        (expand-file-name "settings.json" (harness-perms--claude-config-dir))))))))
      (cl-loop for key in harness-perms--auto-mode-lists
               for entries = (delete-dups (cl-loop for s in all
                                                   append (copy-sequence (harness-perms--auto-mode-entries s key))))
               when entries append (list key entries)))))

(defconst harness-perms--auto-mode-headings
  '((:environment . "Environment: what counts as the organization's own infrastructure, and what
is sensitive.  Code and data going to infrastructure named here as trusted
(repositories, source control, buckets, domains, services, registries) stay
inside the organization: that is ordinary work, not sending private data off
the machine.  Secrets still go nowhere but the service they belong to, and
what is named here as sensitive stays protected.  A destination these entries
do not name is judged by the rules above alone.")
    (:hard_deny . "Hard deny: deny every call one of these describes, whatever else applies.")
    (:soft_deny . "Soft deny: deny every call one of these describes, unless an allow entry
covers it.")
    (:allow . "Allow: exceptions to the soft deny entries, and to nothing else."))
  "What each autoMode list means to the judge, as it does to Claude Code.")

(defun harness-perms--auto-mode-block (rules)
  "Return the part of the judge's system prompt that gives it RULES, or nil.
RULES are the autoMode rules of Claude Code's settings
\(`harness-perms-claude-auto-mode-rules'), and nil when there are none.
Each list comes under what it means in Claude Code's auto mode
\(`harness-perms--auto-mode-headings'): the environment says where the
organization's boundary lies, hard deny entries deny, soft deny
entries deny unless an allow entry covers the call, and allow entries
make only those exceptions.  The judge's own rules stand over them
all: no entry lifts one."
  (when rules
    (concat
     "Rules from Claude Code's settings.  Claude Code's own auto mode follows these
entries, which the organization's managed settings and the user's own settings
give it; follow them as it does.  They add to the rules above and lift none
of them."
     (mapconcat (lambda (key)
                  (let ((entries (plist-get rules key)))
                    (if (null entries) ""
                      (concat "\n\n" (alist-get key harness-perms--auto-mode-headings) "\n"
                              (mapconcat (lambda (e) (concat "- " (replace-regexp-in-string
                                                                   "\n" "\n  " (string-trim e))))
                                         entries "\n")))))
                harness-perms--auto-mode-lists ""))))

(defun harness-perms--judge-system-prompt ()
  "Return the auto-mode judge's system prompt.
That is `harness-perms--judge-system', then the rules of Claude Code's
auto-mode settings when there are any (`harness-perms--auto-mode-block'),
so the judge follows what Claude Code's own auto mode follows.  Settings
that cannot be read leave the prompt as it is: they never keep the judge
from judging."
  (let ((block (condition-case err
                   (harness-perms--auto-mode-block (harness-perms-claude-auto-mode-rules))
                 (error (harness-log 'warn "perms: cannot read Claude Code's auto-mode rules: %s"
                                     (harness-error-message err))
                        nil))))
    (if block
        (concat harness-perms--judge-system "\n\n" block)
      harness-perms--judge-system)))

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
instead of waiting for the user.  A refused request to turn
non-interactive mode on is the exception: only the user turns it on,
so there is no other way to look for, and its hint already tells the
agent to carry on as it is."
  (when (and (not (eq (plist-get decision :behavior) 'allow))
             (not (equal (plist-get request :tool) harness-perms-away-tool))
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
denied because nobody can answer.  The prompt is about the call
itself, not about where it reaches: the jail already let its paths
through, asking first about any outside the allowed directories.  So
it offers no pattern, and its answers for the session or for always
hold for the tool (see `harness-perms--answer-tool').  A shell
command's prompt still shows what the command reaches: the paths it
names outside the session's directories, or where it runs when it
names none there (`harness-perms--subject-paths'), and, as `:cwd',
where it runs."
  (let* ((session (plist-get request :session))
         (sid (plist-get session :id)))
    (cond
     ((not (eq (plist-get decision :behavior) 'ask)) (funcall next decision))
     ((not (harness-method-exists-p 'session/pending-add))
      (funcall next (list :behavior 'deny :reason "no user available")))
     (t
      ;; A shell command is about the paths it names outside the
      ;; session's directories, else where it runs (see
      ;; `harness-perms--subject-paths'), and the prompt says where that
      ;; is.
      (let* ((request (harness-perms--with-reach request))
             (paths (harness-perms--subject-paths request))
             (cwd (and (harness-perms--command request) (harness-perms--command-dir request)))
             (pending (list :kind 'permission
                            :payload (append (list :tool (plist-get request :tool)
                                                   :input (plist-get request :input)
                                                   :kind (plist-get request :kind)
                                                   :paths paths
                                                   :call-id (plist-get request :call-id))
                                             (and cwd (list :cwd cwd))
                                             (list :title (harness-perms-describe-request request)
                                                   :reason (harness-perms--judge-prompt-reason decision)
                                                   :options (harness-perms--tool-options)))))
             (pid (harness-call 'session/pending-add sid pending)))
        (puthash pid (list :session-id sid :request request :next next :paths paths :cwd cwd)
                 harness-perms--waiting)
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
a path outside the allowed directories (one with `:dir') is answered
for a glob pattern: the payload's `:pattern' unless ANSWER's names
another, absolute or relative to the session's cwd.  Any other prompt
is answered for its tool, and a confirmation (`harness-perms-confirm')
for this call alone.
Resolves the pending request, records session or standing rules (for
a directory prompt: grants the pattern to the session or, with
`always', to every session, or denies it) and lets the tool call
continue.  This is the only way a directory prompt is granted, and the
only way an agent's request to turn non-interactive mode on is allowed;
that one records no rule (see `harness-perms--away-request').  Return
the final decision, or `continue' when a jail prompt hands the call on."
  (let ((waiting (gethash pending-id harness-perms--waiting)))
    (unless waiting
      (signal 'harness-error (list (format "no pending permission %s" pending-id))))
    (remhash pending-id harness-perms--waiting)
    (cond
     ((plist-get waiting :dir)
      (let ((answer (harness-perms--parse-answer answer)))
        (harness-perms--resolve session-id pending-id answer)
        (harness-perms--answer-dir session-id waiting answer)))
     ((plist-get waiting :user-only)
      (harness-perms--answer-user-only session-id pending-id waiting answer))
     ((plist-get waiting :confirm)
      (harness-perms--answer-confirm session-id pending-id waiting answer))
     (t (harness-perms--answer-tool session-id pending-id waiting answer)))))

(defun harness-perms--resolve (session-id pending-id answer)
  "Mark PENDING-ID of SESSION-ID resolved with ANSWER."
  (when (harness-method-exists-p 'session/pending-resolve)
    (condition-case err
        (harness-call 'session/pending-resolve session-id pending-id answer)
      (error (harness-log 'warn "perms: pending-resolve failed: %S" err)))))

(defun harness-perms--answer-tool (session-id pending-id waiting answer)
  "Answer the tool permission WAITING (PENDING-ID of SESSION-ID) with ANSWER.
Record session or standing rules, noted in the session's transcript
where they can be undone (`harness-perms--note-recorded'), and let the
tool call continue.  The prompt offered no pattern (see
`harness-perms--ask'), so a rule holds for every call of the tool, a
`:pattern' in ANSWER notwithstanding; the jail still decides where
each call may reach."
  (let* ((answer (harness-perms--parse-answer answer))
         (request (plist-get waiting :request))
         (behavior (plist-get answer :behavior))
         (scope (plist-get answer :scope))
         (decision (list :behavior behavior :final t
                         :reason (or (plist-get answer :reason)
                                     (if (eq behavior 'allow) "allowed by the user"
                                       "denied by the user")))))
    (when (memq scope '(session always))
      (harness-perms--add-rule-noted session-id (list :tool (plist-get request :tool) :behavior behavior) scope))
    (harness-perms--resolve session-id pending-id answer)
    (funcall (plist-get waiting :next) decision)
    decision))

;;;; Notes of lasting answers, and their undo
;;
;; An answer for the session or always records a rule, or grants a
;; directory, beyond the call it answers.  Right after, a note in the
;; session's transcript says what it recorded: a hint (the model never
;; gets it), written before the call goes on, so the chat shows it
;; under the call, whichever view the answer came from.  Its `:meta'
;; `:permission' holds the record (see `harness-node-permission'), and
;; `permission/undo' removes what it names, but only that, and only
;; while it is still as the answer left it.  The call's own decision
;; stands either way.  Rules have no identity of their own, so what a
;; note names is told apart by what it says (`harness-perms--rule-key').

(defun harness-perms--recorded-what (record)
  "Return what lasting answer RECORD holds for, as its note words it."
  (let ((dir (plist-get record :dir))
        (rule (plist-get record :rule)))
    (if (stringp dir)
        (abbreviate-file-name dir)
      (let* ((tool (plist-get rule :tool))
             (path (plist-get rule :path))
             (path (and (stringp path) (not (harness-string-blank-p path)) (abbreviate-file-name path))))
        (cond ((and tool path) (format "%s calls in %s" tool path))
              (tool (format "every %s call" tool))
              (path (format "%s to every tool" path))
              (t "every call"))))))

(defun harness-perms--recorded-text (record)
  "Return the note that says what lasting answer RECORD does.
RECORD is as `harness-node-permission' describes.  The note reads
\"Always allowing every bash call, in every session\", say, or
\"Allowing ~/src/other/ for this session\"."
  (let ((verb (if (and (not (stringp (plist-get record :dir)))
                       (eq (harness-perms--sym (plist-get (plist-get record :rule) :behavior)) 'deny))
                  "denying"
                "allowing"))
        (what (harness-perms--recorded-what record)))
    (if (eq (harness-perms--sym (plist-get record :scope)) 'always)
        (format "Always %s %s, in every session" verb what)
      (format "%s %s for this session" (capitalize verb) what))))

(defun harness-perms--note-recorded (session-id record new)
  "Write into SESSION-ID's transcript what a lasting answer recorded.
RECORD is (:scope SCOPE :rule RULE) or (:scope SCOPE :dir DIR), which
the note keeps in its `:meta' `:permission' (see
`harness-node-permission').  NEW non-nil means the answer added it, so
the note offers to undo it (`permission/undo'); otherwise it was there
already and the note only says so.  Without the session module there
is no transcript, and nothing is written; a note that cannot be written
is logged, and the answer goes on.  Return the note, or nil."
  (when (harness-method-exists-p 'session/append)
    (condition-case err
        (harness-call 'session/append session-id
                      (list :kind 'hint
                            :content (concat (harness-perms--recorded-text record)
                                             (if new "" " (already so: nothing new to undo)"))
                            :meta (list :permission (if new (append record (list :undo 'offered)) record))))
      (error (harness-log 'warn "perms: could not note the answer in %s: %s"
                          session-id (harness-error-message err))
             nil))))

(defun harness-perms--allow-dir-noted (session-id grant scope)
  "Grant GRANT to SESSION-ID with SCOPE as an answer does, and note it.
SCOPE is `session' or `always' (see `permission/allow-dir').  The note
in the session's transcript (`harness-perms--note-recorded') offers to
undo the grant when it is new: a directory already granted the same
way, by another prompt answered first, is no new grant.  When the
policy sets `harness-allowed-directories', `always' grants to the
session, and the note says so."
  (let* ((scope (harness-perms--scope-allowed scope 'harness-allowed-directories))
         (session (harness-perms--session session-id))
         (dir (harness-perms--expand-dir session grant))
         (always (eq scope 'always))
         (new (not (member dir (if always (harness-perms--global-dirs session) (harness-perms--granted session))))))
    (if always
        (harness-call 'permission/allow-dir session-id grant 'always)
      (harness-call 'permission/allow-dir session-id grant))
    (harness-perms--note-recorded session-id (list :scope scope :dir dir) new)))

(defun harness-perms--rule-key (rule)
  "Return what RULE says, in a form rules are compared by.
Two rules are the same when they decide the same: the order of their
keys, symbols that came back as strings and blank values make no
difference."
  (let ((text (lambda (v) (and (stringp v) (not (harness-string-blank-p v)) (string-trim v)))))
    (list (funcall text (plist-get rule :tool))
          (harness-perms--sym (plist-get rule :kind))
          (funcall text (plist-get rule :path))
          (harness-perms--sym (plist-get rule :behavior)))))

(defun harness-perms--rule-from-record (rule)
  "Return RULE as a note recorded it, its symbols symbols again.
A note read back from the node log, or sent over the wire, has
strings instead."
  (let (out)
    (cl-loop for (k v) on rule by #'cddr
             do (setq out (plist-put out k (if (memq k '(:kind :behavior)) (harness-perms--sym v) v))))
    out))

(defun harness-perms--undo-rule (session-id rule scope)
  "Remove RULE, recorded for SESSION-ID with SCOPE, if it still says the same.
The rule `equal' to RULE goes, else the first that says the same (see
`harness-perms--rule-key'): from the session's rules or, with SCOPE
`always', from the saved ones, which are saved again.  A rule for the
same tool and path that says something else now stays as it is.
Return (OUTCOME . MESSAGE): OUTCOME is `undone', `changed' or `gone',
and MESSAGE says why when it is not `undone'."
  (let* ((always (eq scope 'always))
         (rules (harness-perms--scope-rules session-id scope))
         (key (harness-perms--rule-key rule))
         (subject (lambda (k) (list (nth 0 k) (nth 2 k))))
         (pos (or (cl-position rule rules :test #'equal)
                  (cl-position key rules :key #'harness-perms--rule-key :test #'equal))))
    (cond
     (pos
      (let ((rest (append (cl-subseq rules 0 pos) (nthcdr (1+ pos) rules))))
        (cond (always (setq harness-perms-rules rest)
                      (harness-perms--save-rules))
              (rest (puthash session-id rest harness-perms--session-rules))
              (t (remhash session-id harness-perms--session-rules))))
      (list 'undone))
     ((cl-find (funcall subject key) rules :test #'equal
               :key (lambda (r) (funcall subject (harness-perms--rule-key r))))
      (cons 'changed (format "Not undone: %s for %s has changed since%s, so it stays as it is"
                             (if always "the saved rule" "this session's rule")
                             (harness-perms--rule-subject rule)
                             (if always " (in Settings, say)" ""))))
     (always
      (cons 'gone (format "Nothing to undo: the saved rules no longer have one for %s"
                          (harness-perms--rule-subject rule))))
     (t
      (cons 'gone "Nothing to undo: this session has no such rule now (session rules end when the harness restarts, and a fork starts without them)")))))

(defun harness-perms--undo-dir (session-id dir scope)
  "Withdraw DIR, granted to SESSION-ID with SCOPE, if it is still granted.
DIR is as the grant keeps it.  The entry naming DIR goes: from the
session's grants or, with SCOPE `always', from
`harness-allowed-directories', which is saved again.  When no entry
names it any more but one still covers it (changed since, on the
settings page say), every entry stays as it is.  Return (OUTCOME
. MESSAGE) as `harness-perms--undo-rule' does."
  (let* ((session (harness-perms--session session-id))
         (always (eq scope 'always))
         (entries (if always (default-value 'harness-allowed-directories) (harness-perms--granted session)))
         (expanded (mapcar (lambda (d) (harness-perms--expand-dir session d)) entries))
         (pos (or (cl-position dir entries :test #'equal)
                  (cl-position dir expanded :test #'equal)))
         (cover (and (not pos) (cl-find-if (lambda (d) (harness-perms--within-p d dir)) expanded))))
    (cond
     (pos
      (let ((rest (append (cl-subseq entries 0 pos) (nthcdr (1+ pos) entries))))
        (if always
            (harness-perms--save-dirs rest)
          (harness-perms--set-granted session-id rest)))
      (harness-emit 'permission/dir-revoked session-id dir)
      (list 'undone))
     (cover
      (cons 'changed (format "Not undone: %s changed since%s, and %s still covers %s, so they stay as they are"
                             (if always "the allowed directories" "this session's directories")
                             (if always " (in Settings, say)" "")
                             (abbreviate-file-name cover) (abbreviate-file-name dir))))
     (t
      (cons 'gone (format "Nothing to undo: %s is no longer %s" (abbreviate-file-name dir)
                          (if always "among the allowed directories" "granted to this session")))))))

(harness-defmethod permission/undo (session-id node-id)
  "Undo the lasting answer that note NODE-ID of SESSION-ID tells of.
The note is the hint written after an answer for the session or always
\(`harness-perms--note-recorded'); its `:meta' `:permission' names the
rule the answer recorded or the directory it granted (see
`harness-node-permission').  Only that goes, from the session or from
the saved settings, and only while it is still as the answer left it:
a rule for the same tool or path that says something else now (edited
on the settings page, say), or a directory another entry still covers,
stays as it is.  The decision the answer made for its call stands
either way.  The note then records the outcome, which the chat shows,
and its undo is offered no more: asking again changes nothing and
returns the same.  Return (:outcome OUTCOME :message TEXT); OUTCOME is
`undone', `changed', `gone', or `none' for a note whose answer
recorded nothing new, and TEXT says what happened."
  (let* ((node (and (harness-method-exists-p 'session/node)
                    (harness-call 'session/node session-id node-id)))
         (record (harness-node-permission node))
         (state (harness-permission-undo-state record)))
    (cond
     ((null record)
      (signal 'harness-error (list (format "%s is no note of a permission answer" node-id))))
     ((not (eq state 'offered))
      (list :outcome (or state 'none)
            :message (or (plist-get record :result) "Nothing to undo: that answer recorded nothing new")))
     (t
      (let* ((scope (if (eq (harness-perms--sym (plist-get record :scope)) 'always) 'always 'session))
             (dir (plist-get record :dir))
             (result (if (stringp dir)
                         (harness-perms--undo-dir session-id dir scope)
                       (harness-perms--undo-rule session-id
                                                 (harness-perms--rule-from-record (plist-get record :rule))
                                                 scope)))
             (outcome (car result))
             (message (if (eq outcome 'undone)
                          (let ((text (harness-perms--recorded-text record)))
                            (concat "Undone: no longer " (downcase (substring text 0 1)) (substring text 1)))
                        (cdr result))))
        (harness-call 'session/update-node session-id node-id
                      :meta (plist-put (copy-sequence (plist-get node :meta)) :permission
                                       (append (harness-plist-remove record :undo :result)
                                               (list :undo outcome :result message))))
        (list :outcome outcome :message message))))))

;;;; Confirmations
;;
;; Some calls change what only the user may change, whatever the
;; permission mode, the standing rules and the judge would say: moving a
;; session to another directory changes the directories it may reach.
;; The tool's own `permission/decide' stage, ahead of the jail, has the
;; user confirm each such call with `harness-perms-confirm'.  The prompt
;; offers allow-once and deny-once only, records no rule, and its answer
;; is final; yolo does not answer it, and a session nobody can answer
;; for is denied at once.

(defconst harness-perms-confirm-options '(allow-once deny-once)
  "Answer options of a confirmation (see `harness-perms-confirm').")

(defun harness-perms-confirm (request next &rest prompt)
  "Have the user confirm REQUEST, a tool call, then go on with NEXT.
For the `permission/decide' stage of a tool whose every call needs the
user's yes.  PROMPT is a plist: `:title', the prompt's headline;
`:reason', what the call would do; `:paths', the paths it is about
\(REQUEST's by default); `:input', what the tool's handler gets once
the user allows the call (REQUEST's input by default); `:hint', what the
agent is told after a denial.  The prompt shows REQUEST's input.  The
decision handed to NEXT is final: the user's answer, or a denial at once
when REQUEST's session is non-interactive or there is no user to ask."
  (let* ((session (plist-get request :session))
         (sid (plist-get session :id))
         (hint (or (plist-get prompt :hint) "Do not ask again unless the user wants it.")))
    (if (or (harness-perms--non-interactive-p session)
            (not (harness-method-exists-p 'session/pending-add)))
        (funcall next (list :behavior 'deny :final t
                            :reason (format "%s needs the user's confirmation, and %s"
                                            (harness-tools-label (plist-get request :tool))
                                            (if (harness-perms--non-interactive-p session)
                                                "the session is non-interactive: the user is away"
                                              "no user is available"))
                            :hint "Do not retry; say in your answer what you wanted to do, so the user can do it."))
      (let* ((title (plist-get prompt :title))
             (pending (list :kind 'permission
                            :payload (list :tool (plist-get request :tool)
                                           :input (plist-get request :input)
                                           :kind (plist-get request :kind)
                                           :paths (if (plist-member prompt :paths) (plist-get prompt :paths)
                                                    (plist-get request :paths))
                                           :call-id (plist-get request :call-id)
                                           :title title
                                           :reason (plist-get prompt :reason)
                                           :options harness-perms-confirm-options
                                           :confirm t)))
             (pid (harness-call 'session/pending-add sid pending)))
        (puthash pid (list :session-id sid :request request :next next :confirm t
                           :input (plist-get prompt :input) :hint hint :title title
                           :options harness-perms-confirm-options)
                 harness-perms--waiting)
        (harness-emit 'permission/requested sid (plist-put (copy-sequence pending) :id pid))))))

(defun harness-perms--answer-confirm (session-id pending-id waiting answer)
  "Answer the confirmation WAITING (PENDING-ID of SESSION-ID) with ANSWER.
Allow lets the call go on, with the input the confirmation was made for;
anything else denies it.  Either way only this call: no rule is
recorded, whatever scope ANSWER names."
  (let* ((answer (harness-perms--parse-answer answer))
         (decision (if (eq (plist-get answer :behavior) 'allow)
                       (append (list :behavior 'allow :final t
                                     :reason (or (plist-get answer :reason) "confirmed by the user"))
                               (and (plist-get waiting :input) (list :input (plist-get waiting :input))))
                     (list :behavior 'deny :final t
                           :reason (or (plist-get answer :reason) "the user said no")
                           :hint (plist-get waiting :hint)))))
    (harness-perms--resolve session-id pending-id answer)
    (funcall (plist-get waiting :next) decision)
    decision))

;;;; Switching to yolo or non-interactive with a prompt waiting

(defun harness-perms--user-only-p (waiting)
  "Non-nil when only the user may answer the waiting prompt WAITING.
That is a prompt about a directory (the jail's, or an agent's own
request), a confirmation (`harness-perms-confirm') and an agent's
request to turn non-interactive mode on.  Neither a switch to yolo nor
one to non-interactive answers them."
  (or (plist-get waiting :dir) (plist-get waiting :confirm) (plist-get waiting :user-only)))

(defun harness-perms--accept-yolo (session-id)
  "Answer SESSION-ID's waiting prompts that yolo would have allowed.
A pending tool prompt was asked because the mode in effect left the
call undecided; once the session is in yolo the call would be allowed
without asking, so the prompt is answered allow-once and the call runs.
Only what the mode stage now allows is answered, so a standing deny
rule still decides, and a directory prompt keeps waiting: not even yolo
grants a directory without the user's answer.  Nor does it confirm what
only the user confirms (`harness-perms-confirm'), or answer an agent's
request to turn non-interactive mode on."
  (let ((session (harness-perms--session session-id)) pids)
    (when (eq (harness-perms--mode-of session) 'yolo)
      (maphash
       (lambda (pid waiting)
         (when (equal (plist-get waiting :session-id) session-id)
           (let* ((request (plist-get waiting :request))
                  ;; The request holds the session as it was when the
                  ;; prompt was made; the mode stage must see the new one.
                  (fresh (plist-put (copy-sequence request) :session session)))
             (when (and (not (harness-perms--user-only-p waiting))
                        (eq 'allow (plist-get (harness-perms--mode-decision nil fresh) :behavior)))
               (push pid pids)))))
       harness-perms--waiting)
      (dolist (pid (nreverse pids))
        (condition-case err
            (harness-call 'permission/answer
                          session-id pid (list :behavior 'allow :scope 'once
                                               :reason "the session switched to yolo mode"))
          (error (harness-log 'warn "perms: could not accept %s for yolo mode: %s"
                              pid (harness-error-message err))))))))

(defconst harness-perms--redecided-stages '(11 . 89)
  "Priorities of the stages a waiting prompt goes through again.
They are the `permission/decide' stages after the jail (10) and before
the prompt (90): the mode and its standing rules, the stages other
modules add there, the auto-mode judge and the denial of what it gave
no verdict on.  The earlier ones decided where the call may reach,
which the switch to non-interactive does not change; see
`harness-perms--judge-waiting'.")

(defun harness-perms--decide-waiting (session-id pid waiting)
  "Decide the waiting prompt WAITING, PID of SESSION-ID, as a new call.
The prompt's request goes through `harness-perms--redecided-stages'
with the session as it is now.  A verdict resolves the prompt and
hands the call on, so it runs or is refused as the verdict says, and
`permission/decided' steers the agent after a denial as after any.  A
prompt answered meanwhile, or still undecided (the session turned
interactive again while the judge thought), keeps waiting."
  (let ((request (plist-put (copy-sequence (plist-get waiting :request))
                            :session (harness-perms--session session-id)))
        (done (lambda () (remhash pid harness-perms--judging))))
    (puthash pid t harness-perms--judging)
    (harness-then
     (harness-run-filter-async-between 'permission/decide
                                       (car harness-perms--redecided-stages)
                                       (cdr harness-perms--redecided-stages)
                                       (list :behavior 'ask) request)
     (lambda (decision)
       (funcall done)
       (let ((behavior (plist-get decision :behavior)))
         (when (and (memq behavior '(allow deny))
                    (eq (gethash pid harness-perms--waiting) waiting))
           (remhash pid harness-perms--waiting)
           (harness-perms--resolve session-id pid
                                   (list :behavior behavior :scope 'once
                                         :reason (plist-get decision :reason)))
           (funcall (plist-get waiting :next) (plist-put (copy-sequence decision) :final t)))))
     (lambda (err)
       (funcall done)
       (harness-log 'warn "perms: deciding prompt %s again failed: %s" pid (harness-error-message err))))))

(defun harness-perms--judge-waiting (session-id)
  "Have SESSION-ID's waiting prompts decided now that its user is away.
A prompt waits for the user because the session's mode left its call
undecided, or because the judge objected while the user could still
overrule it.  Once the session is non-interactive nobody answers it, so
each is decided as a new call of the session would be (see
`harness-perms--decide-waiting'): the judge decides in the user's
place.  The prompts only the user answers keep waiting
\(`harness-perms--user-only-p'): no switch grants a directory, confirms
what only the user confirms or turns non-interactive mode on."
  (let ((session (harness-perms--session session-id))
        (todo nil))
    (when (harness-perms--non-interactive-p session)
      (maphash (lambda (pid waiting)
                 (when (and (equal (plist-get waiting :session-id) session-id)
                            (not (harness-perms--user-only-p waiting))
                            (not (gethash pid harness-perms--judging)))
                   (push (cons pid waiting) todo)))
               harness-perms--waiting)
      (dolist (entry (nreverse todo))
        (condition-case err
            (harness-perms--decide-waiting session-id (car entry) (cdr entry))
          (error (remhash (car entry) harness-perms--judging)
                 (harness-log 'warn "perms: could not decide prompt %s again: %s"
                              (car entry) (harness-error-message err))))))))

(defun harness-perms--on-session-updated (session-id changes)
  "Settle SESSION-ID's waiting prompts when it switches to yolo or non-interactive.
CHANGES are the session's changed fields.  In yolo, what the mode now
allows is answered (see `harness-perms--accept-yolo'); in
non-interactive mode the judge decides the prompts (see
`harness-perms--judge-waiting').  Either runs from the command loop,
after the switch returns."
  (when (eq (harness-perms--sym (plist-get changes :permission-mode)) 'yolo)
    (harness-run-soon #'harness-perms--accept-yolo session-id))
  (when (harness-json-true-p (plist-get changes :non-interactive))
    (harness-run-soon #'harness-perms--judge-waiting session-id)))

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
`harness-allowed-directories', which is refused when the policy sets
it; with `turn' it is granted until the session's turn ends (see
`harness-perms--turn-dirs'); otherwise the grant is kept with the
session.  Return the session's effective roots."
  (let* ((session (harness-perms--session session-id))
         (dir (harness-perms--expand-dir session dir)))
    (pcase (harness-perms--sym scope)
      ('always
       (harness-policy-refuse 'harness-allowed-directories)
       (unless (member dir (harness-perms--global-dirs session))
         (harness-perms--save-dirs (append (default-value 'harness-allowed-directories) (list dir))))
       (harness-emit 'permission/dir-allowed session-id dir))
      ('turn (harness-perms--grant-for-turn session-id dir))
      (_ (let ((granted (harness-perms--granted session)))
           (unless (member dir granted)
             (harness-perms--set-granted session-id (append granted (list dir)))))
         (harness-emit 'permission/dir-allowed session-id dir)))
    (harness-perms-roots (harness-perms--session session-id))))

(harness-defmethod permission/revoke-dir (session-id dir)
  "Withdraw DIR from SESSION-ID.
Removes a session grant, or one until the session's turn ends, or else
the entry in the global `harness-allowed-directories'.  The cwd, the
worktree, the session's own temporary directory, directories set in a
project's .dir-locals.el and those the policy sets cannot be revoked
here.  Return the session's effective roots."
  (let* ((session (harness-perms--session session-id))
         (dir (harness-perms--expand-dir session dir))
         (granted (harness-perms--granted session))
         (turn (gethash session-id harness-perms--turn-dirs))
         (global (default-value 'harness-allowed-directories)))
    (cond
     ((member dir granted)
      (harness-perms--set-granted session-id (remove dir granted)))
     ((member dir turn)
      (if (cdr turn)
          (puthash session-id (remove dir turn) harness-perms--turn-dirs)
        (remhash session-id harness-perms--turn-dirs)))
     ((member dir (harness-perms--global-dirs session))
      (harness-policy-refuse 'harness-allowed-directories)
      (harness-perms--save-dirs
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
is a grant, for the session or until its turn ends, or comes from the
global `harness-allowed-directories', unless the policy sets that."
  (let* ((session (harness-perms--session session-id))
         (global (unless (harness-policy-pinned-p 'harness-allowed-directories)
                   (harness-perms--global-dirs session))))
    (mapcar (lambda (e)
              (append e (list :revocable
                              (and (or (memq (plist-get e :source) '(session turn))
                                       (and (eq (plist-get e :source) 'config)
                                            (member (plist-get e :dir) global)))
                                   t))))
            (harness-perms-dirs session))))

(harness-defmethod permission/rules (session-id)
  "Return the effective permission rules of SESSION-ID for display.
The result is (:mode MODE :non-interactive BOOL :auto-allow TOOLS
:session RULES :always RULES :roots DIRS :inspect DIRS :skills DIRS).
TOOLS are the tools that never need approval, those that inspect the
harness included; `:inspect' lists the directories of the harness
itself and `:skills' the skills directories, which every call that
only reads may read (see `harness-perms-inspection-dirs' and
`harness-perms-skill-dirs')."
  (let ((session (harness-perms--session session-id)))
    (list :mode (harness-perms--mode-of session)
          :non-interactive (and (harness-perms--non-interactive-p session) t)
          :auto-allow (append harness-perms--auto-allow-tools harness-perms--inspection-tools)
          :session (gethash session-id harness-perms--session-rules)
          :always harness-perms-rules
          :roots (harness-perms-roots session)
          :inspect (mapcar (lambda (e) (plist-get e :dir)) (harness-perms-inspection-dirs))
          :skills (delq nil (mapcar (lambda (e) (and (plist-get e :contained) (plist-get e :dir)))
                                    (harness-perms-skill-dirs session))))))

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
                                                :kind (plist-get r :kind)
                                                :paths (if (plist-member w :paths) (plist-get w :paths)
                                                         (plist-get r :paths))
                                                :cwd (plist-get w :cwd)
                                                :dir (plist-get w :dir) :pattern (plist-get w :pattern)
                                                :title (or (plist-get w :title) (harness-perms-describe-request r))
                                                :options (or (plist-get w :options)
                                                             (if (plist-get w :dir)
                                                                 (harness-perms--dir-prompt-options
                                                                  harness-perms-dir-options)
                                                               (harness-perms--tool-options)))))
                           out))))
               harness-perms--waiting)
      out)))

;;;; Module

(harness-declare-event 'permission/requested
                       "(SESSION-ID PENDING) when a tool call waits for the user's answer.")
(harness-declare-event 'permission/dir-allowed
                       "(SESSION-ID DIR) after `permission/allow-dir', or a grant until the turn ends, widened the jail.")
(harness-declare-event 'permission/dir-revoked
                       "(SESSION-ID DIR) after `permission/revoke-dir', or the end of a turn, narrowed the jail.")

(defun harness-perms--init ()
  "Install the `permission/decide' chain and the steering after denials.
Grants until a turn ends are dropped from here on when it ends.  Safe
to call again."
  (harness-add-filter 'permission/decide #'harness-perms--dir-request 5)
  (harness-add-filter 'permission/decide #'harness-perms--away-request 6)
  (harness-add-filter 'permission/decide #'harness-perms--sandbox-guard 7)
  (harness-add-filter 'permission/decide #'harness-perms--jail 10)
  (harness-add-filter 'permission/decide #'harness-perms--mode 20)
  (harness-add-filter 'permission/decide #'harness-perms--auto 30)
  (harness-add-filter 'permission/decide #'harness-perms--non-interactive 40)
  (harness-add-filter 'permission/decide #'harness-perms--ask 90)
  (harness-on 'permission/decided #'harness-perms--on-decided)
  (harness-on 'session/updated #'harness-perms--on-session-updated)
  (harness-on 'session/deleted #'harness-perms--forget-revealed)
  ;; What was granted until a turn ends goes when it ends.
  (harness-on 'agent/turn-started #'harness-perms--end-turn-grants)
  (harness-on 'agent/turn-ended #'harness-perms--end-turn-grants))

(defun harness-perms--shutdown ()
  "Remove the `permission/decide' chain and the steering after denials."
  (dolist (fn '(harness-perms--dir-request harness-perms--away-request harness-perms--sandbox-guard
                harness-perms--jail harness-perms--mode
                harness-perms--auto harness-perms--non-interactive harness-perms--ask))
    (harness-remove-filter 'permission/decide fn))
  (harness-off (cons 'permission/decided #'harness-perms--on-decided))
  (harness-off (cons 'session/updated #'harness-perms--on-session-updated))
  (harness-off (cons 'session/deleted #'harness-perms--forget-revealed))
  (harness-off (cons 'agent/turn-started #'harness-perms--end-turn-grants))
  (harness-off (cons 'agent/turn-ended #'harness-perms--end-turn-grants)))

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
