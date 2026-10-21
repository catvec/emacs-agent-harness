;;; harness-access.el --- What a session may reach: its jail, escalations and judgements  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session's access is spread over several modules: the directories
;; of its jail and their grants (harness-perms.el), the kernel sandbox
;; its commands run in (harness-sandbox.el), its permission mode and
;; non-interactive switch (its record), the tools it is offered
;; (`agent/tools'), the read-only policies of other modules
;; (harness-readonly.el).  This module gathers them, and adds what a
;; session's own jail needs to be set up beyond its directories.
;;
;; * The access profile
;;
;; Each session may have an access profile, kept in its record's
;; `:ext' as `:access' (so it survives a restart), a plist of:
;;
;;   :network    `:false' when the session may not reach the network
;;   :read-only  t when the session may not write anything
;;   :tools-off  the names of the tools turned off for it
;;   :read-dirs  directories it may read but not write
;;   :dropped    directories it gave up: its working directory, its
;;               worktree, its temporary directory or one of
;;               `harness-allowed-directories', for this session only
;;
;; A session without one has the access it always had.  The profile is
;; held by the harness, not by a prompt:
;;
;; - the directories go through perms' `permission/dir-entries' filter:
;;   a read-only directory is an entry with `:read-only', which a call
;;   that only reads may reach and any other may not, and bash sees it
;;   read-only; a dropped directory is no entry at all;
;; - the tools a session may not use go from its tool list (`agent/tools')
;;   and a call to one is refused for good by a `permission/decide'
;;   stage at 4, before every other: tools turned off, and without the
;;   network those of kind net, ssh and emacs_eval (which runs in the
;;   user's Emacs, outside any sandbox), and bash and elisp unless the
;;   sandbox runs them offline (`tools/sandbox-options' `:network nil');
;; - a read-only session is one of `harness-readonly-register''s: only
;;   the reading tools, and bash read-only and offline.
;;
;; A sub-agent or a fork takes its parent's restrictions with it (the
;; network, writing, the tools, the directories given up), so a
;; session cannot get around what it gave up by starting another; a
;; fork takes its read-only directories too, as it takes its grants.
;;
;; * Escalation and relinquishing
;;
;; What a session may reach is a sensitive attribute, which only the
;; user raises.  An agent asks for more with `request_escalation': a
;; directory (to write, or only to read), the network, writing, a tool
;; turned off, a more permissive permission mode, non-interactive mode.
;; The stage at 5 decides it as only the user may (as
;; `request_directory_access' is): the user is asked, in every mode,
;; yolo included, and no rule or judge answers; a non-interactive
;; session, whose user is away, is refused at once.  A directory goes
;; through the very prompt of `request_directory_access' (perms'
;; `harness-perms-decide-dir-request'), the rest through
;; `harness-perms-confirm'.  `request_directory_access' stays, the
;; directory form of the same request.
;;
;; An agent may always take access away from its own session, with
;; `drop_access': nobody is asked, in any mode or session, read-only
;; ones included (`harness-readonly-always-tools').  It gives up a
;; directory (or only writing to it), the network, writing, a tool, a
;; permission mode (for a less permissive one) or non-interactive mode.
;; The user changes the profile from the access view (`access/*'
;; methods), without being asked anything.
;;
;; Writing a .dir-locals.el is an escalation too: the file sets the
;; harness's own settings for a project -- the directories every session
;; there may reach, the sandbox policy, the permission mode -- so a call
;; of a file tool that writes one asks the user, in every mode, as an
;; escalation does, and so does a shell command that names one and looks
;; like it writes it.  The shell command's check is a reading of its
;; text, not a boundary.
;;
;; * Judgements
;;
;; Every decision of the permission chain (`permission/decided') is a
;; judgement: the call, what was decided, who decided it -- the user,
;; a rule, the mode, the judge, the jail, the access profile, a module's
;; gate (`harness-tools-decision-by') -- and why.  The record is kept in
;; memory, and written into the call's result node as `:judgement'
;; (a `tools/result' filter), so the transcript keeps it.
;; `access/judgements' lists a session's, filtered, with the call and
;; result nodes the chat draws them from; a call that waits for the user
;; is one too.
;;
;; * Methods
;;
;; `access/describe' says everything about a session's access at once,
;; for the access view (harness-ui-access.el): the sandbox, the mode,
;; the directories, the tools, the rules.  `access/judgements' lists the
;; judgements.  `access/set-network', `access/set-read-only',
;; `access/set-tool', `access/add-read-dir', `access/remove-read-dir',
;; `access/drop-dir' and `access/restore-dir' change the profile for the
;; user.  `access/changed' (SESSION-ID) says a session's access changed,
;; `access/judged' (SESSION-ID RECORD) that a call was judged.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-perms)
(require 'harness-readonly)

(defvar harness-corporate-mode)

;;;; Names

(defconst harness-access-escalation-tool "request_escalation"
  "Tool through which an agent asks the user for more access.")

(defconst harness-access-drop-tool "drop_access"
  "Tool through which an agent gives up access, never asking anyone.")

(defconst harness-access-attributes
  '("directory" "read_directory" "writes" "network" "tool" "permission_mode" "non_interactive")
  "The attributes `request_escalation' and `drop_access' take.
`read_directory' is for an escalation only: `drop_access' gives up a
directory whatever it may do there.")

(defconst harness-access-modes '(ask accept-edits auto yolo)
  "The permission modes from the least permissive to the most.
A mode later in the list is an escalation from one before it.")

(defconst harness-access-offline-tools '("ssh" "emacs_eval")
  "Tools besides those of kind net that a session without the network loses.
ssh runs commands on another machine; emacs_eval runs code in the
user's Emacs, outside any sandbox, where nothing keeps it off the
network.")

(defconst harness-access-sandboxed-tools '("bash" "elisp")
  "Tools whose commands run in the sandbox.
Without the network they run offline there; where the sandbox cannot
confine them they are off.")

(defconst harness-access-droppable-sources '(cwd worktree tmp config)
  "Sources of directories a session gives up by keeping them in `:dropped'.
A grant, for the session or until its turn ends, is revoked instead, a
read-only directory taken out of `:read-dirs', and the tool output
directory, where the harness keeps what long outputs were cut to, stays.")

(defconst harness-access-settings-files '(".dir-locals.el" ".dir-locals-2.el")
  "Names of the files whose writing is an escalation.
They set the harness's own settings for a project (see harness-config.el).")

;;;; Small helpers

(defun harness-access--session (session-id)
  "Return the session plist of SESSION-ID, or signal a `harness-error'."
  (or (and (stringp session-id) (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get session-id)))
      (signal 'harness-error (list (format "No session %s" session-id)))))

(defun harness-access--name (value)
  "Return VALUE, an attribute or a tool name, as a trimmed string, or nil."
  (let ((s (cond ((stringp value) value)
                 ((and value (symbolp value)) (symbol-name value)))))
    (and s (not (harness-string-blank-p s)) (string-trim s))))

(defun harness-access--attribute (value)
  "Return VALUE as one of `harness-access-attributes', or nil.
Case and dashes for underscores do not matter."
  (when-let* ((name (harness-access--name value)))
    (car (member (replace-regexp-in-string "-" "_" (downcase name)) harness-access-attributes))))

(defun harness-access--mode (value)
  "Return VALUE as one of `harness-access-modes', or nil."
  (when-let* ((name (harness-access--name value)))
    (car (memq (intern (replace-regexp-in-string "_" "-" (downcase name))) harness-access-modes))))

(defun harness-access--mode-rank (mode)
  "Return how permissive MODE is, 0 for ask."
  (or (cl-position mode harness-access-modes) 0))

(defun harness-access--abbrev (dir)
  "Return DIR abbreviated for a message."
  (abbreviate-file-name (or dir "")))

;;;; The profile

(defun harness-access-profile (session)
  "Return the access profile of SESSION, a session plist, or nil."
  (let ((p (plist-get (plist-get session :ext) :access)))
    (and (consp p) (keywordp (car p)) p)))

(defun harness-access-network-p (session)
  "Non-nil when SESSION may reach the network as far as its profile goes."
  (not (eq (plist-get (harness-access-profile session) :network) :false)))

(defun harness-access-read-only-p (session)
  "Non-nil when SESSION's profile keeps it from writing."
  (harness-json-true-p (plist-get (harness-access-profile session) :read-only)))

(defun harness-access--strings (value)
  "Return VALUE, a list from the profile, as a list of strings."
  (and (listp value) (cl-remove-if-not #'stringp value)))

(defun harness-access-tools-off (session)
  "Return the names of the tools SESSION's profile turns off."
  (harness-access--strings (plist-get (harness-access-profile session) :tools-off)))

(defun harness-access-read-dirs (session)
  "Return the directories SESSION's profile lets it read but not write."
  (harness-access--strings (plist-get (harness-access-profile session) :read-dirs)))

(defun harness-access-dropped (session)
  "Return the directories SESSION gave up (see `harness-access-droppable-sources')."
  (harness-access--strings (plist-get (harness-access-profile session) :dropped)))

(defun harness-access--normalise (profile)
  "Return PROFILE as it is stored: no key without a value, no duplicates.
The network is stored only when it is off and writing only when it is
off, so a profile that restricts nothing is nil."
  (let ((network (plist-get profile :network))
        (read-only (plist-get profile :read-only))
        (tools (delete-dups (copy-sequence (harness-access--strings (plist-get profile :tools-off)))))
        (read-dirs (delete-dups (copy-sequence (harness-access--strings (plist-get profile :read-dirs)))))
        (dropped (delete-dups (copy-sequence (harness-access--strings (plist-get profile :dropped))))))
    (append (and (eq network :false) (list :network :false))
            (and (harness-json-true-p read-only) (list :read-only t))
            (and tools (list :tools-off tools))
            (and read-dirs (list :read-dirs read-dirs))
            (and dropped (list :dropped dropped)))))

(defun harness-access--update (session-id fn &optional hint)
  "Change SESSION-ID's access profile to what FN makes of it; return the new one.
FN gets the profile and returns the new one, normalised then
\(`harness-access--normalise').  HINT, a string, goes into the
session's transcript as a hint, so the change is on record.  Announced
as `access/changed'."
  (let* ((session (harness-access--session session-id))
         (old (harness-access-profile session))
         (new (harness-access--normalise (funcall fn (copy-sequence old)))))
    (unless (equal old new)
      (harness-call 'session/set-ext session-id :access new hint)
      (harness-emit 'access/changed session-id))
    new))

(defun harness-access--hint (who text)
  "Return the transcript hint of an access change TEXT made by WHO.
WHO is `user' or `agent'."
  (format "Access: %s (%s)." text (if (eq who 'agent) "given up by the agent" "set by the user")))

;;;; Directories

(defun harness-access--dir (session path)
  "Return the directory PATH names for SESSION, absolute, with its host.
As `harness-perms--requested-dir' makes it: symbolic links resolved, a
file standing for the directory holding it."
  (harness-perms--requested-dir session path))

(defun harness-access--same-dir-p (a b)
  "Non-nil when A and B name the same directory, symbolic links aside."
  (and (stringp a) (stringp b)
       (or (equal (file-name-as-directory a) (file-name-as-directory b))
           (and (not (file-remote-p a)) (not (file-remote-p b))
                (equal (file-name-as-directory (harness-path-normalize a))
                       (file-name-as-directory (harness-path-normalize b)))))))

(defun harness-access--dir-entries (entries session)
  "Apply SESSION's profile to ENTRIES, the directories it may touch.
A `permission/dir-entries' filter: the directories it gave up of
`harness-access-droppable-sources' go, and those it may only read come
last, with `:read-only' t and source `read', so a directory both
granted and read-only stays writable."
  (let ((dropped (harness-access-dropped session))
        (read-dirs (harness-access-read-dirs session)))
    (if (not (or dropped read-dirs))
        entries
      (append (if dropped
                  (cl-remove-if (lambda (e)
                                  (and (memq (plist-get e :source) harness-access-droppable-sources)
                                       (cl-some (lambda (d) (harness-access--same-dir-p d (plist-get e :dir)))
                                                dropped)))
                                entries)
                entries)
              (mapcar (lambda (d) (list :dir (file-name-as-directory d) :source 'read :read-only t))
                      read-dirs)))))

(defun harness-access--entry-of (session dir)
  "Return the entry of SESSION's directories that is DIR, or nil.
Its read-only directories count, its dropped ones do not."
  (cl-find-if (lambda (e) (harness-access--same-dir-p (plist-get e :dir) dir))
              (harness-perms-dirs session)))

(defun harness-access--holder (session dir)
  "Return the entry of SESSION's directories that holds DIR, or nil."
  (cl-find-if (lambda (e) (harness-perms--within-p (plist-get e :dir) dir))
              (harness-perms-dirs session)))

(defun harness-access--source-label (source)
  "Return how a message names directory SOURCE."
  (pcase source
    ('read "a directory it may only read")
    (_ (harness-perms--source-label source))))

(defun harness-access-drop-dir (session-id path &optional keep-read who)
  "Take the directory PATH away from SESSION-ID; return what was done, as text.
PATH must be one of the session's own directories as `permission/dirs'
lists them.  A grant is revoked, a read-only directory forgotten, and
the working directory, the worktree, the temporary directory or a
configured directory is given up for this session alone.  KEEP-READ
non-nil keeps it readable: it becomes a read-only directory of the
session.  WHO, `user' or `agent', is named in the transcript's hint.
Signal a `harness-error' for a PATH that is none of the session's
directories, or the tool output directory."
  (let* ((session (harness-access--session session-id))
         (dir (or (and (stringp path) (not (harness-string-blank-p path)) (harness-access--dir session path))
                  (signal 'harness-error (list "Give the directory to give up"))))
         (entry (harness-access--entry-of session dir))
         (source (plist-get entry :source))
         (shown (harness-access--abbrev dir))
         (read (lambda (p) (plist-put p :read-dirs (cons dir (plist-get p :read-dirs))))))
    (cond
     ((null entry)
      (let ((holder (harness-access--holder session dir)))
        (signal 'harness-error
                (list (if holder
                          (format "%s lies inside %s (%s), which stays as it is: give that up instead, or drop writing with drop_access attribute writes"
                                  shown (harness-access--abbrev (plist-get holder :dir))
                                  (harness-access--source-label (plist-get holder :source)))
                        (format "%s is none of this session's directories; there is nothing to give up" shown))))))
     ((eq source 'outputs)
      (signal 'harness-error
              (list "The tool output directory holds what long outputs were cut to; it is the harness's, and cannot be given up")))
     ((eq source 'read)
      (harness-access--update session-id
                              (lambda (p) (plist-put p :read-dirs
                                                     (cl-remove-if (lambda (d) (harness-access--same-dir-p d dir))
                                                                   (plist-get p :read-dirs))))
                              (harness-access--hint who (format "%s may no longer be read" shown)))
      (format "%s is no longer readable by this session." shown))
     ((memq source '(session turn))
      (harness-call 'permission/revoke-dir session-id (plist-get entry :dir))
      (when keep-read
        (harness-access--update session-id read
                                (harness-access--hint who (format "%s kept for reading only" shown))))
      (format "%s is no longer granted to this session%s." shown
              (if keep-read "; it may still be read" "")))
     (t
      (harness-access--update session-id
                              (lambda (p)
                                (let ((p (plist-put p :dropped (cons (plist-get entry :dir) (plist-get p :dropped)))))
                                  (if keep-read (funcall read p) p)))
                              (harness-access--hint who (format "%s (%s) given up%s" shown
                                                                (harness-access--source-label source)
                                                                (if keep-read ", kept for reading" ""))))
      (harness-emit 'permission/dir-revoked session-id (plist-get entry :dir))
      (format "%s (%s) is given up for this session%s."
              shown (harness-access--source-label source)
              (if keep-read ": it may still be read, not written" ""))))))

(defun harness-access-restore-dir (session-id dir)
  "Give SESSION-ID back the directory DIR it gave up; for the user.
Kept for reading meanwhile, it is no read-only directory any more.
Return non-nil when DIR was one it had given up."
  (let* ((session (harness-access--session session-id))
         (found (cl-find-if (lambda (d) (harness-access--same-dir-p d dir)) (harness-access-dropped session))))
    (when found
      (harness-access--update session-id
                              (lambda (p)
                                (plist-put (plist-put p :dropped (remove found (plist-get p :dropped)))
                                           :read-dirs (cl-remove-if (lambda (d) (harness-access--same-dir-p d found))
                                                                    (plist-get p :read-dirs))))
                              (harness-access--hint 'user (format "%s given back" (harness-access--abbrev found))))
      (harness-emit 'permission/dir-allowed session-id found)
      t)))

(defun harness-access--read-grant-check (session dir)
  "Return why SESSION needs no read grant of DIR, as text, or nil when it does."
  (let ((holder (harness-access--holder session dir)))
    (when holder
      (format "%s is already %s: it lies inside %s (%s)"
              (harness-access--abbrev dir)
              (if (plist-get holder :read-only) "readable" "readable and writable")
              (harness-access--abbrev (plist-get holder :dir))
              (harness-access--source-label (plist-get holder :source))))))

(defun harness-access-add-read-dir (session-id path &optional who)
  "Let SESSION-ID read the directory PATH, not write it; return what was done.
WHO, `user' or `agent', is named in the transcript's hint.  A
directory the session reaches already is left as it is."
  (let* ((session (harness-access--session session-id))
         (dir (harness-access--dir session path))
         (already (harness-access--read-grant-check session dir)))
    (if already
        (concat already ".")
      (harness-access--update session-id
                              (lambda (p) (plist-put p :read-dirs (append (plist-get p :read-dirs) (list dir))))
                              (harness-access--hint who (format "%s may be read" (harness-access--abbrev dir))))
      (harness-emit 'permission/dir-allowed session-id dir)
      (format "%s may now be read by this session, not written: the tools that only read take paths in it, and bash sees it read-only."
              (harness-access--abbrev dir)))))

(defun harness-access-remove-read-dir (session-id dir)
  "Stop SESSION-ID reading the read-only directory DIR; for the user.
Return non-nil when DIR was one."
  (let* ((session (harness-access--session session-id))
         (found (cl-find-if (lambda (d) (harness-access--same-dir-p d dir)) (harness-access-read-dirs session))))
    (when found
      (harness-access--update session-id
                              (lambda (p) (plist-put p :read-dirs (remove found (plist-get p :read-dirs))))
                              (harness-access--hint 'user (format "%s may no longer be read"
                                                                  (harness-access--abbrev found))))
      (harness-emit 'permission/dir-revoked session-id found)
      t)))

;;;; Network, writing and tools

(defun harness-access-set-network (session-id on &optional who)
  "Let SESSION-ID reach the network when ON, else not; return the profile.
WHO, `user' or `agent', is named in the transcript's hint."
  (harness-access--update session-id
                          (lambda (p) (plist-put p :network (if on nil :false)))
                          (harness-access--hint who (if on "network on" "network off"))))

(defun harness-access-set-read-only (session-id on &optional who)
  "Keep SESSION-ID from writing when ON, else let it; return the profile.
WHO, `user' or `agent', is named in the transcript's hint."
  (harness-access--update session-id
                          (lambda (p) (plist-put p :read-only (and on t)))
                          (harness-access--hint who (if on "writing off: read-only" "writing on"))))

(defun harness-access--check-tool (name)
  "Return NAME, the name of a registered tool, or signal a `harness-error'."
  (let ((name (harness-access--name name)))
    (unless (and name (harness-tool-get name))
      (signal 'harness-error (list (format "No tool is named %s" (or name "(none)")))))
    name))

(defun harness-access-set-tool (session-id tool on &optional who)
  "Turn TOOL on for SESSION-ID when ON, else off; return the profile.
`harness-access-drop-tool' cannot be turned off: giving up access is
always allowed.  WHO, `user' or `agent', is named in the hint."
  (let ((tool (harness-access--check-tool tool)))
    (when (and (not on) (equal tool harness-access-drop-tool))
      (signal 'harness-error (list (format "%s cannot be turned off: a session may always give up access"
                                           harness-access-drop-tool))))
    (harness-access--update session-id
                            (lambda (p)
                              (plist-put p :tools-off
                                         (if on (remove tool (plist-get p :tools-off))
                                           (cons tool (plist-get p :tools-off)))))
                            (harness-access--hint who (format "%s turned %s" tool (if on "on" "off"))))))

(defun harness-access--sandboxed-p (session)
  "Non-nil when the sandbox can confine SESSION's commands, offline included."
  (harness-readonly-confined-p (harness-readonly-dir session)))

(defun harness-access--tool-kind (name)
  "Return the kind of tool NAME, or nil for a name no tool has."
  (let ((tool (harness-tool-get name)))
    (and tool (harness-tool-kind tool))))

(defun harness-access--offline-off-p (name session &optional sandboxed)
  "Non-nil when tool NAME is off for SESSION because it may not reach the network.
SANDBOXED, when given, says whether the sandbox confines SESSION's
commands, `unknown' to look it up."
  (and (not (harness-access-network-p session))
       (or (eq (harness-access--tool-kind name) 'net)
           (member name harness-access-offline-tools)
           (and (member name harness-access-sandboxed-tools)
                (not (if (memq sandboxed '(nil unknown))
                         (harness-access--sandboxed-p session)
                       sandboxed))))
       t))

(defun harness-access--tools (names session)
  "Offer SESSION only the tools of NAMES its profile leaves it.
An `agent/tools' filter at 85, before the read-only policies' at 90.
The tools it turned off go, and without the network those of kind net,
ssh and emacs_eval, and bash and elisp unless the sandbox confines its
commands.  `harness-access-drop-tool' always stays.  A nil SESSION is
the catalogue of every tool and keeps NAMES."
  (if (or (null session) (null (harness-access-profile session)))
      names
    (let ((off (harness-access-tools-off session))
          (sandboxed 'unknown))
      (cl-remove-if (lambda (name)
                      (and (not (equal name harness-access-drop-tool))
                           (or (member name off)
                               (and (not (harness-access-network-p session))
                                    (progn
                                      (when (and (eq sandboxed 'unknown)
                                                 (member name harness-access-sandboxed-tools))
                                        (setq sandboxed (and (harness-access--sandboxed-p session) t)))
                                      (harness-access--offline-off-p name session sandboxed))))))
                    names))))

(defun harness-access--sandbox-options (options session-id)
  "Run SESSION-ID's commands offline when its profile says so.
A `tools/sandbox-options' filter at 80: OPTIONS is what the handlers
before it made.  Options ask for the sandbox, so a command that cannot
have it fails rather than run online.  Anything going wrong here keeps
the network off, the safe side."
  (condition-case err
      (if (harness-access-network-p (harness-call 'session/get session-id))
          options
        (harness-plist-merge options (list :network nil)))
    (error
     (harness-log 'error "access: choosing the sandbox options of %s failed, so they are offline: %S"
                  session-id err)
     (harness-plist-merge options (list :network nil)))))

;;;; The read-only policy

(defun harness-access--readonly-policy (session)
  "Return the read-only policy of SESSION when its profile keeps it from writing."
  (when (harness-access-read-only-p session)
    (list :tools (list harness-access-escalation-tool harness-perms-dir-tool)
          :label "read-only session"
          :doing "gave up writing"
          :hint "This session may only read: carry on reading, or ask the user for writing with request_escalation (attribute writes).")))

;;;; The stage of the access profile

(defun harness-access--deny (reason hint)
  "Return the final denial of the access profile, for REASON with HINT."
  (list :behavior 'deny :final t :by 'access :reason reason :hint hint))

(defun harness-access--settings-file-p (path)
  "Non-nil when PATH names a file whose writing is an escalation."
  (and (stringp path) (member (file-name-nondirectory (directory-file-name path)) harness-access-settings-files) t))

(defconst harness-access--writes-settings-regexp
  "\\(?:>\\|\\btee\\b\\|\\bcp\\b\\|\\bmv\\b\\|\\bln\\b\\|\\binstall\\b\\|\\brsync\\b\\|\\bsed\\b[^|;&]*-i\\|\\bdd\\b\\|\\bperl\\b[^|;&]*-i\\|\\btruncate\\b\\|\\bpatch\\b\\|\\bgit\\b[^|;&]*\\b\\(?:checkout\\|restore\\|apply\\|stash\\|reset\\|mv\\)\\b\\)"
  "What makes a shell command naming a settings file look like it writes it.")

(defun harness-access--settings-target (request)
  "Return the settings file REQUEST would write, or nil.
A call of a tool that does more than read whose paths name one of
`harness-access-settings-files', or a shell command naming one and
looking like it writes (`harness-access--writes-settings-regexp')."
  (let ((kind (harness-perms--sym (plist-get request :kind)))
        (command (let ((input (plist-get request :input))) (and (listp input) (plist-get input :command)))))
    (cond
     ((eq kind 'read) nil)
     ((and (eq kind 'exec) (stringp command))
      (and (string-match "\\.dir-locals\\(?:-2\\)?\\.el" command)
           (string-match-p harness-access--writes-settings-regexp command)
           (match-string 0 command)))
     (t (cl-find-if #'harness-access--settings-file-p (plist-get request :paths))))))

(defun harness-access--profile-refusal (request)
  "Return the decision the access profile makes on REQUEST, or nil.
`harness-access-drop-tool' is allowed at once; a tool turned off, or
one that needs the network the session may not reach, is refused for
good; anything else is left to the stages after it."
  (let* ((session (plist-get request :session))
         (tool (plist-get request :tool)))
    (cond
     ((equal tool harness-access-drop-tool)
      (list :behavior 'allow :final t :by 'access :reason "giving up access never needs approval"))
     ((null (harness-access-profile session)) nil)
     ((member tool (harness-access-tools-off session))
      (harness-access--deny (format "%s is turned off for this session" tool)
                            (format "Do not retry; carry on without it. If the task cannot be done without %s, ask the user for it with request_escalation (attribute tool, value %s)."
                                    tool tool)))
     ((harness-access--offline-off-p tool session)
      (harness-access--deny
       (if (member tool harness-access-sandboxed-tools)
           (format "this session may not reach the network, and %s runs offline only in the sandbox, which cannot confine commands here"
                   tool)
         (format "this session may not reach the network, so it may not use %s" tool))
       "Do not try to reach the network another way. Carry on with what is on this machine, or ask the user for the network with request_escalation (attribute network).")))))

(defun harness-access--gate (decision next request)
  "Apply the session's access profile to REQUEST, then go on with NEXT.
A `permission/decide' stage at 4, before every other: see
`harness-access--profile-refusal'.  A call that writes a settings file
\(`harness-access--settings-target') waits for the user's
confirmation, as an escalation does.  DECISION is the current value.
A call this stage cannot check is refused: it fails closed."
  (let ((verdict (condition-case err
                     (or (harness-access--profile-refusal request)
                         (and (harness-access--settings-target request) 'settings))
                   (error
                    (harness-log 'error "access: checking a call of %s failed, so it is denied: %S"
                                 (plist-get request :tool) err)
                    (harness-access--deny "the access settings of this session could not be checked, so the call is not made"
                                          "Do not retry; say in your answer what you wanted to do.")))))
    (cond
     ((eq verdict 'settings)
      (let ((file (harness-access--settings-target request)))
        (harness-perms-confirm
         request next
         :title (format "Change the harness settings file %s" (file-name-nondirectory file))
         :reason (format "%s sets directory-local variables, the harness's own among them: the directories every session there may reach, the sandbox policy, the permission mode. Writing it can widen what sessions may do, so it is an escalation only you allow."
                         (file-name-nondirectory file))
         :hint "Do not write it another way. Say in your answer what the file should hold, so the user can change it.")))
     (verdict (funcall next verdict))
     (t (funcall next decision)))))

;;;; Escalation: request_escalation

(defun harness-access--nothing (attribute value text)
  "Return the decision for an escalation of ATTRIBUTE (VALUE) that grants nothing.
TEXT says why: the session has it already."
  (list :behavior 'allow :final t :by 'access :reason text
        :input (list :attribute attribute :value value :nothing text)))

(defun harness-access--refuse (reason hint)
  "Return the final refusal of an escalation, for REASON with HINT."
  (harness-access--deny reason hint))

(defun harness-access--why (input)
  "Return the agent's reason in INPUT, as a sentence for the prompt."
  (let ((why (plist-get input :reason)))
    (if (and (stringp why) (not (harness-string-blank-p why)))
        (format "The agent asks: %s." (string-remove-suffix "." (string-trim why)))
      "The agent gave no reason.")))

(defun harness-access--confirm (request next attribute value title reason)
  "Ask the user to raise ATTRIBUTE to VALUE for REQUEST's session.
TITLE and REASON make the prompt; NEXT goes on with the user's answer,
whose allow gives the tool's handler the attribute and the value."
  (harness-perms-confirm request next
                         :title title
                         :reason (concat reason "  " (harness-access--why (plist-get request :input)))
                         :input (list :attribute attribute :value value)
                         :hint "Do not ask for it again; carry on as you are, and say in your answer what you could not do."))

(defun harness-access--escalate-dir (request next path)
  "Decide an escalation for write access to PATH: as request_directory_access does.
REQUEST is the call and NEXT continues the chain; the decision handed
on names the attribute in its `:input', for the handler."
  (harness-perms-decide-dir-request
   request
   (lambda (d)
     (funcall next (if (and (listp d) (plist-get d :input))
                       (plist-put (copy-sequence d) :input
                                  (append (list :attribute "directory") (plist-get d :input)))
                     d)))
   path (plist-get (plist-get request :input) :reason)))

(defun harness-access--escalate-read-dir (request next path)
  "Decide an escalation to read the directory PATH, for REQUEST; NEXT goes on."
  (let* ((session (plist-get request :session))
         (dir (harness-access--dir session path))
         (already (harness-access--read-grant-check session dir))
         (rule (harness-perms--dir-rule session dir)))
    (cond
     (already (funcall next (harness-access--nothing "read_directory" dir already)))
     ((eq (harness-perms--sym (plist-get rule :behavior)) 'deny)
      (funcall next (plist-put (plist-put (harness-perms--rule-decision rule (plist-get session :id)) :final t)
                               :hint "Do not ask for it again; work inside the allowed directories.")))
     (t (harness-perms-confirm
         (plist-put (copy-sequence request) :paths (list dir))
         next
         :title (format "Let the agent read %s" (harness-access--abbrev dir))
         :paths (list dir)
         :reason (concat "It may read the directory, not write it; bash sees it read-only.  "
                         (harness-access--why (plist-get request :input)))
         :input (list :attribute "read_directory" :value dir)
         :hint "Do not ask for it again; work with the directories you have.")))))

(defun harness-access--other-read-only (session)
  "Return the label of the read-only policy of another module governing SESSION.
That is a policy other than the access profile's; nil when none does."
  (let ((policy (condition-case nil
                    (let ((harness-readonly--policies (cl-remove 'access harness-readonly--policies :key #'car)))
                      (harness-readonly-policy session))
                  (error nil))))
    (and policy (or (plist-get policy :label) "a read-only policy"))))

(defun harness-access--escalate (request next)
  "Decide REQUEST, a call of `request_escalation', as only the user may.
NEXT goes on with the decision, which is final: the user's answer, or a
refusal at once when the
request is wrong or nobody can answer (`harness-perms-confirm'), or an
allow that grants nothing when the session has what it asks for."
  (let* ((session (plist-get request :session))
         (input (plist-get request :input))
         (attribute (harness-access--attribute (plist-get input :attribute)))
         (value (harness-access--name (plist-get input :value))))
    (pcase attribute
      ('nil
       (funcall next (harness-access--refuse
                      (format "%s needs attribute, one of %s" harness-access-escalation-tool
                              (string-join harness-access-attributes ", "))
                      "Call it again with the attribute you need.")))
      ((or "directory" "read_directory")
       (if (null value)
           (funcall next (harness-access--refuse (format "%s needs value: the directory" attribute)
                                                 "Call it again with value set to the directory you need."))
         (if (equal attribute "directory")
             (harness-access--escalate-dir request next value)
           (harness-access--escalate-read-dir request next value))))
      ("network"
       (if (harness-access-network-p session)
           (funcall next (harness-access--nothing attribute nil "this session may reach the network already"))
         (harness-access--confirm request next attribute nil "Let the agent reach the network again"
                                  "It gave the network up, or you turned it off: web tools, ssh and emacs_eval come back, and bash runs online.")))
      ("writes"
       (cond
        ((harness-access-read-only-p session)
         (harness-access--confirm request next attribute nil "Let the agent write again"
                                  "The session is read-only: it may write again where its directories allow."))
        ((harness-access--other-read-only session)
         (funcall next (harness-access--refuse
                        (format "this session is read-only by %s, which no escalation changes"
                                (harness-access--other-read-only session))
                        "Carry on reading; say in your answer what should be written.")))
        (t (funcall next (harness-access--nothing attribute nil "this session may write already")))))
      ("tool"
       (cond
        ((null value)
         (funcall next (harness-access--refuse "tool needs value: the tool's name"
                                               "Call it again with value set to the tool you need.")))
        ((null (harness-tool-get value))
         (funcall next (harness-access--refuse (format "no tool is named %s" value) "Check the name.")))
        ((member value (harness-access-tools-off session))
         (harness-access--confirm request next attribute value (format "Turn %s on for the agent again" value)
                                  (format "%s is turned off for this session." value)))
        ((harness-access--offline-off-p value session)
         (funcall next (harness-access--refuse
                        (format "%s is off because this session may not reach the network" value)
                        "Ask for the network instead (attribute network), if the task needs it.")))
        (t (funcall next (harness-access--nothing attribute value
                                                  (format "%s is not turned off for this session" value))))))
      ("permission_mode"
       (let ((mode (harness-access--mode value))
             (current (harness-perms--mode-of session)))
         (cond
          ((null mode)
           (funcall next (harness-access--refuse
                          (format "permission_mode needs value, one of %s"
                                  (mapconcat #'symbol-name harness-access-modes ", "))
                          "Call it again with the mode you need.")))
          ((harness-policy-pinned-p 'harness-permission-mode)
           (funcall next (harness-access--refuse "the policy sets the permission mode, which no escalation changes"
                                                 "Carry on in the mode you have.")))
          ((<= (harness-access--mode-rank mode) (harness-access--mode-rank current))
           (funcall next (harness-access--nothing
                          attribute (symbol-name mode)
                          (format "the session is in %s mode, which is no less permissive than %s; to lower it, use %s"
                                  current mode harness-access-drop-tool))))
          (t (harness-access--confirm request next attribute (symbol-name mode)
                                      (format "Switch the session to %s mode" mode)
                                      (format "It is in %s mode now." current))))))
      ("non_interactive"
       (cond
        ((harness-policy-pinned-p 'harness-non-interactive)
         (funcall next (harness-access--refuse "the policy sets non-interactive mode, which no escalation changes"
                                               "Carry on as you are.")))
        ((harness-perms--non-interactive-p session)
         (funcall next (harness-access--nothing attribute nil "this session is non-interactive already")))
        (t (harness-access--confirm request next attribute nil "Turn non-interactive mode on for this session"
                                    "Nobody is asked anything there until it is turned off again: the auto-mode judge decides what would ask you.")))))))

(defun harness-access--escalation (decision next request)
  "Decide a call of `request_escalation' from the user's answer alone.
A `permission/decide' stage at 5: other calls go on with DECISION.
See `harness-access--escalate'; a request this stage cannot read is
refused."
  (if (not (equal (plist-get request :tool) harness-access-escalation-tool))
      (funcall next decision)
    (condition-case err
        (harness-access--escalate request next)
      (error
       (harness-log 'error "access: deciding an escalation failed: %S" err)
       (funcall next (harness-access--refuse (format "the escalation could not be decided: %s" (harness-error-message err))
                                             "Do not retry; say in your answer what you needed."))))))

(defun harness-access--escalation-result (input ctx)
  "Handler of `request_escalation': grant what the user allowed, and say so.
It runs once the user allowed the call, or once the session had what
it asked for (INPUT's `:nothing' says why), or when the user approved
the call after it was denied and the agent reran it (`rerun_approved'):
then INPUT is the call's own, and its attribute is granted for the
session.  A directory the user granted at the prompt was granted there
\(INPUT's `:path'); CTX names the session."
  (let* ((sid (plist-get ctx :session-id))
         (attribute (harness-access--attribute (plist-get input :attribute)))
         (value (harness-access--name (plist-get input :value)))
         (nothing (plist-get input :nothing)))
    (condition-case err
        (cond
         ((stringp nothing) (harness-tool-ok (format "Nothing to grant: %s." nothing)))
         ((null attribute) (harness-tool-error "Give attribute: what to ask for"))
         ((equal attribute "directory")
          (if (plist-get input :path)
              (harness-perms--dir-request-result input ctx)
            ;; An approved rerun: the user approved this very request.
            (progn (harness-call 'permission/allow-dir sid value)
                   (harness-perms--dir-request-result (list :path value) ctx))))
         ((equal attribute "read_directory")
          (harness-tool-ok (harness-access-add-read-dir sid value 'user)))
         ((equal attribute "network")
          (harness-access-set-network sid t 'user)
          (harness-tool-ok "The user let this session reach the network again: the web tools, ssh and emacs_eval are back from the next request on, and bash runs online."))
         ((equal attribute "writes")
          (harness-access-set-read-only sid nil 'user)
          (harness-tool-ok "The user let this session write again, where its directories allow, from the next request on."))
         ((equal attribute "tool")
          (harness-access-set-tool sid value t 'user)
          (harness-tool-ok (format "The user turned %s on again for this session; it is offered from the next request on." value)))
         ((equal attribute "permission_mode")
          (let ((mode (or (harness-access--mode value) (error "No permission mode %s" value))))
            (harness-call 'session/update sid :permission-mode mode)
            (harness-tool-ok (format "The user switched this session to %s mode." mode))))
         ((equal attribute "non_interactive")
          (harness-call 'session/update sid :non-interactive t)
          (harness-tool-ok "The user turned non-interactive mode on for this session: from now on the auto-mode judge decides what would ask them, and a denied call is to be worked around rather than waited on."))
         (t (harness-tool-error (format "Unknown attribute %s" attribute))))
      (error (harness-tool-error (format "Granting %s failed: %s" attribute (harness-error-message err)))))))

(harness-define-tool harness-access-escalation-tool
  :label "Request escalation"
  :description "Ask the user for more access for this session: a directory to write (attribute directory) or only to read (read_directory), the network back (network), writing back (writes), a tool turned off (tool), a more permissive permission mode (permission_mode: ask, accept-edits, auto or yolo), or non-interactive mode (non_interactive). This is the only way a session's access grows: the user always decides, in every permission mode, and the call waits for the answer; no rule or judge answers it, and a non-interactive session is refused at once. Ask only for what the task needs, and say why. If the user says no, do not ask again. To give access up instead, use drop_access, which never asks."
  :schema '(:type "object"
            :properties (:attribute (:type "string"
                                     :enum ["directory" "read_directory" "writes" "network" "tool" "permission_mode" "non_interactive"]
                                     :description "What to ask for.")
                         :value (:type "string" :description "The directory (absolute or relative to the working directory) for directory and read_directory, the tool's name for tool, the mode for permission_mode; nothing for the others.")
                         :reason (:type "string" :description "Why you need it; shown to the user."))
            :required ("attribute" "reason"))
  :kind 'meta
  :subject (lambda (input)
             (let ((attribute (harness-access--name (plist-get input :attribute)))
                   (value (harness-access--name (plist-get input :value))))
               (string-trim (format "%s %s" (or attribute "") (or value "")))))
  :handler #'harness-access--escalation-result)

;;;; Relinquishing: drop_access

(defun harness-access--drop (input ctx)
  "Handler of `drop_access': give up what INPUT names, for CTX's session.
Allowed at once by the stage at 4 (`harness-access--profile-refusal'):
a session may always take access away from itself."
  (let* ((sid (plist-get ctx :session-id))
         (attribute (harness-access--attribute (plist-get input :attribute)))
         (value (harness-access--name (plist-get input :value)))
         (back "Ask the user with request_escalation if you need it again."))
    (condition-case err
        (pcase attribute
          ('nil (harness-tool-error (format "Give attribute, one of %s"
                                            (string-join (remove "read_directory" harness-access-attributes) ", "))))
          ((or "directory" "read_directory")
           (if (null value)
               (harness-tool-error "Give value: the directory to give up")
             (harness-tool-ok (concat (harness-access-drop-dir sid value (harness-json-true-p (plist-get input :keep_read))
                                                               'agent)
                                      " " back))))
          ("network"
           (harness-access-set-network sid nil 'agent)
           (harness-tool-ok (concat "This session may no longer reach the network: the web tools, ssh and emacs_eval are gone from the next request on, and bash runs offline in the sandbox (or not at all where the sandbox cannot confine it). " back)))
          ("writes"
           (harness-access-set-read-only sid t 'agent)
           (harness-tool-ok (concat "This session is read-only now: from the next request on it has only the reading tools, and bash runs read-only and offline in the sandbox. " back)))
          ("tool"
           (if (null value)
               (harness-tool-error "Give value: the tool to turn off")
             (harness-access-set-tool sid value nil 'agent)
             (harness-tool-ok (format "%s is turned off for this session from the next request on. %s" value back))))
          ("permission_mode"
           (let* ((session (harness-access--session sid))
                  (mode (harness-access--mode value))
                  (current (harness-perms--mode-of session)))
             (cond
              ((null mode)
               (harness-tool-error (format "Give value, one of %s" (mapconcat #'symbol-name harness-access-modes ", "))))
              ((eq mode current) (harness-tool-ok (format "The session is in %s mode already." mode)))
              ((> (harness-access--mode-rank mode) (harness-access--mode-rank current))
               (harness-tool-error (format "%s is more permissive than %s, the session's mode: ask the user for it with %s"
                                           mode current harness-access-escalation-tool)))
              (t (harness-call 'session/update sid :permission-mode mode)
                 (harness-tool-ok (format "The session is in %s mode now, down from %s. %s" mode current back))))))
          ("non_interactive"
           (let ((session (harness-access--session sid)))
             (if (not (harness-perms--non-interactive-p session))
                 (harness-tool-ok "The session is interactive already: the user is asked.")
               (harness-call 'session/update sid :non-interactive :false)
               (harness-tool-ok "Non-interactive mode is off for this session: the user is asked again what its permission mode leaves open.")))))
      (error (harness-tool-error (harness-error-message err))))))

(harness-define-tool harness-access-drop-tool
  :label "Drop access"
  :description "Give up access this session has, at once and without asking anyone: a directory (attribute directory: a grant, the working directory, the worktree, the temporary directory or a configured directory; keep_read keeps it readable), the network (network), writing (writes: the session becomes read-only), a tool (tool), a permission mode for a less permissive one (permission_mode), or non-interactive mode (non_interactive). Use it when you are done with something or want to be sure you cannot touch it. Sub-agents you start keep what you gave up. Getting it back takes the user's answer to request_escalation."
  :schema '(:type "object"
            :properties (:attribute (:type "string"
                                     :enum ["directory" "writes" "network" "tool" "permission_mode" "non_interactive"]
                                     :description "What to give up.")
                         :value (:type "string" :description "The directory for directory, the tool's name for tool, the less permissive mode for permission_mode; nothing for the others.")
                         :keep_read (:type "boolean" :description "For directory: keep reading it, give up writing it only (default false).")
                         :reason (:type "string" :description "Why, for the record."))
            :required ("attribute"))
  :kind 'meta
  :subject (lambda (input)
             (let ((attribute (harness-access--name (plist-get input :attribute)))
                   (value (harness-access--name (plist-get input :value))))
               (string-trim (format "%s %s" (or attribute "") (or value "")))))
  :handler #'harness-access--drop)

;;;; Sub-agents and forks

(defun harness-access--inherit (session-id plist)
  "Give SESSION-ID, just created with PLIST, its parent's restrictions.
A `session/created' subscriber.  A session with a parent -- a sub-agent,
a fork -- other than a BTW takes the network, writing, the tools and
the directories its parent gave up; a fork also takes the directories
its parent may only read, as it takes its grants.  Nothing is copied
when the parent has no profile."
  (let ((parent-id (plist-get plist :parent-id)))
    (when (and (stringp parent-id)
               (not (eq (harness-perms--sym (plist-get plist :kind)) 'btw)))
      (condition-case err
          (when-let* ((parent (ignore-errors (harness-call 'session/get parent-id)))
                      (profile (harness-access-profile parent)))
            (let ((inherited (harness-access--normalise
                              (append (harness-plist-remove profile :read-dirs)
                                      (and (plist-get plist :fork-node)
                                           (list :read-dirs (plist-get profile :read-dirs)))))))
              (when inherited
                (harness-access--update session-id
                                        (lambda (own)
                                          (list :network (if (or (eq (plist-get own :network) :false)
                                                                 (eq (plist-get inherited :network) :false))
                                                             :false)
                                                :read-only (or (plist-get own :read-only) (plist-get inherited :read-only))
                                                :tools-off (append (plist-get own :tools-off) (plist-get inherited :tools-off))
                                                :read-dirs (append (plist-get own :read-dirs) (plist-get inherited :read-dirs))
                                                :dropped (append (plist-get own :dropped) (plist-get inherited :dropped))))
                                        "Access: the restrictions of the session that started this one (set by its parent)."))))
        (error (harness-log 'error "access: giving %s its parent's restrictions failed: %S" session-id err))))))

;;;; Judgements

(defvar harness-access--judged (make-hash-table :test 'equal)
  "Session id -> the judgements of its calls in this run, newest first.
Each is a plist as `harness-access--record' makes it.")

(defconst harness-access--judged-kept 300
  "How many judgements a session keeps in memory.
The transcript keeps every call's, in its result node.")

(defun harness-access--behavior (decision)
  "Return DECISION's behavior: `allow', or `deny' for anything else."
  (if (eq (harness-perms--sym (plist-get decision :behavior)) 'allow) 'allow 'deny))

(defun harness-access--record (session-id request decision)
  "Keep the judgement DECISION made on REQUEST of SESSION-ID.
A `permission/decided' subscriber; announced as `access/judged'."
  (let ((call-id (plist-get request :call-id)))
    (when (and (stringp session-id) (stringp call-id))
      (let* ((record (list :call-id call-id
                           :tool (plist-get request :tool)
                           :behavior (harness-access--behavior decision)
                           :by (harness-tools-decision-by decision)
                           :reason (plist-get decision :reason)
                           :hint (plist-get decision :hint)
                           :at (float-time)))
             (kept (cons record (cl-remove call-id (gethash session-id harness-access--judged)
                                           :key (lambda (r) (plist-get r :call-id)) :test #'equal))))
        (puthash session-id (seq-take kept harness-access--judged-kept) harness-access--judged)
        (harness-emit 'access/judged session-id record)))))

(defun harness-access--judgement-of (session-id call-id)
  "Return the judgement kept in memory for CALL-ID of SESSION-ID, or nil."
  (cl-find call-id (gethash session-id harness-access--judged)
           :key (lambda (r) (plist-get r :call-id)) :test #'equal))

(defun harness-access--stamp-result (result session-id call)
  "Put the judgement of CALL into RESULT's `:meta', which the transcript keeps.
A `tools/result' filter: SESSION-ID ran CALL.  The judgement is
\(:behavior B :by BY :reason R), as `harness-access--record' kept it."
  (let ((record (and (listp call) (harness-access--judgement-of session-id (plist-get call :id)))))
    (if (and record (listp result))
        (plist-put (copy-sequence result) :meta
                   (append (list :judgement (list :behavior (plist-get record :behavior)
                                                  :by (plist-get record :by)
                                                  :reason (plist-get record :reason)))
                           (harness-plist-remove (plist-get result :meta) :judgement)))
      result)))

(defun harness-access--forget (session-id &rest _)
  "Forget the judgements of SESSION-ID, which is gone."
  (remhash session-id harness-access--judged))

(defconst harness-access--trim-chars 4000
  "Characters a listing keeps of a call's output and of each value of its input.")

(defun harness-access--trim (value)
  "Return VALUE, a node's input or one of its values, with long strings cut."
  (cond ((and (stringp value) (> (length value) harness-access--trim-chars))
         (concat (substring value 0 harness-access--trim-chars) "\n[…]"))
        ((and (consp value) (proper-list-p value)) (mapcar #'harness-access--trim value))
        (t value)))

(defun harness-access--trim-node (node)
  "Return NODE with its input and output cut for a listing."
  (when node
    (let ((node (copy-sequence node)))
      (when (plist-get node :input) (setq node (plist-put node :input (harness-access--trim (plist-get node :input)))))
      (when (stringp (plist-get node :output))
        (setq node (plist-put node :output (harness-access--trim (plist-get node :output)))))
      node)))

(defun harness-access--denied-reason (result)
  "Return the reason a denied RESULT node gives, from its output, or nil."
  (let ((text (plist-get result :output)))
    (and (stringp text)
         (string-match "\\`Denied: \\([^\n]*\\)" text)
         (let ((reason (match-string 1 text)))
           ;; The hint and the approval note follow the reason on its line.
           (car (split-string reason "\\. " t))))))

(defun harness-access--judgement (result memory pending)
  "Return the judgement of a call node from its RESULT, MEMORY and PENDING.
RESULT's `:judgement' says, else MEMORY, the record kept this run, else
what RESULT shows: `:denied' or not.  A call PENDING, a request waiting
for the user, is undecided: `ask'."
  (let* ((meta (and result (plist-get result :meta)))
         (stamped (and meta (plist-get meta :judgement))))
    (cond
     (pending (list :behavior 'ask :by 'user :reason (or (plist-get (plist-get pending :payload) :reason)
                                                         "waiting for your answer")))
     ((and (listp stamped) stamped)
      (list :behavior (harness-perms--sym (plist-get stamped :behavior))
            :by (harness-perms--sym (plist-get stamped :by))
            :reason (plist-get stamped :reason)))
     (memory (list :behavior (plist-get memory :behavior) :by (plist-get memory :by)
                   :reason (plist-get memory :reason)))
     ((null result) (list :behavior 'unknown :by nil :reason nil))
     ((harness-json-true-p (plist-get meta :denied))
      (list :behavior 'deny :by nil :reason (harness-access--denied-reason result)))
     (t (list :behavior 'allow :by nil :reason nil)))))

(defun harness-access--matches-p (item filter)
  "Non-nil when judgement ITEM passes FILTER, a plist of the listing's options."
  (let ((behavior (harness-perms--sym (plist-get filter :behavior)))
        (by (harness-perms--sym (plist-get filter :by)))
        (tool (harness-access--name (plist-get filter :tool)))
        (query (harness-access--name (plist-get filter :query))))
    (and (or (null behavior) (eq behavior 'all)
             (eq behavior (plist-get item :behavior))
             ;; Asked: what the user decided, or still has to.
             (and (eq behavior 'asked) (eq (plist-get item :by) 'user)))
         (or (null by) (eq by (plist-get item :by)))
         (or (null tool) (equal tool (plist-get item :tool)))
         (or (null query)
             (let ((case-fold-search t)
                   (rx (regexp-quote query)))
               (cl-some (lambda (s) (and (stringp s) (string-match-p rx s)))
                        (list (plist-get item :tool) (plist-get item :reason) (plist-get item :call-id)
                              (plist-get item :subject))))))))

(defun harness-access--subject (call)
  "Return a one-line description of the CALL node's input, for searching."
  (condition-case nil
      (harness-first-line (harness-tool-title (plist-get call :tool) (plist-get call :input)) 200)
    (error nil)))

(defun harness-access-judgements (session-id &optional filter)
  "Return the judgements of SESSION-ID's calls, as `access/judgements' does.
FILTER is a plist: `:behavior' (allow, deny, ask -- waiting for the
user -- or asked, what the user decided or has to), `:by' (who
decided, see `harness-tools-decision-by'), `:tool', `:query' (text in
the tool, the reason, the call id or the call's title) and `:limit'
\(the newest so many, 200 by default)."
  (let* ((nodes (harness-call 'session/nodes session-id))
         (results (make-hash-table :test 'equal))
         (pending (make-hash-table :test 'equal))
         (limit (let ((l (plist-get filter :limit)))
                  (if (and (integerp l) (> l 0)) (min l 1000) 200)))
         (items nil)
         (counts (list :allow 0 :deny 0 :ask 0))
         (tools nil) (bys nil))
    (dolist (n nodes)
      (when (and (eq (harness-perms--sym (plist-get n :kind)) 'tool-result) (plist-get n :call-id))
        (puthash (plist-get n :call-id) n results)))
    (when (harness-method-exists-p 'permission/pending)
      (dolist (p (ignore-errors (harness-call 'permission/pending session-id)))
        (when-let* ((cid (plist-get (plist-get p :payload) :call-id)))
          (puthash cid p pending))))
    (dolist (call nodes)
      (when (and (eq (harness-perms--sym (plist-get call :kind)) 'tool-call) (plist-get call :call-id))
        (let* ((cid (plist-get call :call-id))
               (result (gethash cid results))
               (waiting (and (null result) (gethash cid pending)))
               (judgement (harness-access--judgement result (harness-access--judgement-of session-id cid)
                                                     waiting))
               (meta (and result (plist-get result :meta)))
               (behavior (plist-get judgement :behavior))
               (item (append (list :call-id cid
                                   :tool (plist-get call :tool)
                                   :subject (harness-access--subject call)
                                   :at (or (plist-get call :ts) (plist-get call :created)))
                             judgement
                             (list :pending-id (and waiting (plist-get waiting :id))
                                   :approved (and meta (harness-json-true-p (plist-get meta :approved)))
                                   :used (and meta (harness-json-true-p (plist-get meta :used)))))))
          (when (memq behavior '(allow deny ask))
            (plist-put counts (intern (format ":%s" behavior))
                       (1+ (plist-get counts (intern (format ":%s" behavior))))))
          (cl-pushnew (plist-get call :tool) tools :test #'equal)
          (when (plist-get item :by) (cl-pushnew (plist-get item :by) bys))
          (when (harness-access--matches-p item filter)
            (push (cons item (cons call result)) items)))))
    ;; ITEMS is newest first already.
    (let ((total (length items)))
      (list :items (mapcar (lambda (e)
                             (append (car e)
                                     (list :call (harness-access--trim-node (cadr e))
                                           :result (harness-access--trim-node (cddr e)))))
                           (seq-take items limit))
            :total total
            :counts counts
            :tools (sort tools #'string<)
            :by (sort (mapcar #'symbol-name bys) #'string<)))))

;;;; Describing a session's access

(defun harness-access--sandbox (session)
  "Return what the sandbox does for SESSION's commands, as a plist."
  (let* ((status (and (harness-method-exists-p 'sandbox/status)
                      (ignore-errors (harness-call 'sandbox/status))))
         (dir (harness-readonly-dir session))
         (remote (and (stringp dir) (file-remote-p dir) t)))
    (list :backend (or (plist-get status :backend) 'none)
          :available (plist-get status :available)
          :policy (or (and (harness-method-exists-p 'config/get)
                           (ignore-errors (harness-call 'config/get 'harness-sandbox-policy
                                                        (plist-get session :cwd))))
                      (plist-get status :policy))
          :confined (and (harness-readonly-confined-p dir) t)
          :remote remote
          :module (and status t))))

(defconst harness-access--elsewhere "not for this kind of session"
  "Why a tool that belongs to other kinds of session is not offered.
Such as hand_in, a task's, or the plan tools of a supervising session:
it is no restriction anyone set.")

(defun harness-access--off-reason (name session offered)
  "Return why tool NAME is not offered to SESSION, or nil when it is.
OFFERED are the names it is offered."
  (cond
   ((member name offered) nil)
   ((member name (harness-access-tools-off session)) "turned off")
   ((harness-access--offline-off-p name session) "no network")
   ((and (harness-tool-get name)
         (harness-tools--corporate-off-p name (harness-access--tool-kind name)))
    "corporate mode")
   ((let ((policy (ignore-errors (harness-readonly-policy session))))
      (and policy (not (member name (harness-readonly-allowed-tools policy)))
           (format "read-only (%s)" (or (plist-get policy :label) "policy")))))
   (t harness-access--elsewhere)))

(defun harness-access--tool-entries (session-id session)
  "Return the tools of SESSION-ID as (:on NAMES :off ENTRIES :builtin NAMES).
OFF entries are (:name NAME :why TEXT :profile BOOL :elsewhere BOOL),
PROFILE non-nil for a tool the profile turned off, which the user can
turn on, ELSEWHERE for one that belongs to other kinds of session
\(`harness-access--elsewhere'), which nobody turned off."
  (let* ((offered (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list session-id)))
         (builtin (and (harness-method-exists-p 'tools/builtin)
                       (ignore-errors (harness-call 'tools/builtin session-id))))
         (all (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list)))
         (on (append offered builtin))
         (off (delq nil (mapcar (lambda (name)
                                  (unless (member name on)
                                    (let ((why (harness-access--off-reason name session on)))
                                      (list :name name :why why
                                            :profile (and (member name (harness-access-tools-off session)) t)
                                            :elsewhere (and (equal why harness-access--elsewhere) t)))))
                                all))))
    (list :on (sort (copy-sequence on) #'string<) :off off :builtin builtin)))

(defun harness-access--describe-dirs (session-id session)
  "Return SESSION-ID's directories for the access view.
They are `permission/dirs' entries, each with `:read-only', and the
directories it gave up, with `:dropped' t.  A directory it gave up but
kept for reading is its read-only entry, with `:given-up' t."
  (let* ((entries (harness-call 'permission/dirs session-id))
         (all-dropped (harness-access-dropped session))
         (given-up-p (lambda (dir) (cl-some (lambda (d) (harness-access--same-dir-p d dir)) all-dropped)))
         (dropped (cl-remove-if (lambda (d) (cl-find-if (lambda (e) (harness-access--same-dir-p (plist-get e :dir) d))
                                                       entries))
                                all-dropped)))
    (append (mapcar (lambda (e)
                      (let ((ro (and (harness-json-true-p (plist-get e :read-only)) t)))
                        (append (harness-plist-remove e :read-only)
                                (list :read-only ro)
                                (and ro (funcall given-up-p (plist-get e :dir)) (list :given-up t)))))
                    entries)
            (mapcar (lambda (d) (list :dir d :source 'dropped :dropped t :revocable nil :read-only nil)) dropped))))

(defun harness-access-describe (session-id)
  "Return everything about SESSION-ID's access, as `access/describe' does."
  (let* ((session (harness-access--session session-id))
         (rules (harness-call 'permission/rules session-id))
         (other-ro (harness-access--other-read-only session)))
    (list :session (list :id session-id :name (plist-get session :name) :cwd (plist-get session :cwd)
                         :host (plist-get session :host) :worktree (plist-get session :worktree)
                         :kind (plist-get session :kind) :status (plist-get session :status)
                         :parent-id (plist-get session :parent-id))
          :sandbox (harness-access--sandbox session)
          :mode (plist-get rules :mode)
          :mode-pinned (and (harness-policy-pinned-p 'harness-permission-mode) t)
          :non-interactive (plist-get rules :non-interactive)
          :non-interactive-pinned (and (harness-policy-pinned-p 'harness-non-interactive) t)
          :network (and (harness-access-network-p session) t)
          :corporate (and (boundp 'harness-corporate-mode) harness-corporate-mode t)
          :read-only (or (harness-access-read-only-p session) (and other-ro t))
          :read-only-profile (harness-access-read-only-p session)
          :read-only-by other-ro
          :profile (harness-access-profile session)
          :dirs (harness-access--describe-dirs session-id session)
          :inspect (plist-get rules :inspect)
          :skills (plist-get rules :skills)
          :tools (harness-access--tool-entries session-id session)
          :never-ask (plist-get rules :auto-allow)
          :rules (list :session (plist-get rules :session) :always (plist-get rules :always)
                       :pinned (and (harness-policy-pinned-p 'harness-perms-rules) t)))))

;;;; Methods

(harness-defmethod access/describe (session-id)
  "Return everything about SESSION-ID's access, for the access view.
A plist: `:session' (id, name, cwd, host, worktree, kind, status),
`:sandbox' (`:backend', `:available', `:policy', `:confined' -- whether
commands in its directory run confined -- `:remote'), `:mode' and
`:mode-pinned', `:non-interactive' and `:non-interactive-pinned',
`:network', `:corporate', `:read-only' with `:read-only-profile' (its
own) and `:read-only-by' (another module's policy), `:profile', `:dirs'
\(`permission/dirs' entries with `:read-only', and the directories it
gave up with `:dropped'), `:inspect' and `:skills' (directories every
read may reach), `:tools' (`:on', `:off' entries with `:why',
`:builtin'), `:never-ask' and `:rules' (`:session', `:always',
`:pinned')."
  (harness-access-describe session-id))

(harness-defmethod access/judgements (session-id &rest filter)
  "Return the judgements of SESSION-ID's calls, newest first.
FILTER: `:behavior' (allow, deny, ask, asked or all), `:by', `:tool',
`:query', `:limit'; see `harness-access-judgements'.  The result is
\(:items ITEMS :total N :counts (:allow N :deny N :ask N) :tools NAMES
:by LABELS): ITEMS the judgements that pass, each (:call-id :tool
:subject :at :behavior :by :reason :pending-id :approved :used :call
NODE :result NODE), the nodes cut for a listing; TOTAL how many pass;
the counts and the names over every call of the session."
  (harness-access-judgements session-id filter))

(harness-defmethod access/set-network (session-id on)
  "Let SESSION-ID reach the network when ON is true, else not; for the user."
  (harness-access-set-network session-id (harness-json-true-p on) 'user)
  t)

(harness-defmethod access/set-read-only (session-id on)
  "Keep SESSION-ID from writing when ON is true, else let it; for the user."
  (harness-access-set-read-only session-id (harness-json-true-p on) 'user)
  t)

(harness-defmethod access/set-tool (session-id tool on)
  "Turn TOOL on for SESSION-ID when ON is true, else off; for the user."
  (harness-access-set-tool session-id tool (harness-json-true-p on) 'user)
  t)

(harness-defmethod access/add-read-dir (session-id dir)
  "Let SESSION-ID read DIR but not write it; for the user.  Return what was done."
  (harness-access-add-read-dir session-id dir 'user))

(harness-defmethod access/remove-read-dir (session-id dir)
  "Stop SESSION-ID reading the read-only directory DIR; for the user."
  (or (harness-access-remove-read-dir session-id dir)
      (signal 'harness-error (list (format "%s is no read-only directory of this session"
                                           (harness-access--abbrev dir))))))

(harness-defmethod access/drop-dir (session-id dir &optional keep-read)
  "Take DIR away from SESSION-ID, keeping it readable with KEEP-READ; for the user.
See `harness-access-drop-dir'.  Return what was done, as text."
  (harness-access-drop-dir session-id dir (harness-json-true-p keep-read) 'user))

(harness-defmethod access/restore-dir (session-id dir)
  "Give SESSION-ID back the directory DIR it gave up; for the user."
  (or (harness-access-restore-dir session-id dir)
      (signal 'harness-error (list (format "%s was not given up" (harness-access--abbrev dir))))))

;;;; Module

(defun harness-access--on-session-updated (session-id changes)
  "Announce that SESSION-ID's access changed when CHANGES touch it.
CHANGES are the session's changed fields: its permission mode, its
non-interactive switch, its directories."
  (when (cl-some (lambda (k) (plist-member changes k))
                 '(:permission-mode :non-interactive :allowed-dirs :cwd :worktree :host))
    (harness-emit 'access/changed session-id)))

(harness-declare-event 'access/changed
                       "(SESSION-ID) after what SESSION-ID may reach changed: its access profile, its mode, its non-interactive switch.")
(harness-declare-event 'access/judged
                       "(SESSION-ID RECORD) after the permission chain decided a call of SESSION-ID; RECORD is (:call-id :tool :behavior :by :reason :hint :at).")

(defun harness-access--init ()
  "Hook the module into the bus (idempotent)."
  (harness-add-filter 'permission/dir-entries #'harness-access--dir-entries 50)
  (harness-add-filter 'agent/tools #'harness-access--tools 85)
  (harness-add-filter 'permission/decide #'harness-access--gate 4)
  (harness-add-filter 'permission/decide #'harness-access--escalation 5)
  (harness-add-filter 'tools/sandbox-options #'harness-access--sandbox-options 80)
  (harness-add-filter 'tools/result #'harness-access--stamp-result 95)
  (harness-readonly-register 'access #'harness-access--readonly-policy)
  (harness-on 'permission/decided #'harness-access--record)
  (harness-on 'session/created #'harness-access--inherit)
  (harness-on 'session/deleted #'harness-access--forget)
  (harness-on 'session/updated #'harness-access--on-session-updated))

(defun harness-access--shutdown ()
  "Take the module off the bus."
  (harness-remove-filter 'permission/dir-entries #'harness-access--dir-entries)
  (harness-remove-filter 'agent/tools #'harness-access--tools)
  (harness-remove-filter 'permission/decide #'harness-access--gate)
  (harness-remove-filter 'permission/decide #'harness-access--escalation)
  (harness-remove-filter 'tools/sandbox-options #'harness-access--sandbox-options)
  (harness-remove-filter 'tools/result #'harness-access--stamp-result)
  (harness-readonly-unregister 'access)
  (harness-off (cons 'permission/decided #'harness-access--record))
  (harness-off (cons 'session/created #'harness-access--inherit))
  (harness-off (cons 'session/deleted #'harness-access--forget))
  (harness-off (cons 'session/updated #'harness-access--on-session-updated)))

(put 'harness-access--gate 'harness-permission-stage 'access)
(put 'harness-access--escalation 'harness-permission-stage 'access)

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'access)
  (harness-access--init))

(harness-define-module 'access
  :doc "What a session may reach, in one place: its access profile (network, writing, tools, read-only and given-up directories), request_escalation, which only the user answers, drop_access, which never asks, and the record of every permission judgement."
  :requires '(perms session tools readonly)
  :init #'harness-access--init
  :shutdown #'harness-access--shutdown)

(provide 'harness-access)
;;; harness-access.el ends here
