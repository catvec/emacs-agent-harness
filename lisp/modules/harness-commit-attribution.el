;;; harness-commit-attribution.el --- Which model and prompt wrote each commit, privately  -*- lexical-binding: t; -*-

;;; Commentary:

;; Git records who committed; it does not record which model wrote which
;; lines, or which prompt asked for them.  git-ai does the line-level
;; part, but by default its notes follow `git push' to the code remote,
;; and its prompts can leave the machine.  This module adds the private
;; harness side of the design in
;; docs/analysis/private-commit-model-attribution-2026-10-29.md:
;;
;; - a private git-ai profile (telemetry off, prompts local, no login,
;;   notes uploaded to a private HTTP notes service instead of written
;;   to `refs/notes/ai');
;; - checkpoints built from the harness's own tool calls, so a line
;;   git-ai attributes to `emacs-agent-harness' is really a line one of
;;   its sessions wrote;
;; - an attribution epoch per (harness session, user prompt, model), so
;;   a model switch within a turn does not merge two models' lines, and
;;   a sub-agent's lines do not merge into its parent's turn;
;; - no prompt records of its own: the report says which prompt produced
;;   a commit from the private notes service's management API, where a
;;   redacted record can be read from another device;
;; - `report', `show' and `show-prompt' read the notes and those prompt
;;   records, never the commit message.
;;
;; Off by default.  The layered setting `harness-commit-attribution'
;; turns it on for a project (in its .dir-locals.el, which the settings
;; page's Project scope writes) or for every project (the global
;; value).  A repository is the unit: turning it on installs a
;; `pre-commit' safety net carrying the harness's marker, and turning
;; it off removes that hook again.  A hook somebody else wrote is left
;; alone.  The module does nothing in a repository that has not turned
;; it on: it runs no git-ai command and stores no prompt record.
;;
;; What is private.  The code remote receives no notes, no model names
;; and no prompts.  In the recommended `private-service' mode git-ai's
;; notes backend is HTTP: there is no `refs/notes/ai' at all, so a
;; push, a mirror and a fork have nothing to carry.  The private notes
;; service receives the git-ai authorship log -- commit SHAs, paths,
;; line ranges, session ids and agent/model ids -- and never source or
;; commit messages.  By default it receives no prompts either.
;; `harness-commit-attribution-prompt-sync' opts into storing redacted
;; prompt records there: the prompt runs through `harness-secrets'
;; before it leaves the machine, a `hash'-mode record carries only its
;; SHA-256, and the service keeps the records in plaintext behind its
;; token.  The records go through the service's management API, which
;; is separate from the worker endpoints git-ai uses; only the harness
;; reads and writes it.  A `secrets/redact' redaction triggers that
;; same API (`harness-redact--store-functions'), so a secret taken out
;; of this machine is taken out of the service too.  The module keeps
;; no copy of its own.  The encrypted prompt vault (phase 3 of the
;; design) remains the stronger option.  The UI (phase 4) is a
;; documented follow-up too: `status' says the vault is not
;; implemented yet.
;;
;; No block.  A checkpoint never blocks a tool call: it goes into a
;; queue per repository, runs `git-ai checkpoint agent-v1 --hook-input
;; stdin' asynchronously, and its failure is logged once.  The tool
;; result is unchanged.  Nothing is checkpointed when the module is
;; not on for the session's repository, when git-ai is missing, or when
;; no private notes URL is configured (so a checkpoint can never fall
;; back to git-ai's default notes backend and write `refs/notes/ai').
;;
;; The pre-commit hook.  A command that edits and commits in one shell
;; command would otherwise commit before the post-command checkpoint.
;; The module writes `harness-attribution/context.json' under the
;; repository's git directory before a bash command that may commit,
;; and the hook checkpoints the staged and untracked paths with that
;; context just before git creates the commit.  The hook always exits
;; 0.  It runs git-ai with a small private profile of its own under the
;; session's temporary directory, with the notes backend forced to HTTP
;; and the private URL, so even a sandbox that cannot see the user's
;; `~/.git-ai' can only write to the private service; without a token
;; in the environment the upload fails and is dropped, never written to
;; the repository.  The doctor says when the hook cannot cover a case.
;;
;; Epochs.  git-ai keys a session by `tool:conversation_id'.  The
;; harness uses
;;
;;   <harness-session-id>@<user-node-id>@<model>
;;
;; as the conversation id (the model is the epoch: a model switch makes
;; a new one), and puts the same model in the checkpoint.  A tool call
;; outside a turn uses `system@<action>' and no prompt.  The model is
;; the one recorded on the tool-call node, not the session's model at
;; the end of the call: a model switch belongs to the next call.
;;
;; The report.  `commit-attribution/report' reads the notes through the
;; private service's read endpoint (or `git-ai show' without one),
;; parses the git-ai authorship log, and joins each session to the
;; prompt record the service's management API holds.  It counts AI
;; lines, not all lines: git-ai leaves human and untracked lines
;; unattributed, and this module does not invent an attribution for
;; them.  `commit-attribution/show' prints one commit and
;; `commit-attribution/show-prompt' returns the prompt text the service
;; stored.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-http)
(require 'harness-redaction)

(defvar harness-state-directory)

(declare-function harness-config--work-dirs "harness-config" ())
(declare-function harness-worktree--git "harness-worktree" (cwd &rest args))
(declare-function harness-worktree--same-path-p "harness-worktree" (a b))
(declare-function harness-worktree--known-roots "harness-worktree" ())
(declare-function harness-secrets-mask-text "harness-secrets" (text))
(declare-function harness-tools-resolve-path "harness-tools" (path ctx))
;; The redaction engine calls the store below; the module is optional, so
;; only these names are needed, and only when that engine is loaded.
(declare-function harness-redact-run-ids "harness-redact" (run))
(declare-function harness-redact-run-secrets "harness-redact" (run))
(declare-function harness-redact-run-dry-p "harness-redact" (run))
(declare-function harness-redact-add-store "harness-redact" (run store &optional lines))
(declare-function harness-redact-entry-incr "harness-redact" (run sid key n))
(declare-function harness-redact-entry-add "harness-redact" (run sid key items))

;;;; The setting

(defcustom harness-commit-attribution nil
  "Non-nil records which model and prompt wrote each commit, privately.
Where it is on, the harness feeds git-ai checkpoints from its own tool
calls, stores redacted prompt records in the private notes service when
prompt sync is on, and installs a `pre-commit' safety net in the
repository.  The attribution travels to a private notes service, never
to the code remote.

It is off by default.  Turn it on for a project in that project's
.dir-locals.el, which the settings page's Project scope writes:

  ((nil . ((harness-commit-attribution . t))))

A .dir-locals.el that applies to a directory a session works in, a
task's worktree or a subdirectory, turns it on for that repository too.
The global value t turns it on in every repository the harness works
in; turning it on per project is the better habit.

Turning it on runs git-ai only after the other settings are in place
\(see `harness-commit-attribution-notes-url'): without a private notes
URL the module records nothing rather than risk writing git notes that
could be pushed.  Run `commit-attribution/configure' to write the
private git-ai profile and `commit-attribution/doctor' to check it."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-commit-attribution-backend 'git-ai
  "The attribution backend.  `git-ai' is the only one in this version.
A native commit-level fallback, without line attribution, is a later
phase of the design."
  :type '(choice (const :tag "git-ai" git-ai)) :safe (lambda (v) (eq v 'git-ai))
  :group 'harness)

(defcustom harness-commit-attribution-git-ai-program "git-ai"
  "The git-ai program, or its absolute path when it is not on PATH."
  :type 'string :safe #'stringp :group 'harness)

(defcustom harness-commit-attribution-notes-mode 'private-service
  "Where the attribution notes go.
`private-service' uploads them to `harness-commit-attribution-notes-url'
over HTTP and keeps no `refs/notes/ai' in the repository.  `local' is
the same backend pointed at a loopback-only service: nothing syncs,
nothing is published.  `private-remote' would keep git notes and is
refused in this version (see `commit-attribution/configure'): git-ai's
own note push uses `--no-verify', and the Profile C pre-push guard is a
phase 5 follow-up."
  :type '(choice (const :tag "Private notes service" private-service)
                 (const :tag "Local service only" local)
                 (const :tag "Private Git notes remote (compatibility)"
                        private-remote))
  :safe (lambda (v) (memq v '(private-service local private-remote)))
  :group 'harness)

(defcustom harness-commit-attribution-notes-url nil
  "Base URL of the private notes service, such as https://notes.example.internal.
Required in `private-service' and `local' mode.  The module refuses to
checkpoint without it, so a checkpoint can never fall back to git-ai's
default notes backend and write `refs/notes/ai' into the repository."
  :type '(choice (const :tag "Not set" nil) string)
  :safe (lambda (v) (or (null v) (stringp v))) :group 'harness)

(defcustom harness-commit-attribution-notes-token nil
  "Per-device API key for the private notes service.
git-ai sends it as `X-API-Key'.  Prefer the environment variable
`GIT_AI_API_KEY' or the secret store: a value set here is written to
`~/.git-ai/config.json' by `commit-attribution/configure' (mode 600),
while a value from the environment is inherited by the pre-commit hook
and never written anywhere."
  :type '(choice (const :tag "Use GIT_AI_API_KEY" nil) string)
  :safe (lambda (v) (or (null v) (stringp v))) :group 'harness)

(defcustom harness-commit-attribution-vault nil
  "Directory or private Git remote of the encrypted prompt vault.
The vault is phase 3 of the design and is not implemented yet; the
setting is here so a configuration can be written now, and
`commit-attribution/status' says the vault is a follow-up.  Until then
the redacted prompts live only in the private notes service's
management API, when prompt sync is on."
  :type '(choice (const :tag "Not set" nil) directory string)
  :safe (lambda (v) (or (null v) (stringp v))) :group 'harness)

(defcustom harness-commit-attribution-device (system-name)
  "Device id used for the vault file and the notes the module records.
It defaults to this machine's host name."
  :type 'string :safe #'stringp :group 'harness)

(defcustom harness-commit-attribution-recipients nil
  "age/GPG recipients of the prompt vault; public keys only.
Phase 3 of the design; not used yet."
  :type '(repeat string) :safe (lambda (v) (and (listp v) (cl-every #'stringp v)))
  :group 'harness)

(defcustom harness-commit-attribution-prompt-mode 'excerpt
  "How much of a prompt the private prompt service keeps.
`excerpt' keeps a short excerpt, `full' keeps it whole, and `hash'
keeps only its SHA-256.  Every mode keeps the hash.  The text is run
through `harness-secrets-mask-text' before it is uploaded, and the
module keeps no copy of its own."
  :type '(choice (const :tag "Redacted excerpt" excerpt)
                 (const :tag "Redacted full prompt" full)
                 (const :tag "Hash only" hash))
  :safe (lambda (v) (memq v '(excerpt full hash))) :group 'harness)

(defcustom harness-commit-attribution-excerpt-chars 500
  "Most characters of a prompt `harness-commit-attribution-prompt-mode'
`excerpt' keeps."
  :type 'natnum :safe #'natnump :group 'harness)

(defcustom harness-commit-attribution-prompt-sync nil
  "Non-nil stores redacted prompt records in the private notes service.
The module keeps no records of its own: with this off, no prompt text
is stored anywhere by it, and the report says the prompt is
unavailable.  With it on, the record of each conversation is uploaded
through the service's management API to
`harness-commit-attribution-notes-url', so another device can link the
prompt.  The prompt is masked with `harness-secrets' before it is
uploaded, and the record hashes the masked text, never the original.
A `hash'-mode record carries only that hash.  The service stores the
record in plaintext behind its token.  It is off by default."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-commit-attribution-retention-days nil
  "The number of days after which `commit-attribution/prune' deletes prompt records.
Nil keeps them until pruned by hand.  The records live in the private
notes service, so pruning calls its management API; it changes no
notes, and no Git history."
  :type '(choice (const :tag "Keep until pruned" nil) natnum)
  :safe (lambda (v) (or (null v) (natnump v))) :group 'harness)

(defcustom harness-commit-attribution-private-remotes nil
  "Remote names or URL prefixes allowed to receive `refs/notes/*'.
Reserved for the Profile C pre-push guard, a phase 5 follow-up; this
version never pushes notes.  Remember that git-ai's own note push uses
`--no-verify', which is why `private-service' is the default."
  :type '(repeat string) :safe (lambda (v) (and (listp v) (cl-every #'stringp v)))
  :group 'harness)

(defcustom harness-commit-attribution-task-report t
  "Non-nil adds the model-attribution section to task reports.
The task-report UI is phase 4 of the design; the report data this
setting would use is already produced by `commit-attribution/report'."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-commit-attribution-include-subagents t
  "Non-nil attributes sub-agent sessions separately from their parent.
A sub-agent has a session id of its own, so its lines never merge into
the parent's prompt by accident."
  :type 'boolean :safe #'booleanp :group 'harness)

;;;; Constants and state

(defconst harness-commit-attribution-agent-name "emacs-agent-harness"
  "The agent name the module writes into every git-ai checkpoint.")

(defconst harness-commit-attribution-hook-marker
  "# harness: private commit attribution"
  "Line marking a `pre-commit' hook as the harness's own.
The harness rewrites or removes only a hook carrying it.")

(defconst harness-commit-attribution--record-file "commit-attribution-repos.json"
  "File in `harness-state-directory' naming the repositories with the hook.")

(defconst harness-commit-attribution--directory "commit-attribution"
  "Directory under `harness-state-directory' for the module's records.")

(defconst harness-commit-attribution--context-file
  "harness-attribution/context.json"
  "Context file under a repository's git directory, for the pre-commit hook.")

(defconst harness-commit-attribution--checkpoint-timeout 20
  "Seconds a git-ai checkpoint may run before it is killed.")

(defvar harness-commit-attribution-git-ai-directory
  (expand-file-name "~/.git-ai")
  "The git-ai state directory; `~/.git-ai' in ordinary use.
A test binds it to a temporary directory; `configure' backs up and
writes `config.json' there.")

(defvar harness-commit-attribution--version-cache nil
  "Cons of the git-ai version string and when it was read.")

(defvar harness-commit-attribution--repo-cache (make-hash-table :test 'equal)
  "CWD -> (ROOT . GIT-DIR) for the local repositories the module saw.
An entry is nil when CWD is in no repository, so a directory outside
one costs no git again.")

(defvar harness-commit-attribution--session-cache (make-hash-table :test 'equal)
  "Session id -> plist of the session's attribution state.
`:active' says whether the module acts for it, `:root' the worktree
root, `:git-dir' its git directory and `:main' its main checkout.
Cleared at a start, a reload and a configuration change.")

(defvar harness-commit-attribution--prompts (make-hash-table :test 'equal)
  "Session id -> the latest user node that may open a turn.
A node is (:id :text :at); a steering message does not replace it.")

(defvar harness-commit-attribution--turns (make-hash-table :test 'equal)
  "Session id -> the prompt and model of its running turn, while one runs.
A plist (:id NODE-ID :text TEXT :model MODEL :at TIME).")

(defvar harness-commit-attribution--calls (make-hash-table :test 'equal)
  "Cons of session id and call id -> the call's attribution context.
The context is a plist: `:model', `:conversation', `:root' and `:input'.")

(defvar harness-commit-attribution--seen-results (make-hash-table :test 'equal)
  "Cons of session id and call id -> t when `tools/finished' saw the call.
`agent/tool-result' then does not checkpoint it a second time.")

(defvar harness-commit-attribution--prompts-sent (make-hash-table :test 'equal)
  "Conversation -> hash of the prompt record stored in the private service.
A conversation is uploaded once; a later checkpoint retries one whose
upload failed.")

(defvar harness-commit-attribution--prompts-sending (make-hash-table :test 'equal)
  "Conversation -> t while its prompt record is being uploaded.
It keeps a second checkpoint from sending the same record twice.")

(defvar harness-commit-attribution--prompt-error (make-hash-table :test 'equal)
  "Conversation -> t when storing its prompt in the service failed.
The first failure is logged; later checkpoints retry quietly.")

(defvar harness-commit-attribution--last-error (make-hash-table :test 'equal)
  "Repository -> the last checkpoint error logged for it.
The first failure there is logged; later ones are counted, so a broken
git-ai does not fill the log one tool call at a time.")

(defvar harness-commit-attribution--queues (make-hash-table :test 'equal)
  "Repository -> the checkpoint jobs waiting to run there, oldest first.")

(defvar harness-commit-attribution--running (make-hash-table :test 'equal)
  "Repository -> t while a checkpoint of its queue runs.")

(defvar harness-commit-attribution--flush-waiters nil
  "Functions called when every checkpoint queue is idle.
`harness-commit-attribution--flush' registers one; the last pump calls
them.")

(defvar harness-commit-attribution--installed (make-hash-table :test 'equal)
  "Main checkout -> t for repositories found with the hook lately.")

(defvar harness-commit-attribution--noted (make-hash-table :test 'equal)
  "Repositories whose foreign hook or hooks path was logged already.")

(defvar harness-commit-attribution--pass-memo nil
  "Directory -> main checkout while a full selection pass runs.")

(defvar harness-commit-attribution--pass-work-dirs nil
  "(DIRS) while a full pass runs: the work directories, found once.")

(defvar harness-commit-attribution--sandbox-dirs nil
  "Directories the module makes readable to sandboxed commands.
They are the git-ai program's directory and its state directory.")

;;;; Small helpers

(defun harness-commit-attribution--canonical (dir)
  "Return DIR as the record keeps a main checkout: absolute, no links, a directory."
  (file-name-as-directory (harness-path-normalize dir)))

(defun harness-commit-attribution--repository-p (dir)
  "Non-nil when DIR is the main checkout of a local git repository."
  (and (stringp dir)
       (not (file-remote-p dir))
       (file-directory-p (expand-file-name ".git" dir))))

(defun harness-commit-attribution--main (dir)
  "Return the main checkout of the local repository DIR lies in, or nil."
  (when (and (stringp dir) (not (file-remote-p dir)) (file-directory-p dir))
    (let* ((memo harness-commit-attribution--pass-memo)
           (found (and memo (gethash dir memo 'unknown))))
      (if (and memo (not (eq found 'unknown)))
          found
        (let ((main (ignore-errors (harness-files-main-root dir))))
          (setq main (and (harness-commit-attribution--repository-p main)
                          (harness-commit-attribution--canonical main)))
          (when memo (puthash dir main memo))
          main)))))

(defun harness-commit-attribution--work-dirs ()
  "Return the directories the harness works in now."
  (cond (harness-commit-attribution--pass-work-dirs
         (car harness-commit-attribution--pass-work-dirs))
        ((fboundp 'harness-config--work-dirs) (harness-config--work-dirs))))

(defun harness-commit-attribution--on-at-p (dir)
  "Non-nil when `harness-commit-attribution' is on at DIR."
  (if (harness-method-exists-p 'config/get)
      (harness-json-true-p
       (harness-call 'config/get 'harness-commit-attribution dir))
    (and (boundp 'harness-commit-attribution)
         (symbol-value 'harness-commit-attribution)
         t)))

(defun harness-commit-attribution--selected-p (main &optional dirs)
  "Non-nil when the repository whose main checkout is MAIN is selected.
It is when the setting is on at MAIN, or at any directory the harness
works in that lies in that repository: one of DIRS, or a work
directory (`harness-commit-attribution--work-dirs')."
  (let ((on-in-repository
         (lambda (dir)
           (and (stringp dir) (not (file-remote-p dir))
                (equal (harness-commit-attribution--main dir) main)
                (harness-commit-attribution--on-at-p dir)))))
    (and (or (harness-commit-attribution--on-at-p main)
             (cl-some on-in-repository dirs)
             (cl-some on-in-repository (harness-commit-attribution--work-dirs)))
         t)))

(defun harness-commit-attribution--git-sync (root &rest args)
  "Run git ARGS in ROOT synchronously; return (EXIT . OUTPUT).
The exit status is nil when git could not be run.  This is only for
small queries a handler cannot wait for, such as `rev-parse' and
`status' before a command that may commit."
  (let ((default-directory (file-name-as-directory root)))
    (with-temp-buffer
      (let ((status (condition-case nil
                        (apply #'call-process "git" nil t nil args)
                      (error nil))))
        (cons status (buffer-string))))))

(defun harness-commit-attribution--repo (cwd)
  "Return (ROOT . GIT-DIR) for the repository CWD lies in, or nil.
ROOT is the worktree root a checkpoint of CWD runs in; GIT-DIR is the
directory `git rev-parse --git-dir' reports there."
  (when (and (stringp cwd) (not (file-remote-p cwd)) (file-directory-p cwd))
    (let ((cached (gethash cwd harness-commit-attribution--repo-cache 'unknown)))
      (if (not (eq cached 'unknown))
          cached
        (let* ((top (harness-commit-attribution--git-sync cwd "rev-parse" "--show-toplevel"))
               (root (and (car top) (zerop (car top))
                          (string-trim (cdr top))))
               (git-dir (and root
                             (harness-commit-attribution--git-sync
                              root "rev-parse" "--git-dir")))
               (git-dir (and git-dir (car git-dir) (zerop (car git-dir))
                             (string-trim (cdr git-dir))))
               (value (and root git-dir
                           (cons (file-name-as-directory (expand-file-name root root))
                                 (file-name-as-directory
                                  (expand-file-name git-dir root))))))
          (puthash cwd value harness-commit-attribution--repo-cache)
          value)))))

(defun harness-commit-attribution--repo-id (main)
  "Return the stable, non-revealing id of the repository at MAIN."
  (format "sha256:%s"
          (substring (secure-hash 'sha256 (encode-coding-string main 'utf-8))
                     0 16)))

(defun harness-commit-attribution--provider (model)
  "Return the provider part of MODEL, or nil."
  (and (stringp model) (string-match "\\`\\([^:]+\\):" model)
       (match-string 1 model)))

(defun harness-commit-attribution--now ()
  "Return the current time as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun harness-commit-attribution--program ()
  "Return the git-ai program the module runs."
  (or (and (stringp harness-commit-attribution-git-ai-program)
           (not (string-empty-p harness-commit-attribution-git-ai-program))
           harness-commit-attribution-git-ai-program)
      "git-ai"))

(defun harness-commit-attribution--program-path ()
  "Return the absolute path of the git-ai program, or nil when not found."
  (let ((program (harness-commit-attribution--program)))
    (cond ((file-name-absolute-p program)
           (and (file-executable-p program) program))
          ((executable-find program)))))

(defun harness-commit-attribution--url ()
  "Return the private notes base URL without a trailing slash, or nil."
  (let ((url (and (stringp harness-commit-attribution-notes-url)
                  (string-trim harness-commit-attribution-notes-url))))
    (when (and url (not (string-empty-p url)))
      (string-remove-suffix "/" url))))

(defun harness-commit-attribution--token ()
  "Return the private notes token, from the setting or the environment."
  (let ((token (or harness-commit-attribution-notes-token
                   (getenv "GIT_AI_API_KEY"))))
    (and (stringp token) (not (string-empty-p token)) token)))

(defun harness-commit-attribution--notes-private-p ()
  "Non-nil when the notes URL is not git-ai's public default."
  (let ((url (harness-commit-attribution--url)))
    (and url
         (not (string-match-p
               (concat "\\`https?://\\(api\\.\\)?"
                       "\\(usegitai\\.com\\|git-ai\\.com\\)"
                       "\\(?:/\\|:\\|\\'\\)")
               url))
         t)))

(defun harness-commit-attribution--mode ()
  "Return the notes mode actually in use."
  (if (eq harness-commit-attribution-notes-mode 'private-remote)
      'private-remote
    (or harness-commit-attribution-notes-mode 'private-service)))

(defun harness-commit-attribution--checkpoint-allowed-p ()
  "Non-nil when a checkpoint may run without risking a public note.
A private notes URL must be configured, and the notes mode must be the
HTTP one.  `private-remote' (Profile C) is a phase 5 follow-up and is
refused here: its only safe form needs the upstream `notes_sync'
setting or a push gateway, and this version will not write git notes
that a plain `git push' could publish."
  (and (not (eq (harness-commit-attribution--mode) 'private-remote))
       (harness-commit-attribution--notes-private-p)
       t))

(defun harness-commit-attribution--prompt-sync-p ()
  "Non-nil when redacted prompts may be uploaded to the private service.
Prompt sync is off by default; it needs the module's private notes URL
as well, so a prompt can never go to git-ai's public default host or
into git notes.  It also needs `harness-secrets' loaded: an unredacted
prompt is never uploaded."
  (and harness-commit-attribution-prompt-sync
       (fboundp 'harness-secrets-mask-text)
       (harness-commit-attribution--checkpoint-allowed-p)
       t))

(defun harness-commit-attribution--checkpoint-env ()
  "Return the environment that forces a checkpoint onto the private service.
This overrides a user config that still says `git_notes' for the
process the module runs, so its own checkpoints never write
`refs/notes/ai'."
  (when (not (eq (harness-commit-attribution--mode) 'private-remote))
    (let ((url (harness-commit-attribution--url))
          (token (harness-commit-attribution--token)))
      (append (and url (list (cons "GIT_AI_NOTES_BACKEND_KIND" "http")
                             (cons "GIT_AI_NOTES_BACKEND_URL" url)
                             (cons "GIT_AI_API_BASE_URL" url)))
              (and token (list (cons "GIT_AI_API_KEY" token)))))))

;;;; The private profile

(defun harness-commit-attribution--config-file ()
  "Return the path of the git-ai configuration file."
  (expand-file-name "config.json" harness-commit-attribution-git-ai-directory))

(defun harness-commit-attribution--read-config ()
  "Return the git-ai configuration as a plist, or nil when there is none.
Signals when the file exists and is not JSON."
  (let ((file (harness-commit-attribution--config-file)))
    (when (file-readable-p file)
      (let ((data (harness-json-parse (harness-read-file file))))
        (and data (if (listp data) data (error "git-ai config is not a JSON object: %s" file)))))))

(defun harness-commit-attribution--check-config (config)
  "Return a list of checks of CONFIG, the parsed git-ai configuration.
Each is (:name NAME :ok BOOL :severity error/warning/info :detail TEXT)."
  (let* ((kind (plist-get (plist-get config :notes_backend) :kind))
         (backend-url (plist-get (plist-get config :notes_backend) :backend_url))
         (url (or backend-url (plist-get config :api_base_url)))
         (prompts (or (plist-get config :exclude_prompts_in_repositories) nil))
         (mode (harness-commit-attribution--mode))
         (want-http (not (eq mode 'private-remote))))
    (list
     (list :name "telemetry" :severity 'error
           :ok (if (or (equal (plist-get config :telemetry_oss) "off")
                       (harness-json-true-p (plist-get config :telemetry_oss_disabled)))
                   t :false)
           :detail (if (or (equal (plist-get config :telemetry_oss) "off")
                           (harness-json-true-p (plist-get config :telemetry_oss_disabled)))
                       "OSS telemetry is off"
                     "telemetry_oss is not off: set it to \"off\""))
     (list :name "prompts-local" :severity 'error
           :ok (if (equal (plist-get config :prompt_storage) "local") t :false)
           :detail (format "prompt_storage is %s"
                           (or (plist-get config :prompt_storage) "unset (default uploads prompts)")))
     (list :name "prompts-excluded" :severity 'warning
           :ok (if (and (listp prompts) (member "*" prompts)) t :false)
           :detail (if (and (listp prompts) (member "*" prompts))
                       "prompts are excluded from every repository"
                     "exclude_prompts_in_repositories does not name \"*\""))
     (list :name "updates" :severity 'warning
           :ok (if (and (harness-json-true-p (plist-get config :disable_auto_updates))
                        (harness-json-true-p (plist-get config :disable_version_checks)))
                   t :false)
           :detail (if (and (harness-json-true-p (plist-get config :disable_auto_updates))
                            (harness-json-true-p (plist-get config :disable_version_checks)))
                       "auto-updates and version checks are off"
                     "disable_auto_updates and disable_version_checks should be true"))
     (list :name "login" :severity 'warning
           :ok (if (file-exists-p
                    (expand-file-name "internal/credentials" harness-commit-attribution-git-ai-directory))
                   :false t)
           :detail (if (file-exists-p
                        (expand-file-name "internal/credentials"
                                          harness-commit-attribution-git-ai-directory))
                       "git-ai has a cloud login; private mode expects only a private service token"
                     "no git-ai cloud login found"))
     (list :name "notes-backend" :severity 'error
           :ok (if (or (not want-http)
                       (and (equal (format "%s" kind) "http") (stringp url)
                            (not (string-empty-p url))))
                   t :false)
           :detail (cond ((not want-http)
                          (format "git_notes mode (private-remote): %s"
                                  (if harness-commit-attribution-private-remotes
                                      "private remotes are named" "no private remotes are named")))
                         ((not (equal (format "%s" kind) "http"))
                          (format "notes backend is %s, not http" (or kind "unset (git_notes)")))
                         ((not (and (stringp url) (not (string-empty-p url))))
                          "the notes backend has no URL")
                         (t (format "HTTP notes backend at %s" url))))
     (list :name "notes-private" :severity 'error
           :ok (if (or (not want-http) (harness-commit-attribution--notes-private-p))
                   t :false)
           :detail (if (or (not want-http) (harness-commit-attribution--notes-private-p))
                       "the notes URL is not git-ai's public default"
                     "the notes URL is unset or git-ai's public default"))
     (list :name "notes-auth" :severity 'warning
           :ok (if (harness-commit-attribution--token) t :false)
           :detail (if (harness-commit-attribution--token)
                       "a notes service token is configured"
                     "no notes token: set GIT_AI_API_KEY or the notes-token setting"))
     (list :name "login-key" :severity 'info
           :ok t
           :detail "a private service API key is not a Git AI cloud login"))))

(defun harness-commit-attribution--version ()
  "Return the git-ai version string, or nil when git-ai cannot be run.
The answer is cached for a minute; a doctor run refreshes it."
  (let* ((now (float-time))
         (cached harness-commit-attribution--version-cache))
    (if (and cached (< (- now (cdr cached)) 60))
        (car cached)
      (let* ((program (harness-commit-attribution--program-path))
             (version
              (when program
                (with-temp-buffer
                  (when (condition-case nil
                            (zerop (call-process program nil t nil "--version"))
                          (error nil))
                    (let ((line (string-trim (buffer-string))))
                      (unless (string-empty-p line) line)))))))
        (setq harness-commit-attribution--version-cache (cons version now))
        version))))

(defun harness-commit-attribution--backup-config ()
  "Copy the git-ai configuration to a timestamped backup; return its path.
Nil when there is no configuration to back up.  The copy keeps mode 600."
  (let ((file (harness-commit-attribution--config-file)))
    (when (file-exists-p file)
      (let* ((stamp (format-time-string "%Y%m%d-%H%M%S"))
             (backup (concat file ".harness-backup-" stamp)))
        (copy-file file backup t nil nil nil)
        (set-file-modes backup #o600)
        (harness-log 'info "commit-attribution: backed up %s to %s"
                     (abbreviate-file-name file) (abbreviate-file-name backup))
        backup))))

(harness-defmethod commit-attribution/configure (dir &optional options)
  "Write the private git-ai profile, with a backup and a diff of the config.
DIR names the repository the settings apply to; OPTIONS may override
`:notes-url', `:notes-token' and `:notes-mode'.  The previous
`~/.git-ai/config.json' is copied to a timestamped mode-600 backup
first.  Every other key in it is kept.  The profile turns OSS telemetry
off, keeps prompts local and out of every repository, disables updates
and version checks, and points the HTTP notes backend at the private
service, so git-ai writes no `refs/notes/ai' to publish.

Return a plist: `:config' and `:backup' are paths (nil for no backup),
`:before' and `:after' the JSON texts, `:changed' the keys this call
changed, `:repository' the main checkout DIR lies in, `:notes-url' the
URL written, and `:mode' the notes mode.  Signal an error when no
private notes URL is given: a profile without one would leave git-ai on
its default notes backend, which is exactly the public leak this mode
exists to avoid."
  (let* ((url (or (plist-get options :notes-url) (harness-commit-attribution--url)))
         (token (or (plist-get options :notes-token)
                    harness-commit-attribution-notes-token))
         (mode (or (plist-get options :notes-mode)
                   harness-commit-attribution-notes-mode
                   'private-service))
         (main (harness-commit-attribution--main
                (or dir default-directory)))
         (file (harness-commit-attribution--config-file))
         (before-text (and (file-exists-p file) (harness-read-file file)))
         (before (condition-case err
                     (and before-text (harness-json-parse before-text))
                   (error (error "Cannot read the existing git-ai config %s: %s"
                                 file (harness-error-message err)))))
         (after (copy-sequence before))
         (changed nil))
    (when (equal (format "%s" mode) "private-remote")
      (error "private-remote mode (Profile C) is a phase 5 follow-up; use private-service"))
    (unless (and (stringp url) (not (string-empty-p (string-trim url))))
      (error "A private notes URL is required: set harness-commit-attribution-notes-url first"))
    (setq url (string-remove-suffix "/" (string-trim url)))
    (cl-flet ((put (key value)
                (unless (equal (plist-get after key) value) (push (symbol-name key) changed))
                (setq after (plist-put after key value))))
      (put :telemetry_oss "off")
      (put :prompt_storage "local")
      (put :exclude_prompts_in_repositories (harness-json-array '("*")))
      (put :disable_auto_updates t)
      (put :disable_version_checks t)
      (put :api_base_url url)
      (put :notes_backend (list :kind (if (equal (format "%s" mode) "private-remote")
                                          "git_notes" "http")
                                :backend_url url))
      ;; A saved cloud key has no place in a private profile: the private
      ;; service token goes here only when it has to be in the file.
      (setq after (harness-plist-remove after :api_key))
      (when (and (stringp token) (not (string-empty-p token)))
        (setq after (plist-put after :api_key token))
        (push "api_key" changed)))
    (let* ((backup (harness-commit-attribution--backup-config))
           (after-text (concat (harness-json-encode-text after) "\n")))
      (harness-ensure-directory (file-name-directory file))
      (harness-write-file-atomically file after-text)
      (set-file-modes file #o600)
      (harness-log 'info "commit-attribution: wrote the private git-ai profile to %s"
                   (abbreviate-file-name file))
      (list :config file :backup backup
            :before before-text :after after-text
            :changed (delete-dups changed)
            :repository main
            :notes-url url
            :mode mode))))

(defun harness-commit-attribution--service-get (shas)
  "Return a promise of an alist of commit SHA -> note content from the service.
SHAS is a list of hex commit ids.  Resolves to nil without a private
notes URL.  Rejects when the service is unreachable, rejects the token,
or answers with a failure other than 404 (which means no note)."
  (let ((url (harness-commit-attribution--url)))
    (if (or (null url) (null shas))
        (harness-resolved nil)
      (harness-with-promise (resolve reject)
        (let ((handle
               (harness-http-request
                (format "%s/worker/notes/?commits=%s"
                        url (mapconcat #'identity shas ","))
                :method "GET"
                :headers (append (and (harness-commit-attribution--token)
                                      (list (cons "X-API-Key"
                                                  (harness-commit-attribution--token))))
                                 '(("Accept" . "application/json")))
                :timeout 20
                :callback
                (lambda (status _headers body err)
                  (cond
                   (err (funcall reject (list 'notes-service status err)))
                   ((eq status 404) (funcall resolve nil))
                   ((and status (>= status 200) (< status 300))
                    (condition-case e
                        (let* ((data (harness-json-parse body))
                               (notes (plist-get data :notes))
                               (out nil))
                          ;; JSON object keys arrive as keywords (:sha);
                          ;; the report looks its commits up by string.
                          (cl-loop for (key value) on notes by #'cddr
                                   do (push (cons (if (keywordp key)
                                                      (substring (symbol-name key) 1)
                                                    key)
                                                  value)
                                            out))
                          (funcall resolve (nreverse out)))
                      (error (funcall reject (list 'notes-service status (format "%S" e))))))
                   ((memq status '(401 403))
                    (funcall reject (list 'notes-service status
                                          "the private notes service rejected the token")))
                   (t (funcall reject (list 'notes-service status body))))))))
          (ignore handle))))))

(defun harness-commit-attribution--service-prompts-get (conversations &optional sessions)
  "Return a promise of an alist of CONVERSATION -> prompt record.
CONVERSATIONS, a list of epoch ids, or SESSIONS, a list of harness
session ids, says what to ask for; the service's management API is the
only store of prompt records.  Resolves to nil without a private notes
URL or ids.  A 404 means the service knows none; a rejected token or
another failure rejects."
  (let ((url (harness-commit-attribution--url)))
    (if (or (null url) (and (null conversations) (null sessions)))
        (harness-resolved nil)
      (harness-with-promise (resolve reject)
        (let ((handle
               (harness-http-request
                (format "%s/management/prompts/?%s"
                        url
                        (string-join
                         (delq nil
                               (list (and conversations
                                          (format "conversations=%s"
                                                  (mapconcat #'url-hexify-string conversations ",")))
                                     (and sessions
                                          (format "sessions=%s"
                                                  (mapconcat #'url-hexify-string sessions ",")))))
                         "&"))
                :method "GET"
                :headers (append (and (harness-commit-attribution--token)
                                      (list (cons "X-API-Key"
                                                  (harness-commit-attribution--token))))
                                 '(("Accept" . "application/json")))
                :timeout 20
                :callback
                (lambda (status _headers body err)
                  (cond
                   (err (funcall reject (list 'prompt-service status err)))
                   ((eq status 404) (funcall resolve nil))
                   ((and status (>= status 200) (< status 300))
                    (condition-case e
                        (let* ((data (harness-json-parse body))
                               (prompts (plist-get data :prompts))
                               (out nil))
                          (cl-loop for (key value) on prompts by #'cddr
                                   do (push (cons (if (keywordp key)
                                                      (substring (symbol-name key) 1)
                                                    key)
                                                  value)
                                            out))
                          (funcall resolve (nreverse out)))
                      (error (funcall reject (list 'prompt-service status (format "%S" e))))))
                   ((memq status '(401 403))
                    (funcall reject (list 'prompt-service status
                                          "the private notes service rejected the token")))
                   (t (funcall reject (list 'prompt-service status body))))))))
          (ignore handle))))))

(defun harness-commit-attribution--fail (fmt &rest args)
  "Signal a `harness-error' whose message FMT formats with ARGS.
Callers pass names, URLs, statuses and counts, never a prompt."
  (signal 'harness-error (list (apply #'format fmt args))))

(defconst harness-commit-attribution--management-read-limit 100
  "Most ids the management API takes in one read, as the service enforces.")

(defun harness-commit-attribution--management (method path &optional json)
  "Call the private service's management API synchronously and return its body.
METHOD, PATH and JSON describe the request; PATH is relative to
`harness-commit-attribution-notes-url'.  The body is parsed as JSON
when it is not empty.  A 404 gives nil (a read takes that as no
records, a write as a missing management API), a rejected token or
another failure signals a `harness-error' whose message names no
prompt.  This is for the redaction engine and for pruning, which
cannot wait on a promise; the report uses the asynchronous reader."
  (let ((url (harness-commit-attribution--url)))
    (unless url
      (harness-commit-attribution--fail "no private notes URL is configured"))
    (let* ((result (harness-http-request-sync
                    (concat url path)
                    :method method
                    :headers (append (and (harness-commit-attribution--token)
                                          (list (cons "X-API-Key"
                                                      (harness-commit-attribution--token))))
                                     '(("Accept" . "application/json")))
                    :json json
                    :timeout 20))
           (status (plist-get result :status))
           (body (or (plist-get result :body) "")))
      (cond
       ((eq status 404) nil)
       ((and status (>= status 200) (< status 300))
        (if (string-empty-p (string-trim body))
            nil
          (harness-json-parse body)))
       ((memq status '(401 403))
        (harness-commit-attribution--fail
         "the private notes service rejected the token"))
       (t (harness-commit-attribution--fail
           "the private notes service answered %s for %s" status path))))))

(defun harness-commit-attribution--management-prompts (conversations sessions)
  "Return an alist of CONVERSATION -> record from the management API.
CONVERSATIONS or SESSIONS says what to ask for; the ids are sent in
batches the service accepts.  A conversation that is not there is
simply absent.  The caller must have checked for a service URL."
  (let ((out nil)
        (batches nil))
    (dolist (pair (list (cons "conversations" conversations)
                        (cons "sessions" sessions)))
      (let ((key (car pair))
            (ids (cdr pair)))
        (while ids
          (push (cons key (take harness-commit-attribution--management-read-limit ids)) batches)
          (setq ids (nthcdr harness-commit-attribution--management-read-limit ids)))))
    (dolist (batch (nreverse batches))
      (let ((data (harness-commit-attribution--management
                   "GET"
                   (format "/management/prompts/?%s=%s"
                           (car batch)
                           (mapconcat #'url-hexify-string (cdr batch) ",")))))
        (let ((prompts (plist-get data :prompts)))
          (cl-loop for (key value) on prompts by #'cddr
                   do (push (cons (if (keywordp key)
                                      (substring (symbol-name key) 1)
                                    key)
                                  value)
                            out)))))
    (nreverse out)))

(defun harness-commit-attribution--management-upload (entries)
  "Store ENTRIES, (CONVERSATION . RECORD) pairs, through the management API.
Return the number the service accepted.  Signals when it does not
answer or refuses the token."
  (let* ((data (harness-commit-attribution--management
                "POST" "/management/prompts/upload"
                (list :entries
                      (mapcar (lambda (entry)
                                (list :conversation (car entry) :record (cdr entry)))
                              entries))))
         (success (plist-get data :success_count))
         (failure (plist-get data :failure_count)))
    (unless data
      (harness-commit-attribution--fail
       "the private notes service has no prompt management API at %s"
       (harness-commit-attribution--url)))
    (if (and (numberp failure) (> failure 0))
        (harness-commit-attribution--fail
         "the private notes service refused %d prompt record(s)" failure)
      (or success 0))))

(defun harness-commit-attribution--management-delete (&optional conversations before)
  "Delete prompt records through the management API and return how many.
CONVERSATIONS names the records to delete; BEFORE, an ISO-8601 time,
deletes the records recorded before it instead."
  (let ((data (harness-commit-attribution--management
               "POST" "/management/prompts/delete"
               (if conversations
                   (list :conversations (append conversations nil))
                 (list :before before)))))
    (unless data
      (harness-commit-attribution--fail
       "the private notes service has no prompt management API at %s"
       (harness-commit-attribution--url)))
    (or (plist-get data :deleted) 0)))

(defun harness-commit-attribution--probe-service ()
  "Return a promise of (OK . DETAIL) for the private notes service.
A 404 for a made-up SHA means the service answered and the token was
accepted; there is no such note."
  (if (eq (harness-commit-attribution--mode) 'private-remote)
      (harness-resolved
       (cons :false "private-remote mode (Profile C) is a phase 5 follow-up"))
    (if (not (harness-commit-attribution--url))
        (harness-resolved (cons :false "no private notes URL is configured"))
    (harness-then
     (harness-commit-attribution--service-get (list (make-string 40 ?0)))
     (lambda (_) (cons t (format "the notes service answered at %s"
                                 (harness-commit-attribution--url))))
       (lambda (err)
         (cons :false (format "the notes service at %s did not answer: %s"
                              (harness-commit-attribution--url)
                              (harness-error-message err))))))))

(defun harness-commit-attribution--probe-management ()
  "Return a promise of (OK . DETAIL) for the prompt management API.
It asks the management status endpoint, so a service without the
management API is told apart from one that merely holds no prompt yet.
Only when prompt sync is on is it checked at all."
  (if (not (harness-commit-attribution--prompt-sync-p))
      (harness-resolved (cons t "prompt sync is off; no prompt record is stored"))
    (harness-then
     (harness-http-request-json
      (format "%s/management/status" (harness-commit-attribution--url))
      :headers (append (and (harness-commit-attribution--token)
                            (list (cons "X-API-Key" (harness-commit-attribution--token))))
                       '(("Accept" . "application/json")))
      :timeout 20)
     (lambda (_)
       (cons t (format "the prompt management API answered at %s"
                       (harness-commit-attribution--url))))
     (lambda (err)
       (cons :false (format "the prompt management API at %s did not answer: %s"
                            (harness-commit-attribution--url)
                            (harness-error-message err)))))))

(defun harness-commit-attribution--hook-file (repo)
  "Return the `pre-commit' hook file of REPO, a (ROOT . GIT-DIR) pair.
The hook lives in the repository's own common hooks directory, which a
linked worktree shares with its main checkout."
  (when repo
    (let* ((root (car repo))
           (common (harness-commit-attribution--git-sync
                    root "rev-parse" "--git-common-dir"))
           (dir (if (and (car common) (zerop (car common)))
                    (expand-file-name (string-trim (cdr common)) root)
                  (cdr repo))))
      (expand-file-name "hooks/pre-commit" dir))))

(harness-defmethod commit-attribution/status (&optional dir)
  "Return the state of private commit attribution for DIR, without probing.
The plist has `:enabled', `:repositories', `:program', `:version',
`:notes-mode', `:notes-url', `:notes-configured', `:prompt-sync',
`:queue', `:prompt-store', `:hook', `:vault', `:last-error' and
`:sandbox'.  `:prompt-store' says where a prompt record can be read
from, since the module keeps none of its own."
  (let* ((cwd (file-name-as-directory (expand-file-name (or dir default-directory))))
         (main (harness-commit-attribution--main cwd))
         (repo (and main (harness-commit-attribution--repo main)))
         (hook (harness-commit-attribution--hook-file repo)))
    (list :enabled (if (and main (harness-commit-attribution--selected-p main)) t :false)
          :repositories (harness-commit-attribution--recorded)
          :program (harness-commit-attribution--program)
          :program-path (harness-commit-attribution--program-path)
          :version (harness-commit-attribution--version)
          :notes-mode (symbol-name (harness-commit-attribution--mode))
          :notes-url (harness-commit-attribution--url)
          :notes-configured (if (harness-commit-attribution--notes-private-p) t :false)
          :prompt-sync (if (harness-commit-attribution--prompt-sync-p) t :false)
          :queue (cl-loop for v being the hash-values of harness-commit-attribution--queues
                          sum (length v))
          :prompt-store (if (harness-commit-attribution--prompt-sync-p)
                            (format "private notes service at %s (management API)"
                                    (harness-commit-attribution--url))
                          "off")
          :hook (if (and hook (file-exists-p hook)
                         (harness-commit-attribution--hook-p (harness-read-file hook)))
                    t :false)
          :hook-file hook
          :vault (if harness-commit-attribution-vault
                     "configured; encrypted vault is a phase 3 follow-up"
                   "not configured; phase 3 follow-up")
          :last-error (and main (gethash main harness-commit-attribution--last-error))
          :sandbox (harness-commit-attribution--sandbox-readable-dirs))))

;;;; The pre-commit hook

(defun harness-commit-attribution--hook ()
  "Return the text of the `pre-commit' safety net the harness installs.
The hook reads the attribution context the module writes under the
repository's git directory, checkpoints the staged and untracked paths
with git-ai, and always exits 0.  It refuses to run when git-ai or
python3 is missing, when there is no recent context, or when the
context names no private notes URL.  It gives git-ai a private
configuration of its own under the session's temporary directory, so a
sandbox without the user's `~/.git-ai' still cannot write git notes."
  (concat
   "#!/bin/sh\n"
   harness-commit-attribution-hook-marker "\n"
   "# Installed by the emacs-agent-harness, because the setting\n"
   "# harness-commit-attribution is on for this repository: it checkpoints\n"
   "# the staged paths with git-ai just before the commit, so a command that\n"
   "# edits and commits at once does not lose the attribution.  It always\n"
   "# exits 0, and it writes no note into this repository: git-ai is given an\n"
   "# HTTP notes backend pointing at the private service.\n"
   "command -v git-ai >/dev/null 2>&1 || exit 0\n"
   "command -v python3 >/dev/null 2>&1 || exit 0\n"
   "gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0\n"
   "ctx=\"$gitdir/harness-attribution/context.json\"\n"
   "[ -r \"$ctx\" ] || exit 0\n"
   "exec python3 - \"$ctx\" <<'HARNESS_ATTRIBUTION_PY'\n"
   "import json, os, subprocess, sys, time\n"
   "try:\n"
   "    ctx = json.load(open(sys.argv[1], encoding='utf-8'))\n"
   "except Exception:\n"
   "    sys.exit(0)\n"
   "root = ctx.get('repo_working_dir')\n"
   "home = ctx.get('git_ai_home')\n"
   "url = ctx.get('notes_url')\n"
   "model = ctx.get('model')\n"
   "conv = ctx.get('conversation_id')\n"
   "at = ctx.get('at')\n"
   "if not all(isinstance(v, str) and v for v in (root, home, url, model, conv)):\n"
   "    sys.exit(0)\n"
   "try:\n"
   "    if at and time.time() - float(at) > 3600:\n"
   "        sys.exit(0)\n"
   "except Exception:\n"
   "    pass\n"
   "confdir = os.path.join(home, '.git-ai')\n"
   "os.makedirs(confdir, mode=0o700, exist_ok=True)\n"
   "profile = {\n"
   "    'telemetry_oss': 'off',\n"
   "    'prompt_storage': 'local',\n"
   "    'exclude_prompts_in_repositories': ['*'],\n"
   "    'disable_auto_updates': True,\n"
   "    'disable_version_checks': True,\n"
   "    'api_base_url': url,\n"
   "    'notes_backend': {'kind': 'http', 'backend_url': url},\n"
   "}\n"
   "cfg = os.path.join(confdir, 'config.json')\n"
   "with open(cfg, 'w', encoding='utf-8') as f:\n"
   "    json.dump(profile, f)\n"
   "os.chmod(cfg, 0o600)\n"
   "def git(*args):\n"
   "    try:\n"
   "        return subprocess.run(['git', '-C', root] + list(args),\n"
   "                              capture_output=True).stdout\n"
   "    except Exception:\n"
   "        return b''\n"
   "paths = []\n"
   "for out in (git('diff', '--cached', '--name-only', '-z'),\n"
   "            git('ls-files', '--others', '--exclude-standard', '-z')):\n"
   "    for name in out.decode('utf-8', 'surrogateescape').split('\\0'):\n"
   "        if name:\n"
   "            paths.append(os.path.join(root, name))\n"
   "paths = sorted(set(paths))\n"
   "payload = {'type': 'ai_agent',\n"
   "           'repo_working_dir': root,\n"
   "           'edited_filepaths': paths,\n"
   "           'agent_name': 'emacs-agent-harness',\n"
   "           'model': model,\n"
   "           'conversation_id': conv}\n"
   "env = os.environ.copy()\n"
   "env['HOME'] = home\n"
   "env['GIT_AI_NOTES_BACKEND_KIND'] = 'http'\n"
   "env['GIT_AI_NOTES_BACKEND_URL'] = url\n"
   "env['GIT_AI_API_BASE_URL'] = url\n"
   "try:\n"
   "    subprocess.run(['git-ai', 'checkpoint', 'agent-v1', '--hook-input', 'stdin'],\n"
   "                   input=json.dumps(payload).encode('utf-8'), cwd=root, env=env,\n"
   "                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
   "except Exception:\n"
   "    pass\n"
   "sys.exit(0)\n"
   "HARNESS_ATTRIBUTION_PY\n"
   "exit 0\n"))

(defun harness-commit-attribution--hook-p (text)
  "Non-nil when TEXT is the `pre-commit' hook the harness wrote."
  (and (stringp text)
       (string-match-p (concat "\\`#![^\n]*\n"
                               (regexp-quote harness-commit-attribution-hook-marker))
                       text)))

(defun harness-commit-attribution--note-once (root fmt &rest args)
  "Log FMT with ARGS about ROOT's hook, once per repository."
  (unless (gethash root harness-commit-attribution--noted)
    (puthash root t harness-commit-attribution--noted)
    (apply #'harness-log 'info (concat "commit-attribution: " fmt) args)))

(defun harness-commit-attribution--hook-dirs (root)
  "Return a promise of (HOOKS . OWN) for the repository at ROOT."
  (harness-then
   (harness-worktree--git root "rev-parse" "--git-path" "hooks" "--git-common-dir")
   (lambda (output)
     (let* ((lines (split-string output "\n" t))
            (hooks (expand-file-name (string-trim (or (car lines) "hooks")) root))
            (common (expand-file-name (string-trim (or (cadr lines) ".git")) root)))
       (cons hooks (expand-file-name "hooks" common))))))

(defun harness-commit-attribution--write-hook (file root verb)
  "Write the harness's hook to FILE, mode 0755, and log VERB for ROOT."
  (harness-write-file-atomically file (harness-commit-attribution--hook))
  (set-file-modes file #o755)
  (harness-log 'info "commit-attribution: %s the pre-commit hook in %s"
               verb (abbreviate-file-name root)))

(defun harness-commit-attribution--install (root)
  "Install the harness's `pre-commit' hook in the repository at ROOT.
The hook goes into the hooks directory git resolves for ROOT, and only
when that is the repository's own `hooks' directory: a `core.hooksPath'
elsewhere, or a hook somebody else wrote, is left alone.  Return a
promise of non-nil when this call wrote the hook."
  (if (file-remote-p root)
      (harness-resolved nil)
    (harness-then
     (harness-commit-attribution--hook-dirs root)
     (lambda (dirs)
       (let ((hooks (car dirs)))
         (cond
          ((not (harness-worktree--same-path-p hooks (cdr dirs)))
           (harness-commit-attribution--note-once
            root "leaving the pre-commit hook of %s alone: core.hooksPath puts the hooks in %s"
            (abbreviate-file-name root) (abbreviate-file-name hooks))
           nil)
          (t
           (let ((file (expand-file-name "pre-commit" hooks)))
             (if (file-exists-p file)
                 (let ((existing (harness-read-file file)))
                   (cond
                    ((not (harness-commit-attribution--hook-p existing))
                     (harness-commit-attribution--note-once
                      root "leaving the pre-commit hook of %s alone: it is not the harness's"
                      (abbreviate-file-name root))
                     nil)
                    ((and (string= existing (harness-commit-attribution--hook))
                          (file-executable-p file))
                     (harness-commit-attribution--installed-in root)
                     nil)
                    (t
                     (harness-commit-attribution--write-hook file root "updated")
                     (harness-commit-attribution--installed-in root)
                     t)))
               (harness-commit-attribution--write-hook file root "installed")
               (harness-commit-attribution--installed-in root)
               t)))))))))

(defun harness-commit-attribution--remove (root)
  "Remove the harness's `pre-commit' hook from the repository at ROOT.
Only a hook carrying the harness's marker goes, and only from the
repository's own hooks directory.  Return a promise of `removed',
`foreign', `hooks-path' or `none'."
  (harness-then
   (harness-commit-attribution--hook-dirs root)
   (lambda (dirs)
     (let ((file (expand-file-name "pre-commit" (cdr dirs))))
       (cond
        ((and (file-exists-p file)
              (harness-commit-attribution--hook-p (harness-read-file file)))
         (delete-file file)
         (harness-log 'info "commit-attribution: removed the pre-commit hook from %s"
                      (abbreviate-file-name root))
         'removed)
        ((file-exists-p file) 'foreign)
        ((not (harness-worktree--same-path-p (car dirs) (cdr dirs))) 'hooks-path)
        (t 'none))))))

;;;; The record of repositories

(defun harness-commit-attribution--record-path ()
  "Return the file naming the repositories that have the harness's hook."
  (expand-file-name harness-commit-attribution--record-file harness-state-directory))

(defun harness-commit-attribution--recorded ()
  "Return the main checkouts of the repositories that have the harness's hook."
  (let ((data (ignore-errors
                (harness-json-parse (harness-read-file
                                     (harness-commit-attribution--record-path))))))
    (and (listp data)
         (delete-dups
          (mapcar #'harness-commit-attribution--canonical
                  (cl-remove-if-not #'stringp data))))))

(defun harness-commit-attribution--write-record (mains)
  "Write MAINS as the record of repositories with the harness's hook."
  (harness-write-file-atomically (harness-commit-attribution--record-path)
                                 (harness-json-encode
                                  (harness-json-array mains))))

(defun harness-commit-attribution--note (main)
  "Record that the repository at MAIN has the harness's hook."
  (let ((main (harness-commit-attribution--canonical main))
        (mains (harness-commit-attribution--recorded)))
    (unless (member main mains)
      (harness-commit-attribution--write-record (append mains (list main))))))

(defun harness-commit-attribution--forget (main)
  "Drop the repository at MAIN from the record."
  (let ((main (harness-commit-attribution--canonical main))
        (mains (harness-commit-attribution--recorded)))
    (when (member main mains)
      (harness-commit-attribution--write-record (remove main mains)))))

(defun harness-commit-attribution--installed-in (root)
  "Note that the repository at ROOT has the harness's hook now."
  (harness-commit-attribution--note root)
  (puthash (harness-commit-attribution--canonical root) t
           harness-commit-attribution--installed))

(defun harness-commit-attribution--install-logged (main)
  "Install the hook in MAIN's repository; log a failure rather than signal it."
  (harness-then
   (condition-case err (harness-commit-attribution--install main)
     (error (harness-rejected err)))
   (lambda (wrote) wrote)
   (lambda (err)
     (harness-log 'warn
                  "commit-attribution: could not install the pre-commit hook in %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     nil)))

(defun harness-commit-attribution--remove-logged (main)
  "Remove the harness's hook from MAIN's repository and drop MAIN from the record."
  (remhash main harness-commit-attribution--installed)
  (harness-then
   (condition-case err (harness-commit-attribution--remove main)
     (error (harness-rejected err)))
   (lambda (outcome)
     (harness-commit-attribution--forget main)
     outcome)
   (lambda (err)
     (harness-log 'warn
                  "commit-attribution: could not remove the pre-commit hook from %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     nil)))

;;;; When it acts

(defun harness-commit-attribution--consider (dir dirs &optional always)
  "Install the hook in the repository DIR lies in, when it is selected.
DIRS are the directories the event at hand names.  Unless ALWAYS, a
repository found installed since the last full pass is skipped."
  (when-let* ((main (harness-commit-attribution--main dir)))
    (unless (and (not always) (gethash main harness-commit-attribution--installed))
      (when (harness-commit-attribution--selected-p main dirs)
        (harness-commit-attribution--install-logged main)))))

(defun harness-commit-attribution--settle (main dirs recorded)
  "Install or remove the hook of MAIN's repository, as the setting says."
  (condition-case err
      (cond
       ((not (harness-commit-attribution--repository-p main))
        (when recorded (harness-commit-attribution--forget main))
        (harness-resolved nil))
       ((harness-commit-attribution--selected-p main dirs)
        (harness-commit-attribution--install-logged main))
       (recorded (harness-commit-attribution--remove-logged main))
       (t (harness-resolved nil)))
    (error
     (harness-log 'warn "commit-attribution: could not look at %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     (harness-resolved nil))))

(defun harness-commit-attribution--pass (&optional dirs)
  "Bring the hook of every repository the harness knows in line with the setting.
Return a promise that never rejects."
  (clrhash harness-commit-attribution--installed)
  (clrhash harness-commit-attribution--session-cache)
  (let* ((harness-commit-attribution--pass-memo (make-hash-table :test 'equal))
         (work (harness-commit-attribution--work-dirs))
         (harness-commit-attribution--pass-work-dirs (list work))
         (recorded (harness-commit-attribution--recorded))
         (known (mapcar #'harness-commit-attribution--canonical
                        (and (fboundp 'harness-worktree--known-roots)
                             (harness-worktree--known-roots))))
         (candidates (delete-dups
                      (delq nil (append known
                                        (mapcar #'harness-commit-attribution--main
                                                (append dirs work))
                                        recorded)))))
    (harness-all
     (mapcar (lambda (main)
               (harness-commit-attribution--settle main dirs (member main recorded)))
             candidates))))

(defun harness-commit-attribution--safely (what fn &rest args)
  "Call FN with ARGS for WHAT while the module is ready; log what it signals."
  (when (harness-module-ready-p 'commit-attribution)
    (condition-case err
        (apply fn args)
      (error (harness-log 'warn "commit-attribution: %s: %s" what
                          (harness-error-message err))
             nil))))

;;;; Attribution epochs and prompt records

(defun harness-commit-attribution--dir ()
  "Return the module's own directory under the state directory."
  (expand-file-name harness-commit-attribution--directory harness-state-directory))

(defun harness-commit-attribution--redact (text)
  "Return (TEXT . REDACTED) for TEXT with secrets masked when the module is there."
  (if (and (fboundp 'harness-secrets-mask-text) (stringp text))
      (let ((result (harness-secrets-mask-text text)))
        (cons (car result) (and (cdr result) t)))
    (cons text nil)))

(defun harness-commit-attribution--prompt-text (node)
  "Return the text of NODE, a user message, or nil."
  (let ((content (plist-get node :content)))
    (cond ((and (stringp content) (not (string-empty-p content))) content)
          ((listp content)
           (let ((text (mapconcat (lambda (block)
                                    (or (plist-get block :text) ""))
                                  content "\n")))
             (unless (string-empty-p text) text))))))

(defun harness-commit-attribution--prompt-hash (text)
  "Return the SHA-256 of TEXT as the service's record spells it, or nil."
  (when (and (stringp text) (not (string-empty-p text)))
    (secure-hash 'sha256 (encode-coding-string text 'utf-8))))

(defun harness-commit-attribution--prompt-record (text conversation model session turn repo)
  "Return the private service's record for CONVERSATION with prompt TEXT.
TEXT is redacted and shortened as the prompt settings say; MODEL is
the model of the epoch, SESSION and TURN are the harness session and
user node, and REPO is the repository id.  The hash is of the redacted
text, never the original, so the service never receives a fingerprint
of a secret-bearing prompt."
  (let* ((masked (harness-commit-attribution--redact (or text "")))
         (clean (car masked))
         (mode (or harness-commit-attribution-prompt-mode 'excerpt))
         (kept (pcase mode
                 ('full clean)
                 ('hash nil)
                 (_ (if (> (length clean) harness-commit-attribution-excerpt-chars)
                        (harness-truncate-end clean harness-commit-attribution-excerpt-chars)
                      clean)))))
    (list :schema "harness-attribution/1"
          :repo repo
          :conversation conversation
          :session session
          :turn turn
          :model model
          :provider (harness-commit-attribution--provider model)
          :prompt kept
          :prompt_sha256 (harness-commit-attribution--prompt-hash clean)
          :at (harness-commit-attribution--now)
          :device (or harness-commit-attribution-device (system-name))
          :redacted (if (cdr masked) t :false)
          :prompt_mode (symbol-name mode))))

(defun harness-commit-attribution--split-conversation (conversation)
  "Return (SESSION TURN MODEL) parsed from CONVERSATION, or nil.
A system epoch (\"system@ACTION\") gives nil."
  (when (and (stringp conversation)
             (not (string-prefix-p "system@" conversation))
             (string-match "\\`\\([^@]+\\)@\\([^@]+\\)@\\(.+\\)\\'" conversation))
    (list (match-string 1 conversation)
          (match-string 2 conversation)
          (match-string 3 conversation))))

(defun harness-commit-attribution--conversation (session prompt-id model)
  "Return the attribution epoch id for SESSION, PROMPT-ID and MODEL.
PROMPT-ID nil gives the system epoch `system@action', ACTion being
MODEL's last word only in callers that pass one; this function's
`system@' form is completed by
`harness-commit-attribution--system-conversation'."
  (if (and (stringp prompt-id) (not (string-empty-p prompt-id)))
      (format "%s@%s@%s" session prompt-id (or model "unknown"))
    (format "system@%s" (or model "unknown"))))

(defun harness-commit-attribution--system-conversation (action)
  "Return the synthetic system epoch for ACTION."
  (format "system@%s" action))

(defun harness-commit-attribution--session-model (sid)
  "Return the model session SID is on, or nil."
  (when (and (fboundp 'harness-method-exists-p)
             (harness-method-exists-p 'session/get))
    (ignore-errors (plist-get (harness-call 'session/get sid) :model))))

(defun harness-commit-attribution--session-info (sid)
  "Return the cached attribution state of session SID, computing it once.
A plist `:active', `:root', `:git-dir', `:main', `:cwd', `:model',
`:parent-id'."
  (let ((cached (gethash sid harness-commit-attribution--session-cache 'unknown)))
    (if (not (eq cached 'unknown))
        cached
      (let* ((session (and (harness-method-exists-p 'session/get)
                           (ignore-errors (harness-call 'session/get sid))))
             (cwd (plist-get session :cwd))
             (main (and cwd (harness-commit-attribution--main cwd)))
             (repo (and cwd (harness-commit-attribution--repo cwd)))
             (parent (plist-get session :parent-id))
             (active (and session cwd repo main
                          (not (plist-get session :host))
                          (harness-commit-attribution--selected-p main (list cwd))
                          (or harness-commit-attribution-include-subagents (not parent))
                          (harness-commit-attribution--program-path)
                          (harness-commit-attribution--checkpoint-allowed-p)))
             (value (list :active (if active t :false)
                          :root (car repo) :git-dir (cdr repo) :main main
                          :cwd cwd :model (plist-get session :model)
                          :parent-id parent)))
        (puthash sid value harness-commit-attribution--session-cache)
        value))))

(defun harness-commit-attribution--active-p (sid)
  "Non-nil when the module may checkpoint for session SID."
  (and (stringp sid)
       (harness-json-true-p (plist-get (harness-commit-attribution--session-info sid)
                                       :active))))

(defun harness-commit-attribution--turn (sid)
  "Return the prompt context of SID's running turn, or nil."
  (gethash sid harness-commit-attribution--turns))

(defun harness-commit-attribution--context-for (sid &optional action)
  "Return the attribution context of session SID for ACTION.
The plist has `:model', `:conversation', `:prompt-id', `:prompt' and
`:root'.  It uses the running turn's prompt when there is one, and a
system epoch otherwise."
  (let* ((info (harness-commit-attribution--session-info sid))
         (turn (harness-commit-attribution--turn sid))
         (model (or (plist-get turn :model)
                    (plist-get info :model)
                    "unknown"))
         (prompt-id (plist-get turn :id))
         (prompt (plist-get turn :text))
         (conversation (if prompt-id
                           (harness-commit-attribution--conversation sid prompt-id model)
                         (harness-commit-attribution--system-conversation action))))
    (list :model model :conversation conversation
          :prompt-id prompt-id :prompt prompt :root (plist-get info :root)
          :session sid)))

;;;; Checkpoints

(defun harness-commit-attribution--payload (context kind &optional paths command tool-id)
  "Return the git-ai agent-v1 payload for CONTEXT, KIND, PATHS and COMMAND.
KIND is `edit', `shell-pre' or `shell-post'.  TOOL-ID is the call id
git-ai uses to pair a pre and post shell event."
  (let ((type (pcase kind
                ('edit "ai_agent")
                ('shell-pre "pre_shell_command")
                ('shell-post "post_shell_command")
                (_ "ai_agent"))))
    (append
     (list :type type
           :repo_working_dir (plist-get context :root)
           :agent_name harness-commit-attribution-agent-name
           :model (plist-get context :model)
           :conversation_id (plist-get context :conversation))
     (when (eq kind 'edit)
       (list :edited_filepaths (harness-json-array (or paths nil))))
     (when (memq kind '(shell-pre shell-post))
       (list :tool_use_id tool-id
             :command command)))))

(defun harness-commit-attribution--queue-idle-p ()
  "Non-nil when no checkpoint is queued or running."
  (and (zerop (hash-table-count harness-commit-attribution--running))
       (cl-every (lambda (q) (null q))
                 (cl-loop for k being the hash-keys of harness-commit-attribution--queues
                          collect (gethash k harness-commit-attribution--queues)))))

(defun harness-commit-attribution--notify-idle ()
  "Resolve the waiters of `harness-commit-attribution--flush' when idle."
  (when (harness-commit-attribution--queue-idle-p)
    (let ((waiters (prog1 harness-commit-attribution--flush-waiters
                     (setq harness-commit-attribution--flush-waiters nil))))
      (dolist (resolve waiters) (funcall resolve t)))))

(defun harness-commit-attribution--flush ()
  "Return a promise resolved when every checkpoint queue is idle."
  (if (harness-commit-attribution--queue-idle-p)
      (harness-resolved t)
    (harness-with-promise (resolve reject)
      (ignore reject)
      (push resolve harness-commit-attribution--flush-waiters))))

(defun harness-commit-attribution--pump (repo)
  "Run the next checkpoint job of REPO, if none is running there."
  (unless (gethash repo harness-commit-attribution--running)
    (let ((queue (gethash repo harness-commit-attribution--queues)))
      (if (null queue)
          (progn (remhash repo harness-commit-attribution--queues)
                 (harness-commit-attribution--notify-idle))
        (let* ((job (car queue))
               (payload (plist-get job :payload))
               (program (plist-get job :program))
               (env (plist-get job :env)))
          (puthash repo (cdr queue) harness-commit-attribution--queues)
          (puthash repo t harness-commit-attribution--running)
          (let ((promise
                 (condition-case err
                     (harness-run-command
                      (list program "checkpoint" "agent-v1" "--hook-input" "stdin")
                      :cwd repo :timeout harness-commit-attribution--checkpoint-timeout
                      :stdin payload :env env :name "harness-attribution-checkpoint")
                   (error (harness-rejected err)))))
            (harness-then
             promise
             (lambda (result)
               (remhash repo harness-commit-attribution--running)
               (let ((exit (plist-get result :exit))
                     (stderr (string-trim (or (plist-get result :stderr) ""))))
                 (if (and (numberp exit) (zerop exit))
                     (progn (remhash repo harness-commit-attribution--last-error)
                            (harness-log 'debug
                                         "commit-attribution: checkpoint in %s done"
                                         (abbreviate-file-name repo)))
                   (unless (gethash repo harness-commit-attribution--last-error)
                     (puthash repo t harness-commit-attribution--last-error)
                     (harness-log 'warn
                                  "commit-attribution: git-ai checkpoint failed in %s (%s): %s"
                                  (abbreviate-file-name repo) exit
                                  (if (string-empty-p stderr) "no message" stderr)))))
               (harness-commit-attribution--pump repo))
             (lambda (err)
               (remhash repo harness-commit-attribution--running)
               (unless (gethash repo harness-commit-attribution--last-error)
                 (puthash repo t harness-commit-attribution--last-error)
                 (harness-log 'warn
                              "commit-attribution: could not run git-ai in %s: %s"
                              (abbreviate-file-name repo) (harness-error-message err)))
               (harness-commit-attribution--pump repo)))))))))

(defun harness-commit-attribution--enqueue (context kind &optional paths command tool-id)
  "Queue a checkpoint of CONTEXT, KIND, PATHS and COMMAND.
Return nil when the module may not checkpoint, else the payload queued.
The job is per repository and preserves order; nothing waits for it."
  (when (harness-commit-attribution--checkpoint-allowed-p)
    (let* ((program (harness-commit-attribution--program-path))
           (root (plist-get context :root))
           (payload (harness-json-encode
                     (harness-commit-attribution--payload
                      context kind paths command tool-id))))
      (when (and program root)
        (let ((job (list :payload payload :program program
                         :env (harness-commit-attribution--checkpoint-env))))
          (puthash root (append (gethash root harness-commit-attribution--queues)
                                (list job))
                   harness-commit-attribution--queues)
          (harness-commit-attribution--pump root)
          payload)))))

(defun harness-commit-attribution--upload-prompt (conversation record)
  "Store CONVERSATION's redacted RECORD in the private service, once.
RECORD has already run through `harness-secrets', and its hash is of
the redacted text.  Nothing is sent unless
`harness-commit-attribution-prompt-sync' is on, the notes URL is
private, and the record has prompt text or a hash.  A failure is
logged once and retried by a later checkpoint of the conversation."
  (when (and (harness-commit-attribution--prompt-sync-p)
             (stringp conversation)
             (or (and (stringp (plist-get record :prompt))
                      (not (string-empty-p (plist-get record :prompt))))
                 (plist-get record :prompt_sha256))
             (not (gethash conversation harness-commit-attribution--prompts-sent))
             (not (gethash conversation harness-commit-attribution--prompts-sending)))
    (let ((hash (plist-get record :prompt_sha256)))
      (puthash conversation t harness-commit-attribution--prompts-sending)
      (let ((promise
             (condition-case err
                 (harness-http-request-json
                  (format "%s/management/prompts/upload"
                          (harness-commit-attribution--url))
                  :method "POST"
                  :headers (append (and (harness-commit-attribution--token)
                                        (list (cons "X-API-Key"
                                                    (harness-commit-attribution--token))))
                                   '(("Accept" . "application/json")))
                  :json (list :entries
                              (list (list :conversation conversation :record record)))
                  :timeout 20)
               (error (harness-rejected err)))))
        (harness-then
         promise
         (lambda (_result)
           (remhash conversation harness-commit-attribution--prompts-sending)
           (remhash conversation harness-commit-attribution--prompt-error)
           (when hash
             (puthash conversation hash harness-commit-attribution--prompts-sent))
           (harness-log 'debug "commit-attribution: stored the prompt of %s"
                        conversation)
           nil)
         (lambda (err)
           (remhash conversation harness-commit-attribution--prompts-sending)
           (unless (gethash conversation harness-commit-attribution--prompt-error)
             (puthash conversation t harness-commit-attribution--prompt-error)
             (harness-log 'warn
                          "commit-attribution: could not store the prompt of %s: %s"
                          conversation (harness-error-message err)))
           nil))))))

(defun harness-commit-attribution--record-prompt (context)
  "Store CONTEXT's prompt in the private service when prompt sync is on.
The module keeps no copy of its own.  Nothing is stored for a system
epoch or when the prompt is empty."
  (when (and (plist-get context :prompt-id)
             (plist-get context :prompt))
    (let* ((conversation (plist-get context :conversation))
           (parsed (harness-commit-attribution--split-conversation conversation))
           (repo (harness-commit-attribution--repo-id
                  (or (plist-get context :root) "")))
           (record (harness-commit-attribution--prompt-record
                    (plist-get context :prompt) conversation (plist-get context :model)
                    (or (car parsed) (plist-get context :session))
                    (plist-get context :prompt-id) repo)))
      (harness-commit-attribution--upload-prompt conversation record))))

(defun harness-commit-attribution--checkpoint-edit (context paths)
  "Checkpoint PATHS as an AI edit of CONTEXT."
  (when paths
    (harness-commit-attribution--record-prompt context)
    (harness-commit-attribution--enqueue context 'edit paths)))

(defun harness-commit-attribution--checkpoint-shell (context kind command tool-id)
  "Checkpoint the shell event KIND of CONTEXT with COMMAND and TOOL-ID."
  (harness-commit-attribution--record-prompt context)
  (harness-commit-attribution--enqueue context kind nil command tool-id))

(defun harness-commit-attribution--input-paths (context input)
  "Return the absolute paths INPUT names, within CONTEXT's root.
It looks at `:path', `:file_path', `:filePath' and a list under
`:files' or `:paths', each an entry or a (:path PATH) plist."
  (let* ((root (plist-get context :root))
         (root (and root (file-name-as-directory (expand-file-name root))))
         (values (append (list (plist-get input :path)
                               (plist-get input :file_path)
                               (plist-get input :filePath))
                         (let ((files (or (plist-get input :files)
                                          (plist-get input :paths))))
                           (when (listp files)
                             (mapcar (lambda (f)
                                       (if (stringp f) f (or (plist-get f :path)
                                                             (plist-get f :file_path))))
                                     files)))))
         (resolved
          (and root
               (delq nil
                     (mapcar
                      (lambda (path)
                        (when (and (stringp path) (not (string-empty-p path)))
                          (if (file-name-absolute-p path)
                              (and (harness-path-within-p root path) path)
                            (let ((abs (expand-file-name path root)))
                              (and (harness-path-within-p root abs) abs)))))
                      values)))))
    (delete-dups resolved)))

(defun harness-commit-attribution--changed-paths (root)
  "Return the absolute changed and untracked paths in ROOT.
Read with `git status --porcelain -z', so a rename counts its new name."
  (let* ((root (and root (file-name-as-directory (expand-file-name root))))
         (result (and root
                      (harness-commit-attribution--git-sync
                       root "status" "--porcelain=v1" "-z" "--untracked-files=all")))
         (status (car result))
         (output (cdr result))
         (parts (and status (zerop status) (split-string output "\0")))
         (paths nil))
    (while parts
      (let ((entry (pop parts)))
        (unless (string-empty-p entry)
          (let ((state (substring entry 0 (min 2 (length entry))))
                (name (substring entry (min 3 (length entry)))))
            (when (and (string-match-p "[RC]" state))
              ;; A rename or copy is followed by its old name.
              (pop parts))
            (unless (string-empty-p name)
              (push (expand-file-name name root) paths))))))
    (delete-dups (nreverse paths))))

(defun harness-commit-attribution--commit-command-p (command)
  "Non-nil when COMMAND may run `git commit'."
  (and (stringp command)
       (string-match-p "\\bgit\\b[^;&|\n]*\\b\\(commit\\|merge\\|cherry-pick\\|rebase\\|am\\)\\b"
                       command)
       t))

(defun harness-commit-attribution--write-context (context command)
  "Write the pre-commit hook context of CONTEXT before COMMAND.
Nothing is written when the context names no private notes URL or no
git directory.  The file is mode 600 and lies under the repository's
git directory, so it is never committed."
  (when-let* ((root (plist-get context :root))
              (repo (harness-commit-attribution--repo root))
              (git-dir (cdr repo))
              (url (harness-commit-attribution--url))
              (session (plist-get context :session)))
    (let* ((info (harness-commit-attribution--session-info session))
           (tmp (and (harness-method-exists-p 'session/tmp-dir)
                     (ignore-errors (harness-call 'session/tmp-dir session))))
           (home (and tmp (expand-file-name "harness-git-ai-home"
                                            (file-name-as-directory tmp))))
           (file (expand-file-name harness-commit-attribution--context-file
                                   (expand-file-name git-dir root)))
           (data (list :schema "harness-attribution-context/1"
                       :repo_working_dir root
                       :git_ai_home home
                       :notes_url url
                       :agent_name harness-commit-attribution-agent-name
                       :model (plist-get context :model)
                       :conversation_id (plist-get context :conversation)
                       :command command
                       :at (float-time))))
      (if (not home)
          (harness-log 'debug
                       "commit-attribution: no session temporary directory for %s; the pre-commit hook has no private profile"
                       session)
        (harness-ensure-directory (file-name-directory file))
        (harness-write-file-atomically file (harness-json-encode data))
        (set-file-modes file #o600)
        (let ((config-dir (expand-file-name ".git-ai" home)))
          (harness-ensure-directory config-dir)
          (harness-write-file-atomically
           (expand-file-name "config.json" config-dir)
           (harness-json-encode
            (list :telemetry_oss "off"
                  :prompt_storage "local"
                  :exclude_prompts_in_repositories (harness-json-array '("*"))
                  :disable_auto_updates t
                  :disable_version_checks t
                  :api_base_url url
                  :notes_backend (list :kind "http" :backend_url url))))
          (set-file-modes (expand-file-name "config.json" config-dir) #o600))
        (ignore info)))))

;;;; Tool and turn events

(defun harness-commit-attribution--on-node-added (sid node)
  "Remember NODE when it is a user message that may open SID's next turn."
  (harness-commit-attribution--safely
   "a new transcript node"
   (lambda ()
     (when (and (harness-commit-attribution--active-p sid)
                (eq (let ((kind (plist-get node :kind)))
                      (if (stringp kind) (intern kind) kind))
                    'user)
                (not (harness-json-true-p (plist-get (plist-get node :meta) :steering))))
       (let ((text (harness-commit-attribution--prompt-text node)))
         (when text
           (puthash sid (list :id (plist-get node :id) :text text
                              :at (or (plist-get node :ts) (float-time)))
                    harness-commit-attribution--prompts)))))))

(defun harness-commit-attribution--on-turn-started (sid)
  "Make the latest user message of SID the prompt of its running turn."
  (harness-commit-attribution--safely
   "a turn's start"
   (lambda ()
     (when (harness-commit-attribution--active-p sid)
       (let ((prompt (gethash sid harness-commit-attribution--prompts)))
         (remhash sid harness-commit-attribution--prompts)
         (when prompt
           (puthash sid (list :id (plist-get prompt :id)
                              :text (plist-get prompt :text)
                              :model (or (harness-commit-attribution--session-model sid)
                                         "unknown")
                              :at (plist-get prompt :at))
                    harness-commit-attribution--turns)))))))

(defun harness-commit-attribution--clear-session (sid)
  "Forget the transient attribution state of SID."
  (remhash sid harness-commit-attribution--prompts)
  (remhash sid harness-commit-attribution--turns)
  (remhash sid harness-commit-attribution--session-cache)
  (let (keys)
    (maphash (lambda (key _value)
               (when (equal (car-safe key) sid) (push key keys)))
             harness-commit-attribution--calls)
    (dolist (key keys) (remhash key harness-commit-attribution--calls)))
  (let (keys)
    (maphash (lambda (key _value)
               (when (equal (car-safe key) sid) (push key keys)))
             harness-commit-attribution--seen-results)
    (dolist (key keys) (remhash key harness-commit-attribution--seen-results))))

(defun harness-commit-attribution--on-turn-ended (sid _reason)
  "Clear SID's active epoch when its turn ends."
  (harness-commit-attribution--safely
   "a turn's end"
   (lambda ()
     (remhash sid harness-commit-attribution--turns)
     (remhash sid harness-commit-attribution--prompts))))

(defun harness-commit-attribution--on-tool-call (sid node)
  "Remember the model and epoch of NODE, a tool call of SID."
  (harness-commit-attribution--safely
   "a tool call"
   (lambda ()
     (when (harness-commit-attribution--active-p sid)
       (let* ((call-id (plist-get node :call-id))
              (model (or (plist-get (plist-get node :meta) :model)
                         (harness-commit-attribution--session-model sid)
                         "unknown"))
              (turn (harness-commit-attribution--turn sid))
              (prompt-id (plist-get turn :id))
              (conversation (if prompt-id
                                (harness-commit-attribution--conversation
                                 sid prompt-id model)
                              (harness-commit-attribution--system-conversation
                               (or (plist-get node :tool) "tool"))))
              (info (harness-commit-attribution--session-info sid)))
         (when call-id
           (puthash (cons sid call-id)
                    (list :model model :conversation conversation
                          :prompt-id prompt-id :prompt (plist-get turn :text)
                          :root (plist-get info :root) :session sid
                          :input (plist-get node :input))
                    harness-commit-attribution--calls)))))))

(defun harness-commit-attribution--call-context (sid call)
  "Return the attribution context for CALL of SID, storing it when new.
The model is the tool-call node's when there is one, not the session's
current model; a call outside a turn gets a system epoch."
  (let* ((call-id (or (plist-get call :id) (plist-get call :call-id)))
         (key (and call-id (cons sid call-id)))
         (stored (and key (gethash key harness-commit-attribution--calls)))
         (info (harness-commit-attribution--session-info sid))
         (turn (harness-commit-attribution--turn sid))
         (model (or (plist-get stored :model)
                    (harness-commit-attribution--session-model sid)
                    "unknown"))
         (prompt-id (or (plist-get stored :prompt-id) (plist-get turn :id)))
         (prompt (or (plist-get stored :prompt) (plist-get turn :text)))
         (conversation (or (plist-get stored :conversation)
                           (if prompt-id
                               (harness-commit-attribution--conversation
                                sid prompt-id model)
                             (harness-commit-attribution--system-conversation
                              (or (plist-get call :name) "tool")))))
         (context (list :model model :conversation conversation
                        :prompt-id prompt-id :prompt prompt
                        :root (or (plist-get stored :root) (plist-get info :root))
                        :session sid)))
    (when key
      (puthash key (plist-put (copy-sequence context) :input
                              (or (plist-get call :input)
                                  (plist-get stored :input)))
               harness-commit-attribution--calls))
    context))

(defun harness-commit-attribution--write-tool-p (call)
  "Non-nil when CALL writes files."
  (let* ((name (plist-get call :name))
         (known (member name '("write_file" "edit_file" "multi_edit" "Write" "Edit"
                               "NotebookEdit" "apply_patch")))
         (spec (and (not known) (fboundp 'harness-method-exists-p)
                    (harness-method-exists-p 'tools/get)
                    (ignore-errors (harness-call 'tools/get name)))))
    (or known
        (and spec (eq (let ((kind (plist-get spec :kind)))
                        (if (stringp kind) (intern kind) kind))
                      'write)))))

(defun harness-commit-attribution--on-tools-started (sid call)
  "Checkpoint what CALL of SID may have changed before it runs."
  (harness-commit-attribution--safely
   "a tool's start"
   (lambda ()
     (when (and (harness-commit-attribution--active-p sid)
                (equal (plist-get call :name) "bash"))
       (let* ((context (harness-commit-attribution--call-context sid call))
              (command (plist-get (plist-get call :input) :command))
              (root (plist-get context :root))
              (call-id (or (plist-get call :id) (plist-get call :call-id))))
         (when (harness-commit-attribution--commit-command-p command)
           ;; Edits made before the command count: checkpoint them before
           ;; the command runs, then the pre/post shell pair covers what
           ;; the command itself writes.
           (when root
             (let ((paths (harness-commit-attribution--changed-paths root)))
               (when paths (harness-commit-attribution--checkpoint-edit context paths))))
           (harness-commit-attribution--write-context context command))
         (when call-id
           (harness-commit-attribution--checkpoint-shell
            context 'shell-pre command call-id)))))))

(defun harness-commit-attribution--on-tools-finished (sid call result)
  "Checkpoint what CALL of SID wrote, after it finished with RESULT."
  (harness-commit-attribution--safely
   "a tool's result"
   (lambda ()
     (when (harness-commit-attribution--active-p sid)
       (let* ((call-id (or (plist-get call :id) (plist-get call :call-id)))
              (name (plist-get call :name))
              (context (harness-commit-attribution--call-context sid call))
              (failed (harness-json-true-p (plist-get result :is-error))))
         (when call-id
           (puthash (cons sid call-id) t harness-commit-attribution--seen-results))
         (cond
          ((equal name "bash")
           (harness-commit-attribution--checkpoint-shell
            context 'shell-post (plist-get (plist-get call :input) :command) call-id))
          ((and (not failed) (harness-commit-attribution--write-tool-p call))
           (let* ((input (or (plist-get call :input) (plist-get context :input)))
                  (paths (harness-commit-attribution--input-paths context input)))
             (unless paths
               (when-let* ((root (plist-get context :root)))
                 (setq paths (harness-commit-attribution--changed-paths root))))
             (harness-commit-attribution--checkpoint-edit context paths)))))))))

(defun harness-commit-attribution--on-agent-tool-result (sid node)
  "Checkpoint NODE's call when `tools/finished' did not see it.
That covers a provider's own tool call that never ran through the
harness's tool registry; the model and input come from the tool-call
node kept in `harness-commit-attribution--calls'."
  (harness-commit-attribution--safely
   "a tool result"
   (lambda ()
     (when (harness-commit-attribution--active-p sid)
       (let* ((call-id (plist-get node :call-id))
              (key (and call-id (cons sid call-id)))
              (context (and key (gethash key harness-commit-attribution--calls))))
         (when (and context call-id
                    (not (gethash key harness-commit-attribution--seen-results))
                    (not (harness-json-true-p (plist-get node :is-error))))
           (let ((paths (harness-commit-attribution--input-paths
                         context (plist-get context :input))))
             (when paths (harness-commit-attribution--checkpoint-edit context paths)))))))))

;;;; Session and repository events

(defun harness-commit-attribution--on-worktree-created (root worktree)
  "Install the hook in the repository of ROOT, which got WORKTREE, if selected."
  (harness-commit-attribution--safely
   "a new worktree"
   (lambda ()
     (harness-commit-attribution--consider
      root (delq nil (list root (plist-get worktree :path))) t))))

(defun harness-commit-attribution--on-session-created (id session)
  "Install the hook in the repository SESSION works in, when selected."
  (harness-commit-attribution--safely
   "a new session"
   (lambda ()
     (remhash id harness-commit-attribution--session-cache)
     (let ((cwd (plist-get session :cwd)))
       (harness-commit-attribution--consider cwd (list cwd))))))

(defun harness-commit-attribution--on-session-moved (id _old new)
  "Install the hook in the repository of NEW, where session ID moved."
  (harness-commit-attribution--safely
   "a session's move"
   (lambda ()
     (harness-commit-attribution--clear-session id)
     (harness-commit-attribution--consider new (list new)))))

(defun harness-commit-attribution--on-session-deleted (id _session)
  "Forget the transient attribution state of deleted session ID."
  (harness-commit-attribution--clear-session id))

(defun harness-commit-attribution--on-config-changed (key &optional _value _scope cwd)
  "Run a full pass when KEY, the option that changed, is this module's."
  (when (member (format "%s" key)
                '("harness-commit-attribution"
                  "harness-commit-attribution-notes-url"
                  "harness-commit-attribution-notes-mode"
                  "harness-commit-attribution-git-ai-program"))
    (clrhash harness-commit-attribution--session-cache)
    (harness-commit-attribution--safely
     "a change of the setting" #'harness-commit-attribution--pass
     (and (stringp cwd) (list cwd)))))

(defun harness-commit-attribution--on-started (&rest _)
  "Run a full pass, as the harness starts or reloads."
  (harness-commit-attribution--safely
   "the pass at start" #'harness-commit-attribution--pass))

;;;; Sandbox access

(defun harness-commit-attribution--active-p-in-any-repo-p ()
  "Non-nil when the setting is on for some repository the harness knows."
  (or (harness-commit-attribution--recorded)
      (cl-some (lambda (dir) (ignore-errors (harness-commit-attribution--on-at-p dir)))
               (harness-commit-attribution--work-dirs))))

(defun harness-commit-attribution--sandbox-readable-dirs ()
  "Return the directories sandboxed commands need to reach git-ai.
They are the program's directory and git-ai's state directory, mounted
read-only; the pre-commit hook gives git-ai a private home of its own
under the session's temporary directory."
  (delete-dups
   (delq nil
         (list (let ((path (harness-commit-attribution--program-path)))
                 (and path (file-name-directory path)))
               (and (file-directory-p harness-commit-attribution-git-ai-directory)
                    (file-name-as-directory harness-commit-attribution-git-ai-directory))))))

(defun harness-commit-attribution--sandbox-options (options &optional _session-id)
  "Add the git-ai directories to the sandbox OPTIONS as read-only.
It joins the `tools/sandbox-options' filter, so a bash command that
runs `git commit' can run the pre-commit hook.  A plist without
`:readable' gets one; a non-plist is left for the filter contract to
reject."
  (if (not (harness-commit-attribution--active-p-in-any-repo-p))
      options
    (let ((dirs (harness-commit-attribution--sandbox-readable-dirs)))
      (if (or (null dirs) (not (listp options)) (not (cl-evenp (length options))))
          options
        (plist-put (copy-sequence options) :readable
                   (delete-dups (append (plist-get options :readable) dirs)))))))

;;;; Reading notes

(defun harness-commit-attribution--note-fallback (root shas)
  "Return a promise of an alist of SHA -> note read with `git-ai show'.
Used when no notes service URL is configured.  A commit without a note
is left out."
  (let ((program (harness-commit-attribution--program-path)))
    (harness-all
     (mapcar
      (lambda (sha)
        (harness-then
         (if program
             (harness-run-command (list program "show" sha)
                                  :cwd root :timeout 20 :name "harness-attribution-show")
           (harness-rejected (list 'no-git-ai)))
         (lambda (result)
           (let ((text (string-trim (or (plist-get result :stdout) ""))))
             (and (zerop (or (plist-get result :exit) 1))
                  (not (string-empty-p text))
                  (not (string-match-p "\\`No authorship data" text))
                  (cons sha text))))
         (lambda (_err) nil)))
      shas))))

(defun harness-commit-attribution--notes (root shas)
  "Return a promise of an alist of commit SHA -> note content.
It reads the private service when one is configured, else git-ai's own
store through `git-ai show' in ROOT."
  (if (harness-commit-attribution--url)
      (harness-then
       (harness-commit-attribution--service-get shas)
       (lambda (notes)
         (let (out)
           (dolist (sha shas)
             (when-let* ((content (cdr (assoc sha notes))))
               (push (cons sha content) out)))
           (nreverse out))))
    (harness-commit-attribution--note-fallback root shas)))

(defun harness-commit-attribution--ranges-lines (text)
  "Return the number of lines TEXT, a git-ai range list, covers."
  (let ((total 0))
    (dolist (part (split-string text "," t))
      (let ((part (string-trim part)))
        (unless (string-empty-p part)
          (if (string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" part)
              (setq total (+ total (1+ (- (string-to-number (match-string 2 part))
                                         (string-to-number (match-string 1 part))))))
            (when (string-match-p "\\`[0-9]+\\'" part)
              (cl-incf total))))))
    total))

(defun harness-commit-attribution--parse-note (content)
  "Parse git-ai authorship log CONTENT into a plist.
`:files' is a list of (:path PATH :entries (KEY . LINES) ...),
`:sessions' maps a session key to its agent_id, `:humans' is unused by
the report but kept, and `:parsed' says whether the metadata parsed."
  (let* ((content (string-remove-prefix "\ufeff" content))
         (divider (string-match "\n---\n" content))
         (attestation (if divider (substring content 0 divider) content))
         (metadata-text (and divider (substring content (+ divider 5))))
         (metadata (and metadata-text
                        (not (string-blank-p metadata-text))
                        (condition-case nil (harness-json-parse metadata-text)
                          (error nil))))
         (files nil) (file nil) (entries nil) (sessions nil))
    (dolist (line (split-string attestation "\n"))
      (cond
       ((string-empty-p line) nil)
       ((string-match-p "\\`[ \t]" line)
        (when (and file (string-match "\\`[ \t]+\\([^ \t]+\\)[ \t]+\\([0-9, -]+\\)[ \t]*\\'" line))
          (let ((key (match-string 1 line))
                (ranges (match-string 2 line)))
            (push (cons key (harness-commit-attribution--ranges-lines ranges)) entries))))
       (t
        (when file (push (list :path file :entries (nreverse entries)) files))
        (setq file (if (and (string-prefix-p "\"" line) (string-suffix-p "\"" line))
                       (substring line 1 -1) line)
              entries nil))))
    (when file (push (list :path file :entries (nreverse entries)) files))
    (let ((session-map (plist-get metadata :sessions))
          (prompt-map (plist-get metadata :prompts))
          (name (lambda (key)
                  ;; JSON object keys arrive as keywords (:s_abc); the
                  ;; attestation section spells them as strings.
                  (if (keywordp key) (substring (symbol-name key) 1) key))))
      (when (listp session-map)
        (cl-loop for (key value) on session-map by #'cddr
                 do (push (cons (funcall name key) value) sessions)))
      (when (listp prompt-map)
        (cl-loop for (key value) on prompt-map by #'cddr
                 do (push (cons (funcall name key) value) sessions))))
    (list :files (nreverse files)
          :sessions (nreverse sessions)
          :metadata metadata
          :parsed (if metadata t :false))))

(defun harness-commit-attribution--session-key (key)
  "Return the session map key of an attestation KEY."
  (if (string-match "\\`\\(s_[0-9a-f]+\\)::" key)
      (match-string 1 key)
    key))

(defun harness-commit-attribution--note-summary (content)
  "Return a plist summary of note CONTENT: its sessions, files and lines.
`:sessions' is a list of (:key KEY :tool TOOL :model MODEL
:conversation ID :lines N :files ((PATH . N) ...)) for AI sessions.
`:ai-lines' counts the lines those sessions cover."
  (let* ((parsed (harness-commit-attribution--parse-note content))
         (by-key (make-hash-table :test 'equal))
         (order nil))
    (dolist (file (plist-get parsed :files))
      (dolist (entry (plist-get file :entries))
        (let* ((raw-key (car entry))
               (key (harness-commit-attribution--session-key raw-key))
               (lines (cdr entry))
               (human (string-prefix-p "h_" key))
               (cell (gethash key by-key)))
          (unless human
            (unless cell
              (setq cell (list :key key :tool nil :model nil :conversation nil
                               :lines 0 :files nil))
              (puthash key cell by-key)
              (push key order))
            (setf (plist-get cell :lines) (+ (plist-get cell :lines) lines))
            (let ((file-cell (assoc (plist-get file :path) (plist-get cell :files))))
              (if file-cell
                  (setcdr file-cell (+ (cdr file-cell) lines))
                (setf (plist-get cell :files)
                      (append (plist-get cell :files)
                              (list (cons (plist-get file :path) lines))))))))))
    (dolist (key order)
      (let* ((cell (gethash key by-key))
             (record (cdr (assoc key (plist-get parsed :sessions))))
             (agent (plist-get record :agent_id)))
        (setf (plist-get cell :tool) (plist-get agent :tool)
              (plist-get cell :model) (plist-get agent :model)
              (plist-get cell :conversation) (plist-get agent :id))))
    (list :sessions (mapcar (lambda (key) (gethash key by-key)) order)
          :ai-lines (cl-loop for key in order
                             sum (plist-get (gethash key by-key) :lines))
          :files (plist-get parsed :files)
          :metadata (plist-get parsed :metadata))))

;;;; The report

(defun harness-commit-attribution--commits (root range limit)
  "Return a promise of commit plists for RANGE in ROOT, newest last.
Each is (:sha :short :author :date :parents :subject).  LIMIT caps how
many of the newest commits are reported."
  (let* ((format "%H%x1f%h%x1f%an%x1f%aI%x1f%P%x1f%s%x1e")
         (args (append (list "log" "--no-notes" "--reverse" "--no-decorate")
                       (and limit (list (format "--max-count=%d" limit)))
                       (list (format "--format=%s" format) (or range "HEAD")))))
    (harness-then
     (harness-run-command (append (list "git" "-C" root) args)
                          :timeout 30 :name "harness-attribution-log")
     (lambda (result)
       (unless (and (numberp (plist-get result :exit)) (zerop (plist-get result :exit)))
         (signal 'harness-error
                 (list (format "git log failed: %s"
                               (string-trim (or (plist-get result :stderr) ""))))))
       (let (commits)
         (dolist (record (split-string (or (plist-get result :stdout) "") "\x1e" t))
           ;; `git log' puts a newline after each record, so every record
           ;; but the first starts with one; it is not part of the SHA.
           (let ((fields (split-string (string-remove-prefix "\n" record) "\x1f")))
             (when (>= (length fields) 6)
               (push (list :sha (nth 0 fields) :short (nth 1 fields)
                           :author (nth 2 fields) :date (nth 3 fields)
                           :parents (split-string (nth 4 fields) " " t)
                           :subject (nth 5 fields))
                     commits))))
         (nreverse commits))))))

(defun harness-commit-attribution--describe-session (session records)
  "Return SESSION's report row with its prompt details from RECORDS."
  (let* ((conversation (plist-get session :conversation))
         (record (and conversation (gethash conversation records)))
         (parsed (and conversation
                       (harness-commit-attribution--split-conversation conversation)))
         (prompt (plist-get record :prompt))
         (hash (or (plist-get record :prompt_sha256)
                   (and prompt (secure-hash
                                'sha256 (encode-coding-string prompt 'utf-8))))))
    (list :key (plist-get session :key)
          :tool (plist-get session :tool)
          :model (plist-get session :model)
          :conversation conversation
          :session (or (plist-get record :session) (nth 0 parsed))
          :turn (or (plist-get record :turn) (nth 1 parsed))
          :system (if (and conversation (string-prefix-p "system@" conversation)) t nil)
          :lines (plist-get session :lines)
          :files (plist-get session :files)
          :prompt prompt
          :prompt_hash hash
          :prompt_mode (plist-get record :prompt_mode)
          :available (if prompt t (and hash 'hash))
          :at (plist-get record :at)
          :device (plist-get record :device))))

(defun harness-commit-attribution--note-conversations (notes)
  "Return the distinct conversations in NOTES, an alist of SHA -> content."
  (let (out)
    (dolist (pair notes)
      (let ((summary (harness-commit-attribution--note-summary (cdr pair))))
        (dolist (session (plist-get summary :sessions))
          (when-let* ((conversation (plist-get session :conversation)))
            (unless (member conversation out)
              (push conversation out))))))
    (nreverse out)))

(defun harness-commit-attribution--prompt-table (notes)
  "Return a promise of a hash of CONVERSATION -> prompt record for NOTES.
The records come from the private notes service's management API, the
only store the module has: a prompt written on another device can be
linked.  Without a service, or when it cannot be read, the table is
empty and the report still names the model and session."
  (let ((conversations (harness-commit-attribution--note-conversations notes)))
    (if (or (null conversations)
            (not (harness-commit-attribution--checkpoint-allowed-p)))
        (harness-resolved (make-hash-table :test 'equal))
      (harness-then
       (harness-commit-attribution--service-prompts-get conversations)
       (lambda (remote)
         (let ((table (make-hash-table :test 'equal)))
           (dolist (pair remote)
             (puthash (car pair) (cdr pair) table))
           table))
       (lambda (err)
         (harness-log 'warn "commit-attribution: could not read stored prompts: %s"
                      (harness-error-message err))
         (make-hash-table :test 'equal))))))

(defun harness-commit-attribution--report-data (commits notes &optional prompts)
  "Build the report from COMMITS and NOTES, an alist of sha -> content.
PROMPTS, when given, is the conversation -> record table; an empty one
is used otherwise."
  (let ((records (or prompts (make-hash-table :test 'equal)))
        (rows nil)
        (models (make-hash-table :test 'equal))
        (model-order nil)
        (linked 0) (unavailable 0))
    (dolist (commit commits)
      (let* ((sha (plist-get commit :sha))
             (content (cdr (assoc sha notes)))
             (summary (and content (harness-commit-attribution--note-summary content)))
             (sessions (mapcar (lambda (s)
                                 (harness-commit-attribution--describe-session s records))
                               (plist-get summary :sessions))))
        (dolist (session sessions)
          (when (eq (plist-get session :available) t) (cl-incf linked))
          (unless (eq (plist-get session :available) t) (cl-incf unavailable))
          (let* ((model (or (plist-get session :model) "unknown"))
                 (cell (gethash model models)))
            (unless cell
              (setq cell (list :model model :lines 0 :commits 0 :sessions 0
                               :commit-shas nil :session-keys nil))
              (puthash model cell models)
              (push model model-order))
            (setf (plist-get cell :lines) (+ (plist-get cell :lines)
                                             (or (plist-get session :lines) 0)))
            (unless (member sha (plist-get cell :commit-shas))
              (setf (plist-get cell :commit-shas)
                    (append (plist-get cell :commit-shas) (list sha)))
              (cl-incf (plist-get cell :commits)))
            (unless (member (plist-get session :key) (plist-get cell :session-keys))
              (setf (plist-get cell :session-keys)
                    (append (plist-get cell :session-keys)
                            (list (plist-get session :key))))
              (cl-incf (plist-get cell :sessions)))))
        (push (append commit
                      (list :note (if content t :false)
                            :ai-lines (or (plist-get summary :ai-lines) 0)
                            :sessions sessions
                            :models (delete-dups
                                     (delq nil (mapcar (lambda (s) (plist-get s :model))
                                                       sessions)))))
              rows)))
    (let* ((rows (nreverse rows))
           (total (cl-loop for row in rows sum (plist-get row :ai-lines)))
           (model-rows
            (mapcar
             (lambda (model)
               (let ((cell (gethash model models)))
                 (list :model model
                       :lines (plist-get cell :lines)
                       :percent (if (zerop total) 0.0
                                  (* 100.0 (/ (float (plist-get cell :lines)) total)))
                       :commits (plist-get cell :commits)
                       :sessions (plist-get cell :sessions))))
             (nreverse model-order))))
      (list :commits rows
            :models model-rows
            :ai-lines total
            :commits-count (length rows)
            :prompts (list :linked linked :unavailable unavailable)
            :notes (cl-count-if (lambda (row) (eq (plist-get row :note) t)) rows)))))

(defun harness-commit-attribution--report-root (dir)
  "Return the worktree root a report about DIR runs git in."
  (let* ((dir (and dir (file-name-as-directory (expand-file-name dir))))
         (repo (and dir (harness-commit-attribution--repo dir))))
    (or (car repo)
        dir
        (car (harness-commit-attribution--repo default-directory))
        (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-commit-attribution--settle-notes (root)
  "Return a promise resolved when the notes of ROOT have settled.
It drains the module's checkpoint queue, then asks git-ai to settle
its own daemon (`git-ai await'), so a commit made a moment ago is not
reported as unattributed.  A missing or failing git-ai is logged at
debug level and does not stop the report: it shows the notes there
are."
  (harness-then
   (harness-commit-attribution--flush)
   (lambda (_)
     (let ((program (harness-commit-attribution--program-path)))
       (if (null program)
           (harness-resolved nil)
         (harness-then
          (harness-run-command (list program "await")
                               :cwd root :timeout 20
                               :env (harness-commit-attribution--checkpoint-env)
                               :name "harness-attribution-await")
          (lambda (result)
            (unless (and (numberp (plist-get result :exit))
                         (zerop (plist-get result :exit)))
              (harness-log 'debug
                           "commit-attribution: git-ai await failed in %s: %s"
                           (abbreviate-file-name root)
                           (string-trim (or (plist-get result :stderr) ""))))
            nil)
          (lambda (err)
            (harness-log 'debug "commit-attribution: git-ai await failed in %s: %s"
                         (abbreviate-file-name root) (harness-error-message err))
            nil)))))))

(harness-defmethod commit-attribution/report (&optional dir range limit)
  "Return a promise of the private attribution report for RANGE in DIR.
DIR defaults to `default-directory'; RANGE is any revision range git
understands (\"main..HEAD\", \"HEAD~10..HEAD\"); nil reports HEAD's
history, LIMIT commits at most (default 200).  The report waits for
the module's checkpoints and git-ai's daemon to settle, then reads the
notes through the private service (or `git-ai show') and prompts from
the private prompt service's management API.
It returns a plist: `:commits' (one row per commit with its sessions
and prompts), `:models' (line totals, percentages, commits and
sessions), `:ai-lines', `:commits-count', `:prompts' (:linked and
:unavailable), and `:notes' (commits with a note)."
  (let* ((root (harness-commit-attribution--report-root dir))
         (limit (or limit 200)))
    (harness-then
     (harness-commit-attribution--settle-notes root)
     (lambda (_)
       (harness-then
        (harness-commit-attribution--commits root range limit)
        (lambda (commits)
          (if (null commits)
              (list :commits nil :models nil :ai-lines 0 :commits-count 0
                    :prompts (list :linked 0 :unavailable 0) :notes 0
                    :range range :repository root)
            (harness-then
             (harness-commit-attribution--notes root (mapcar (lambda (c) (plist-get c :sha)) commits))
             (lambda (notes)
               (harness-then
                (harness-commit-attribution--prompt-table notes)
                (lambda (prompts)
                  (append (harness-commit-attribution--report-data commits notes prompts)
                          (list :range range :repository root)))))))))))))

(defun harness-commit-attribution--report-text (data)
  "Return the printable text of report DATA."
  (let* ((range (or (plist-get data :range) "HEAD"))
         (models (plist-get data :models))
         (prompts (plist-get data :prompts)))
    (with-temp-buffer
      (insert (format "Commit attribution (%s)\n" range))
      (insert (format "Repository: %s\n" (or (plist-get data :repository) "?")))
      (insert (format "%d AI line%s in %d commit%s, %d commit%s with a note\n\n"
                      (plist-get data :ai-lines)
                      (if (= 1 (plist-get data :ai-lines)) "" "s")
                      (plist-get data :commits-count)
                      (if (= 1 (plist-get data :commits-count)) "" "s")
                      (plist-get data :notes)
                      (if (= 1 (plist-get data :notes)) "" "s")))
      (if (null models)
          (insert "No model attribution: no note was found for this range.\n")
        (insert (format "%-34s %10s %7s %8s %9s\n"
                        "Model" "AI lines" "Share" "Commits" "Sessions"))
        (dolist (model models)
          (insert (format "%-34s %10d %6.1f%% %8d %9d\n"
                          (harness-truncate-end (or (plist-get model :model) "unknown") 34)
                          (plist-get model :lines)
                          (or (plist-get model :percent) 0.0)
                          (plist-get model :commits)
                          (plist-get model :sessions))))
        (insert (format "\nPrompts: %d linked, %d unavailable\n"
                        (plist-get prompts :linked)
                        (plist-get prompts :unavailable))))
      (insert "\n")
      (dolist (commit (plist-get data :commits))
        (insert (format "%s %s\n" (plist-get commit :short) (plist-get commit :subject)))
        (if (not (eq (plist-get commit :note) t))
            (insert "  no attribution note (an untraced commit, or git-ai was not running)\n")
          (insert (format "  %d AI line%s in %d session%s\n"
                          (plist-get commit :ai-lines)
                          (if (= 1 (plist-get commit :ai-lines)) "" "s")
                          (length (plist-get commit :sessions))
                          (if (= 1 (length (plist-get commit :sessions))) "" "s")))
          (dolist (session (plist-get commit :sessions))
            (insert (format "  %s  %s  %s\n"
                            (or (plist-get session :model) "unknown")
                            (or (plist-get session :tool) "?")
                            (cond ((harness-json-true-p (plist-get session :system))
                                   "system")
                                  ((plist-get session :prompt)
                                   (format "%s: \u201c%s\u201d"
                                           (or (plist-get session :turn) "prompt")
                                           (harness-first-line (plist-get session :prompt) 90)))
                                  ((plist-get session :prompt_hash) "prompt: hash only")
                                  (t "prompt unavailable"))))))
        (insert "\n"))
      (buffer-string))))

(defun harness-commit-attribution--show-report (data buffer-name)
  "Show report DATA in a buffer named BUFFER-NAME."
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (harness-commit-attribution--report-text data))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)
    buffer))

(defun harness-commit-attribution-report (&optional range dir)
  "Show which model and prompt wrote the commits of RANGE in DIR."
  (interactive
   (list (read-string "Revision range (default HEAD): " nil nil "HEAD")
         (read-directory-name "Repository: " nil nil t)))
  (let* ((root (or dir default-directory))
         (name (format "*commit attribution: %s*"
                       (or (and range (not (string-empty-p range)) range) "HEAD"))))
    (harness-then
     (harness-call-async 'commit-attribution/report
                         (or (and dir (expand-file-name dir)) root)
                         (and range (not (string-empty-p range)) range))
     (lambda (data)
       (harness-commit-attribution--show-report data name))
     (lambda (err)
       (message "Commit attribution failed: %s" (harness-error-message err))
       nil))))

(defun harness-commit-attribution--show-text (summary commit)
  "Return printable text for COMMIT and its note SUMMARY."
  (with-temp-buffer
    (insert (format "%s %s\n" (or (plist-get commit :short) "?")
                    (or (plist-get commit :subject) "")))
    (insert (format "Author: %s\nDate: %s\n\n"
                    (or (plist-get commit :author) "?")
                    (or (plist-get commit :date) "?")))
    (if (null (plist-get summary :sessions))
        (insert "No authorship data found for this revision.\n")
      (dolist (session (plist-get summary :sessions))
        (insert (format "%s  %s  lines: %d\n"
                        (or (plist-get session :model) "unknown")
                        (or (plist-get session :tool) "?")
                        (or (plist-get session :lines) 0)))
        (dolist (file (plist-get session :files))
          (insert (format "  %s  %d line%s\n" (car file) (cdr file)
                          (if (= 1 (cdr file)) "" "s"))))
        (when (plist-get session :conversation)
          (insert (format "  conversation: %s\n" (plist-get session :conversation))))
        (insert "\n")))
    (buffer-string)))

(harness-defmethod commit-attribution/show (&optional dir rev)
  "Return a promise of the attribution of REV in DIR.
The plist has `:commit' (its metadata), `:text' (a printable buffer)
and `:sessions' (the parsed note rows)."
  (let* ((root (harness-commit-attribution--report-root dir))
         (rev (or rev "HEAD")))
    (harness-then
     (harness-commit-attribution--settle-notes root)
     (lambda (_)
       (harness-then
        (harness-commit-attribution--commits root rev 1)
        (lambda (commits)
          (let ((commit (car commits)))
            (if (null commit)
                (signal 'harness-error (list (format "No commit %s in %s" rev root)))
              (harness-then
               (harness-commit-attribution--notes root (list (plist-get commit :sha)))
               (lambda (notes)
                 (let* ((content (cdr (assoc (plist-get commit :sha) notes)))
                        (summary (and content (harness-commit-attribution--note-summary content))))
                   (list :commit commit
                         :sessions (plist-get summary :sessions)
                         :text (harness-commit-attribution--show-text summary commit)))))))))))))

(defun harness-commit-attribution-show (&optional rev dir)
  "Show which model wrote the lines of REV in DIR."
  (interactive
   (list (read-string "Revision (default HEAD): " nil nil "HEAD")
         (read-directory-name "Repository: " nil nil t)))
  (harness-then
   (harness-call-async 'commit-attribution/show
                       (or (and dir (expand-file-name dir)) default-directory)
                       (and rev (not (string-empty-p rev)) rev))
   (lambda (data)
     (let ((buffer (get-buffer-create
                    (format "*commit attribution: %s*" (or rev "HEAD")))))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (plist-get data :text))
           (goto-char (point-min))
           (special-mode)))
       (display-buffer buffer)))
   (lambda (err)
     (message "Commit attribution failed: %s" (harness-error-message err))
     nil)))

(defun harness-commit-attribution--fetch-prompt (conversation)
  "Return a promise of the prompt CONVERSATION names, or nil.
The private notes service's management API is the only prompt store;
without one, a failure, or a record with no prompt text, the promise
resolves to nil."
  (if (and (stringp conversation)
           (not (string-empty-p conversation))
           (harness-commit-attribution--checkpoint-allowed-p))
      (harness-then
       (harness-commit-attribution--service-prompts-get (list conversation))
       (lambda (remote)
         (plist-get (cdr (assoc conversation remote)) :prompt))
       (lambda (_err) nil))
    (harness-resolved nil)))

(harness-defmethod commit-attribution/show-prompt (conversation)
  "Return a promise of the prompt the private service keeps for CONVERSATION.
CONVERSATION is a git-ai agent id (the harness epoch).  The module
keeps no prompt records of its own, so this reads the service's
management API.  A record with `harness-commit-attribution-prompt-mode'
`hash' has no text and resolves to nil; `commit-attribution/report'
still shows its hash.  A failure or a missing record gives nil."
  (harness-commit-attribution--fetch-prompt conversation))

(harness-defmethod commit-attribution/fetch-prompt (conversation)
  "Return a promise of the prompt CONVERSATION names, or nil.
The private notes service's management API is the only prompt store,
so a prompt written on another device can be shown; a failure or a
missing record gives nil.  The same as `commit-attribution/show-prompt'."
  (harness-commit-attribution--fetch-prompt conversation))

(defun harness-commit-attribution-show-prompt (&optional conversation)
  "Show the prompt for CONVERSATION from the private prompt service."
  (interactive
   (list (read-string "Conversation id: " nil nil
                      (or (and (fboundp 'thing-at-point)
                               (thing-at-point 'symbol t))
                          ""))))
  (let ((conversation (string-trim (or conversation ""))))
    (cond
     ((string-empty-p conversation) (message "No conversation id"))
     ((not (harness-commit-attribution--checkpoint-allowed-p))
      (message "No private notes service, so no prompt record for %s" conversation))
     (t
      (harness-then
       (harness-call-async 'commit-attribution/fetch-prompt conversation)
       (lambda (prompt)
         (message "%s" (or prompt (format "No prompt found for %s" conversation))))
       (lambda (err)
         (message "Commit attribution failed: %s" (harness-error-message err))
         nil))))))

;;;; Redacting the records the private service holds

(defun harness-commit-attribution--redact-record (record secrets)
  "Return (NEW . COUNT) for RECORD with the values of SECRETS replaced.
NEW is RECORD itself when COUNT is zero; otherwise it is a copy, its
prompt hash is taken from the redacted text, and it is marked redacted.
An identity field that held a secret cannot name the record any more;
NEW then has no `:conversation', and the caller deletes the record
rather than write it under a changed id."
  (let ((result (harness-redaction-value record secrets)))
    (if (zerop (cdr result))
        result
      (let* ((new (copy-sequence (car result)))
             (identity-changed
              (cl-some (lambda (key)
                         (not (equal (plist-get new key)
                                     (plist-get record key))))
                       '(:conversation :session :turn :model :repo :device)))
             (new (if identity-changed
                      (plist-put new :conversation nil)
                    new)))
        (when (plist-get new :prompt)
          (setq new (plist-put new :prompt_sha256
                               (harness-commit-attribution--prompt-hash
                                (plist-get new :prompt)))))
        (setq new (plist-put new :redacted t))
        (cons new (cdr result))))))

(defun harness-commit-attribution-redact-prompts (run)
  "Redact the prompt records the private service holds for RUN.
The redaction engine calls this as one of its stores
\(`harness-redact--store-functions').  It reads the records of the
sessions in RUN's scope through the service's management API, replaces
each secret of RUN with its placeholder, and writes the changed records
back through the same API; no secret is sent to the service, and a
record whose identifying fields held one is deleted instead.  In a
scan only counts are reported.  Nothing is done without a private
notes URL or sessions in scope."
  (when (and (harness-commit-attribution--url)
             (harness-redact-run-ids run)
             (harness-redact-run-secrets run))
    (let* ((ids (harness-redact-run-ids run))
           (secrets (harness-redact-run-secrets run))
           (dry (harness-redact-run-dry-p run))
           (in-flight
            (cl-loop for conversation being the hash-keys
                     of harness-commit-attribution--prompts-sending
                     when (let ((parsed (harness-commit-attribution--split-conversation
                                         conversation)))
                            (and parsed (member (car parsed) ids)))
                     collect conversation))
           (records nil)
           (total 0)
           (changed 0)
           (upload nil)
           (delete nil))
      ;; An upload already on the wire would land after this scan, with
      ;; the secret in it.  Refuse rather than report a clean store.
      (when in-flight
        (harness-commit-attribution--fail
         "%d prompt upload(s) are still in flight; run the redaction again when they finish"
         (length in-flight)))
      (setq records (harness-commit-attribution--management-prompts nil ids))
      (dolist (pair records)
        (let* ((conversation (car pair))
               (record (cdr pair))
               (result (harness-commit-attribution--redact-record record secrets))
               (new (car result))
               (count (cdr result)))
          (when (> count 0)
            (cl-incf total count)
            (cl-incf changed)
            (let ((sid (plist-get record :session)))
              (when (and (stringp sid) (member sid ids))
                (harness-redact-entry-incr run sid :prompt-service count)
                (harness-redact-entry-add run sid :prompt-conversations
                                          (list conversation))))
            (unless dry
              (if (plist-get new :conversation)
                  (push (cons conversation new) upload)
                (push conversation delete))))))
      (unless dry
        (when delete
          (harness-commit-attribution--management-delete (nreverse delete)))
        (when upload
          (harness-commit-attribution--management-upload (nreverse upload))))
      (harness-redact-add-store
       run
       (list :store "private prompt service"
             :count total
             :records (length records)
             :changed changed
             :service (harness-commit-attribution--url))
       (when (> changed 0)
         (list (if dry
                   (format "The private prompt service holds %d occurrence(s) in %d record(s); a redaction would rewrite %d."
                           total (length records) changed)
                 (format "Found and redacted %d occurrence(s) in %d of the private prompt service's %d record(s)."
                         total changed (length records)))))))))

;;;; Pruning, status and doctor

(harness-defmethod commit-attribution/prune (&optional days)
  "Delete prompt records older than DAYS, or the retention setting.
DAYS defaults to `harness-commit-attribution-retention-days'.  The
records live in the private notes service, so this calls its management
API; it changes no notes and no Git history.  Return the number
deleted, or zero when there is no service or no setting."
  (let ((days (or days harness-commit-attribution-retention-days)))
    (if (or (not days)
            (not (harness-commit-attribution--url)))
        0
      (harness-commit-attribution--management-delete
       nil (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                               (time-subtract (current-time) (* 86400 days)) t)))))

(defun harness-commit-attribution--doctor-checks (dir)
  "Return a promise of the check list of the doctor for DIR."
  (let* ((cwd (file-name-as-directory (expand-file-name (or dir default-directory))))
         (main (harness-commit-attribution--main cwd))
         (repo (and main (harness-commit-attribution--repo main)))
         (program (harness-commit-attribution--program-path))
         (config (condition-case err
                     (harness-commit-attribution--read-config)
                   (error (list :error (harness-error-message err)))))
         (config-checks
          (if (and config (not (plist-get config :error)))
              (harness-commit-attribution--check-config config)
            (list (list :name "config" :ok :false :severity 'error
                        :detail (format "no readable git-ai config at %s; run commit-attribution/configure"
                                        (harness-commit-attribution--config-file))))))
         (notes-refs
          (and repo
               (let ((r (harness-commit-attribution--git-sync
                         (car repo) "for-each-ref" "--format=%(refname)" "refs/notes")))
                 (and (car r) (zerop (car r))
                      (split-string (string-trim (cdr r)) "\n" t)))))
         (hook (harness-commit-attribution--hook-file repo))
         (hook-ok (and hook (file-exists-p hook)
                       (harness-commit-attribution--hook-p (harness-read-file hook))))
         (base
          (list
           (list :name "git-ai" :severity 'error
                 :ok (if program t :false)
                 :detail (if program (format "git-ai at %s" program)
                           (format "cannot find %s" (harness-commit-attribution--program))))
           (list :name "version" :severity 'warning
                 :ok (if (harness-commit-attribution--version) t :false)
                 :detail (or (harness-commit-attribution--version)
                             "git-ai did not answer --version"))
           (list :name "repository" :severity 'warning
                 :ok (if (and main (harness-commit-attribution--selected-p main)) t :false)
                 :detail (cond ((not main) "not a local git repository")
                               ((harness-commit-attribution--selected-p main)
                                (format "enabled in %s" (abbreviate-file-name main)))
                               (t (format "not enabled in %s (set harness-commit-attribution)"
                                          (abbreviate-file-name main)))))
           (list :name "notes-mode" :severity 'error
                 :ok (if (eq (harness-commit-attribution--mode) 'private-remote) :false t)
                 :detail (if (eq (harness-commit-attribution--mode) 'private-remote)
                             "private-remote (Profile C) is a phase 5 follow-up; use private-service"
                           (format "%s mode keeps notes out of git" (harness-commit-attribution--mode))))
           (list :name "prompt-sync" :severity 'warning
                 :ok (cond ((not harness-commit-attribution-prompt-sync) t)
                           ((harness-commit-attribution--prompt-sync-p) t)
                           (t :false))
                 :detail (cond ((not harness-commit-attribution-prompt-sync)
                                "prompt sync is off; the module stores no prompt record")
                               ((harness-commit-attribution--prompt-sync-p)
                                (format "redacted prompts are stored at %s through the management API"
                                        (harness-commit-attribution--url)))
                               (t "prompt sync needs a private notes URL; no prompt record is stored")))
           (list :name "notes-refs" :severity 'error
                 :ok (if notes-refs :false t)
                 :detail (if notes-refs
                             (format "%s would be published by a normal push: migrate it with `git ai notes migrate' and delete it"
                                     (string-join notes-refs ", "))
                           "no refs/notes/* in the repository"))
           (list :name "pre-commit-hook" :severity 'warning
                 :ok (if hook-ok t :false)
                 :detail (cond (hook-ok "the harness's pre-commit hook is installed")
                               ((and hook (file-exists-p hook))
                                "a pre-commit hook somebody else wrote is there; edit-and-commit-in-one-command is not covered")
                               (t "the harness's pre-commit hook is not installed; a commit made in one shell command may be unattributed")))
           (list :name "sandbox" :severity 'info
                 :ok t
                 :detail (format "git-ai directories made readable to sandboxed commands: %s"
                                 (or (mapconcat #'identity
                                                (harness-commit-attribution--sandbox-readable-dirs) ", ")
                                     "none"))))))
    (harness-then
     (harness-all (list (harness-commit-attribution--probe-service)
                        (harness-commit-attribution--probe-management)))
     (lambda (probes)
       (let* ((probe (car probes))
              (management (cadr probes))
              (checks (append base config-checks
                              (list (list :name "notes-service" :severity 'error
                                          :ok (car probe) :detail (cdr probe))
                                    (list :name "prompt-service"
                                          :severity (if harness-commit-attribution-prompt-sync
                                                        'error 'info)
                                          :ok (car management)
                                          :detail (cdr management)))))
              (failed (cl-remove-if-not
                       (lambda (check)
                         (and (eq (plist-get check :severity) 'error)
                              (not (eq (plist-get check :ok) t))))
                       checks)))
         (list :ok (if failed :false t)
               :checks checks
               :failed (mapcar (lambda (c) (plist-get c :name)) failed)
               :repository main
               :config (harness-commit-attribution--config-file)
               :prompt-sync (if (harness-commit-attribution--prompt-sync-p) t :false)
               :vault (if harness-commit-attribution-vault
                          "configured; encrypted vault is a phase 3 follow-up"
                        "not configured; phase 3 follow-up")))))))

(harness-defmethod commit-attribution/doctor (&optional dir)
  "Check that attribution can only reach the private stores, for DIR.
Return a promise of (:ok BOOL :checks (...) :failed (...) :repository
MAIN :config FILE :prompt-sync BOOL :vault TEXT).  Each check is
(:name NAME :ok BOOL :severity error/warning/info :detail TEXT).
`:ok' is nil when an error check failed.  The doctor checks the git-ai
profile (telemetry
off, prompts local, no cloud login, HTTP private notes backend), that
no `refs/notes/*' exists in the repository, that the pre-commit hook is
the harness's, and that the private notes service answers with the
configured token."
  (harness-commit-attribution--doctor-checks dir))

(defun harness-commit-attribution-doctor (&optional dir)
  "Print the private attribution doctor's checks for DIR."
  (interactive (list (read-directory-name "Repository: " nil nil t)))
  (harness-then
   (harness-call-async 'commit-attribution/doctor
                       (or (and dir (expand-file-name dir)) default-directory))
   (lambda (result)
     (with-current-buffer (get-buffer-create "*commit attribution doctor*")
       (let ((inhibit-read-only t))
         (erase-buffer)
         (insert (format "Private commit attribution: %s\n"
                         (if (eq (plist-get result :ok) t) "ready" "needs attention")))
         (insert (format "Repository: %s\nConfig: %s\nVault: %s\n\n"
                         (or (plist-get result :repository) "?")
                         (or (plist-get result :config) "?")
                         (or (plist-get result :vault) "?")))
         (dolist (check (plist-get result :checks))
           (insert (format "[%s] %-18s %s\n"
                           (pcase (plist-get check :ok)
                             ('t "ok") (:false "FAIL") (_ "warn"))
                           (plist-get check :name)
                           (or (plist-get check :detail) ""))))
         (goto-char (point-min))
         (special-mode)))
     (display-buffer (current-buffer)))
   (lambda (err)
     (message "Commit attribution doctor failed: %s" (harness-error-message err))
     nil)))

(harness-defmethod commit-attribution/configure-active (dir)
  "Turn attribution on for DIR by writing its project .dir-locals.el.
Return the path of the file written.  The setting is the layered
`harness-commit-attribution'; this is the same edit the settings page's
Project scope makes, not a global change."
  (let* ((main (or (harness-commit-attribution--main dir)
                   (error "Not in a local git repository: %s" dir)))
         (result (harness-call 'config/set "harness-commit-attribution" "t"
                               :scope 'project :cwd main :printed t)))
    (cdr result)))

;;;; Module

(defconst harness-commit-attribution--subscriptions
  '((harness/started . harness-commit-attribution--on-started)
    (harness/reloaded . harness-commit-attribution--on-started)
    (worktree/created . harness-commit-attribution--on-worktree-created)
    (session/created . harness-commit-attribution--on-session-created)
    (session/moved . harness-commit-attribution--on-session-moved)
    (session/deleted . harness-commit-attribution--on-session-deleted)
    (config/changed . harness-commit-attribution--on-config-changed)
    (session/node-added . harness-commit-attribution--on-node-added)
    (agent/turn-started . harness-commit-attribution--on-turn-started)
    (agent/turn-ended . harness-commit-attribution--on-turn-ended)
    (agent/tool-call . harness-commit-attribution--on-tool-call)
    (agent/tool-result . harness-commit-attribution--on-agent-tool-result)
    (tools/started . harness-commit-attribution--on-tools-started)
    (tools/finished . harness-commit-attribution--on-tools-finished))
  "The events the module follows, with the function each one calls.")

(defun harness-commit-attribution--init ()
  "Follow the attribution events and join the sandbox filter."
  (pcase-dolist (`(,event . ,fn) harness-commit-attribution--subscriptions)
    (harness-on event fn))
  (harness-add-filter 'tools/sandbox-options
                      #'harness-commit-attribution--sandbox-options))

(defun harness-commit-attribution--shutdown ()
  "Stop following the events and leave the sandbox filter."
  (pcase-dolist (`(,event . ,fn) harness-commit-attribution--subscriptions)
    (harness-off (cons event fn)))
  (harness-remove-filter 'tools/sandbox-options
                         #'harness-commit-attribution--sandbox-options))

;; A reload does not run `:init' again for a ready module, so a running
;; harness that reloads this file subscribes here.
(harness-commit-attribution--init)

(harness-define-module 'commit-attribution
  :doc "Which model and prompt wrote each commit, private and synced."
  :requires '(config worktree store session tools agent usage secrets)
  :init #'harness-commit-attribution--init
  :shutdown #'harness-commit-attribution--shutdown)

(provide 'harness-commit-attribution)
;;; harness-commit-attribution.el ends here
