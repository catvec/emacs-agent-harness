;;; harness-secret-sandbox.el --- Secret files used in a locked sandbox  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A secret should be usable by a command without its value ever reaching
;; the agent.  The harness already knows which values are secrets: the
;; user declares them in `harness-secrets-sources' (or adds them with
;; `secrets/add-source'), and the secrets module reads each one, gives it
;; the label of its placeholder and masks it wherever it appears.  That
;; list is the whole marking.  This module adds nothing to it -- no
;; second option, no key on an entry, no per-secret settings.  Declaring
;; a secret is saying "to use this, run your tool in the secret sandbox".
;;
;; What the module adds is the other half of that sentence.  A secret's
;; source is hidden from every command and denied to the file tools, so
;; the agent cannot read the value itself, and the only way to use it is
;; `run_with_secret', which runs one command in the locked profile of the
;; sandbox -- with the value in a per-call file of its own -- and returns
;; one fixed sentence: the command's output, exit status and duration
;; never reach the agent.
;;
;; One list.  The label the agent asks for is the label the secrets
;; module masks the value under; the source it names is the source the
;; secrets module reads; a run takes the value the registry already
;; resolved, so a file is read once and a command source runs once for
;; both.  A secret that comes from the harness's environment or from a
;; literal in the user's init file cannot be used in a locked run -- the
;; agent's own commands inherit the environment, and the literal is in a
;; variable it can read -- and `list_secrets' says so, with the reason.
;;
;; Why the output is withheld.  Masking cannot be made complete: a
;; command can write the value base64 of base64, enciphered, hashed, one
;; character per line, a length, an exit status or a timing, and no list
;; of spellings can enumerate every transformation.  Nor can a command
;; line be inspected to know what a program will read: `python script.py'
;; can print the value and looks like nothing.  So this module tries
;; neither.  The guarantee is structural: stdout, stderr, the exit status
;; and the duration are dropped before the result is made.  The agent
;; gets the same sentence whether the command printed the value, failed
;; or timed out.
;;
;; What the command may do.  It runs with `bash -c' in the session's
;; working directory, read-only, with only the sandbox's private
;; temporary directory writable, no capability, a minimal environment,
;; the network off, and one per-call directory holding the value (mode
;; 0600, made 0700 for the call and deleted when it ends), at
;; `$HARNESS_SECRET_FILE'.  The source file itself is not mounted.  The
;; user approves every call, in every mode, seeing the exact command;
;; nothing is remembered.  What remains is timing -- the agent can
;; compare its own clock before and after -- and the side effects of a
;; command the user approved.  Neither returns the value.
;;
;; Keeping the agent out.  A `permission/decide' stage at priority 2
;; refuses, finally and in every mode, a read or a write whose paths
;; touch a secret's source; `list_dir', `glob' and `file_info' may still
;; say the file exists.  A `tools/sandbox-options' handler hides every
;; source, and every live secret directory, from every bash and elisp
;; command.  A source inside the harness's state directory, or inside the
;; session's own working or temporary directory, is refused at run time:
;; the agent could have read it before the secret existed.
;;
;; The sentence the agent gets after a run is the prompt
;; `secret-sandbox-withheld', registered here (harness-prompts.el), so a
;; model can be given its own wording like any other prompt
;; (`harness-prompt-overrides').  docs/secret-sandbox.md is the page for
;; this module: what marking is, what a run may use, and why the output
;; is not returned.
;;
;; Methods: `secret-sandbox/run', `secret-sandbox/secrets',
;; `secret-sandbox/status'.  Tools: `run_with_secret', `list_secrets'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-redaction)
(require 'harness-secrets)
(require 'harness-sandbox)
(require 'harness-perms)
(require 'harness-tools)
(require 'harness-prompts)

(defvar harness-secrets--entries)
(defvar harness-secrets-mask)
(defvar harness-perms-extra-auto-allow-tools)
(defvar harness-state-directory)

;;;; Settings

(defconst harness-secret-sandbox--default-timeout 120
  "Seconds a locked run may take unless its call says otherwise.")

(defconst harness-secret-sandbox--max-timeout 600
  "Most seconds a locked run may take, whatever the call asks.")

(defconst harness-secret-sandbox--result-timeout 660
  "Seconds the tool call may take, above the longest run it starts.")

(defconst harness-secret-sandbox--listing-tools '("list_dir" "glob" "file_info")
  "Tools that may name a source without reading it.
They show that a file exists, its size and its metadata; none of them
reads the contents, so the source stays out of their reach.")

(defconst harness-secret-sandbox--withheld-default
  "The command ran in the locked sandbox.  Its output, exit status and duration are not returned to you."
  "The default text of the `secret-sandbox-withheld' prompt.
It says nothing the command could have chosen: not the output, not the
exit status, not how long it took, and not whether it timed out.")

(harness-prompt-register 'secret-sandbox-withheld
                         :module 'secret-sandbox
                         :purpose "Tells the agent that a locked run's output, exit status and duration are not returned."
                         :used-by "harness-secret-sandbox--withheld"
                         :variables nil
                         :template harness-secret-sandbox--withheld-default)

(defun harness-secret-sandbox--withheld (session)
  "Return what the agent of SESSION is told after a locked run.
That is the `secret-sandbox-withheld' prompt, with SESSION's model's
override of it when one is set, and `harness-secret-sandbox--withheld-default'
otherwise."
  (harness-prompt-effective 'secret-sandbox-withheld
                            harness-secret-sandbox--withheld-default
                            (plist-get session :model)))

;;;; The secrets
;;
;; Nothing here is a declaration: the list is the one the secrets module
;; already keeps, and every value in it is a secret the agent may not
;; read.  What this section adds is the label -> value view the tools use
;; and the reason a value cannot be used in a locked run.

(defvar harness-secret-sandbox--last-use (make-hash-table :test 'equal)
  "When each label's last run ended, by label, as a `float-time'.
The outcome is not kept: an exit status or a duration is a fact about a
run the agent must not learn, and the UI has no use for it either.")

(defvar harness-secret-sandbox--live nil
  "Directories holding a locked run's secret file right now.
Every other command hides them (`tools/sandbox-options'), and a tool
whose paths touch one is refused (`permission/decide').")

(defun harness-secret-sandbox--entries ()
  "Return the secrets registry's entries, looked at again when due.
The registry is the one masking uses, so a value is read once for both.
A refresh that fails is logged there and the entries stay as they were."
  (harness-secrets--registry)
  harness-secrets--entries)

(defun harness-secret-sandbox--ref-file (ref)
  "Return the file REF reads, made absolute, or nil."
  (let ((file (and (consp ref) (plist-get ref :file))))
    (and (stringp file) (expand-file-name file))))

(defun harness-secret-sandbox--ref-kind (ref)
  "Return what REF reads: `file', `command', `env', `literal', or nil."
  (cond ((stringp (plist-get ref :file)) 'file)
        ((stringp (plist-get ref :command)) 'command)
        ((stringp (plist-get ref :env)) 'env)
        ((stringp (plist-get ref :literal)) 'literal)))

(defun harness-secret-sandbox--secret-error (entry kind)
  "Return why a value of registry ENTRY, of KIND, cannot be used in a run."
  (let ((ref (plist-get entry :ref)))
    (cond
     ((plist-get entry :error)
      (format "its source cannot be read: %s" (plist-get entry :error)))
     ((eq kind 'env)
      "it comes from an environment variable of the harness, which every command the harness starts inherits; keep it in a file to use it in a locked run")
     ((eq kind 'literal)
      "it is a literal in harness-secrets-sources, a variable the agent can read; keep it in a file to use it in a locked run")
     ((not (memq kind '(file command)))
      "its source is not one a locked run can read")
     ((and (eq kind 'file)
           (boundp 'harness-state-directory)
           (stringp harness-state-directory)
           (harness-path-within-p (expand-file-name harness-state-directory)
                                  (harness-secret-sandbox--ref-file ref)))
      "its source is in the harness's state directory, where the agent's own tools can read it; move the file out"))))

(defun harness-secret-sandbox--secrets ()
  "Return one plist per value the harness masks, in registry order.
Each is (:label :value :fingerprint :source :ref :entry :error): the
label the agent asks for, the value, the first 8 hex digits of its
SHA-256, where it is read, its reference, the registry entry it came
from, and why a locked run cannot use it.  A value with an error keeps
it and is listed with the reason; a label two values share is an error
on both, since the agent names a secret by its label."
  (let ((entries (harness-secret-sandbox--entries))
        (counts (make-hash-table :test 'equal))
        (out nil))
    (dolist (entry entries)
      (dolist (secret (plist-get entry :secrets))
        (let ((label (plist-get secret :label)))
          (when (stringp label)
            (puthash label (1+ (gethash label counts 0)) counts)))))
    (dolist (entry entries)
      (let ((kind (harness-secret-sandbox--ref-kind (plist-get entry :ref))))
        (dolist (secret (plist-get entry :secrets))
          (let ((label (plist-get secret :label)))
            (when (stringp label)
              (push (list :label label
                          :value (plist-get secret :value)
                          :fingerprint (plist-get secret :fingerprint)
                          :source (or (plist-get secret :source) (plist-get entry :source))
                          :ref (plist-get entry :ref)
                          :entry entry
                          :error (or (and (> (gethash label counts 0) 1)
                                          (format "the label %S names %d secrets; give each its own :label"
                                                  label (gethash label counts 0)))
                                     (harness-secret-sandbox--secret-error entry kind)))
                    out))))))
    (nreverse out)))

(defun harness-secret-sandbox--labels ()
  "Return the labels the agent may ask for, in the registry's order.
A secret a locked run cannot use is not offered."
  (delq nil (mapcar (lambda (secret)
                      (and (not (plist-get secret :error))
                           (plist-get secret :label)))
                    (harness-secret-sandbox--secrets))))

(defun harness-secret-sandbox--find (label)
  "Return the secret named LABEL, or nil."
  (and (stringp label)
       (cl-find label (harness-secret-sandbox--secrets)
                :key (lambda (secret) (plist-get secret :label)) :test #'equal)))

(defun harness-secret-sandbox--source-paths ()
  "Return the file of every secret, so that no command sees one.
A source that cannot be read is still hidden: its file is the secret's."
  (delete-dups (delq nil (mapcar (lambda (entry)
                                   (harness-secret-sandbox--ref-file (plist-get entry :ref)))
                                 (harness-secret-sandbox--entries)))))

(defun harness-secret-sandbox--hide-paths ()
  "Return the paths every command must not see.
The sources of the secrets, and the live secret directories."
  (delete-dups (append (harness-secret-sandbox--source-paths)
                       (copy-sequence harness-secret-sandbox--live))))

;;;; The value

(defun harness-secret-sandbox--source-problem (secret session)
  "Return why SECRET's source may not be used for SESSION, or nil.
A source in the session's working directory or temporary directory is
refused: the agent could have read it with its own tools before the
secret was declared.  So is one in the harness's state directory, which
the agent's inspection exception can read; that is checked here too, in
case the state directory changed since the registry was read."
  (let* ((file (harness-secret-sandbox--ref-file (plist-get secret :ref)))
         (cwd (plist-get session :cwd))
         (tmp (and (harness-method-exists-p 'session/tmp-dir)
                   (ignore-errors (harness-call 'session/tmp-dir (plist-get session :id))))))
    (cond
     ((and file (boundp 'harness-state-directory)
           (stringp harness-state-directory)
           (harness-path-within-p (expand-file-name harness-state-directory) file))
      "its source is in the harness's state directory, where the agent's own tools can read it; move the file out")
     ((and file
           (or (and (stringp cwd) (harness-path-within-p cwd file))
               (and (stringp tmp) (harness-path-within-p tmp file))))
      (format "its source is in %s, which the agent can read with its own tools; move the file out of the working directory and the session's temporary directory"
              (abbreviate-file-name (if (and (stringp cwd) (harness-path-within-p cwd file))
                                        cwd tmp)))))))

(defun harness-secret-sandbox--run-problem (session secret command)
  "Return why a locked run for SESSION of SECRET with COMMAND cannot start, or nil.
Everything here is checked before the prompt, and nothing runs the
command: a value a locked run cannot use, a backend without the locked
profile and a source in the session's directories all refuse."
  (let ((profiles (condition-case err
                      (harness-call 'sandbox/profiles (plist-get session :cwd))
                    (error
                     (harness-log 'warn "secret-sandbox: asking what the sandbox can give failed: %s"
                                  (harness-error-message err))
                     (list :profiles nil :network nil
                           :why "the sandbox module cannot say what it enforces")))))
    (cond
     ((not harness-secrets-mask)
      "masking is off (harness-secrets-mask), and the secret's value would not be kept out of what the harness stores")
     ((not (memq 'locked (plist-get profiles :profiles)))
      (format "the locked sandbox is not available: %s" (or (plist-get profiles :why) "no sandbox backend")))
     ((null secret) nil)
     ((plist-get secret :error)
      (format "the secret %S cannot be used: %s" (plist-get secret :label) (plist-get secret :error)))
     ;; A source the session could already have read is refused before its
     ;; value is written anywhere.
     ((harness-secret-sandbox--source-problem secret session))
     ((not (and (stringp command) (not (harness-string-blank-p command))))
      "it needs a command to run"))))

;;;; The locked run

(defun harness-secret-sandbox--shell ()
  "Return the shell a locked command runs in."
  (if (file-executable-p "/bin/bash") "/bin/bash" "/bin/sh"))

(defun harness-secret-sandbox--make-secret-dir (value)
  "Make the directory of one locked run, holding VALUE in a file named secret.
The directory is mode 0700 and the file 0600; the value is written as
UTF-8 without a newline of our own.  Return the directory."
  (let* ((dir (with-file-modes #o700 (make-temp-file "harness-secret-" t)))
         (file (expand-file-name "secret" dir))
         (coding-system-for-write 'utf-8-unix))
    (with-file-modes #o600
      (write-region value nil file nil 'silent))
    dir))

(defun harness-secret-sandbox--timeout (asked)
  "Return the seconds a locked run may take, ASKED or the default.
The call's number is capped by `harness-secret-sandbox--max-timeout'."
  (let ((asked (if (and (natnump asked) (> asked 0))
                   asked
                 harness-secret-sandbox--default-timeout)))
    (max 1 (min asked harness-secret-sandbox--max-timeout))))

(defun harness-secret-sandbox--finish (secret session)
  "Return the fixed result of a locked run of SECRET in SESSION.
Nothing the command printed, nor its exit status or duration, is part
of it: see the commentary.  Only when the run ended is kept, for the
access view."
  (puthash (plist-get secret :label) (float-time) harness-secret-sandbox--last-use)
  (harness-tool-ok (harness-secret-sandbox--withheld session)
                   :meta (list :secret (plist-get secret :label) :withheld t)))

(harness-defmethod secret-sandbox/run (session-id label command &optional timeout)
  "Run COMMAND in the locked sandbox with the secret LABEL for SESSION-ID.
Return a tool result whose text is one fixed sentence: the command's
stdout, stderr, exit status and duration are not part of it, whether it
succeeded, failed or timed out.  The command runs with `bash -c' in the
session's working directory, which is read-only, with only the private
temporary directory writable and no network; the value is in the file
`$HARNESS_SECRET_FILE'.  The directory holding it is deleted when the
call ends, times out or fails, and its path is never part of the result.
An unknown label, a secret no locked run can use, masking off and no
backend that can give the locked profile are all errors before the
command starts.

LABEL is one of the labels the secrets module masks a value under, and
TIMEOUT the seconds the run may take, 120 by default and at most 600."
  (let* ((session (harness-call 'session/get session-id))
         (secret (harness-secret-sandbox--find label))
         (problem (cond
                   ((not (stringp label))
                    "it needs the label of a secret; list_secrets names the ones you may use")
                   ((null secret)
                    (format "no secret is labelled %S; list_secrets names the ones you may use" label))
                   (t (harness-secret-sandbox--run-problem session secret command)))))
    (if problem
        (harness-tool-error problem)
      (let* ((cwd (plist-get session :cwd))
             (value (plist-get secret :value))
             (dir (harness-secret-sandbox--make-secret-dir value))
             (file (expand-file-name "secret" dir))
             (seconds (harness-secret-sandbox--timeout timeout))
             (line (list (harness-secret-sandbox--shell) "-c" command))
             (options (list :profile 'locked
                            :network nil
                            :env (list (cons "HARNESS_SECRET_FILE" file)
                                       (cons "HARNESS_SECRET_LABEL" label))
                            :hide (harness-secret-sandbox--hide-paths)
                            :readable (list dir)
                            :read-only t))
             (cleaned nil))
        (cl-labels
            ((cleanup ()
               (unless cleaned
                 (setq cleaned t)
                 (setq harness-secret-sandbox--live
                       (delete dir harness-secret-sandbox--live))
                 (ignore-errors (delete-directory dir t)))))
          (condition-case err
              (let ((wrapped (apply #'harness-call 'sandbox/wrap cwd line options)))
                (push dir harness-secret-sandbox--live)
                (harness-then
                 (harness-run-command wrapped :cwd cwd :timeout seconds
                                      :name "run-with-secret")
                 (lambda (_result)
                   (cleanup)
                   (harness-secret-sandbox--finish secret session))
                 (lambda (err)
                   (cleanup)
                   (harness-tool-error
                    (format "The locked command could not run: %s"
                            (harness-error-message err))))))
            (error
             (cleanup)
             (harness-tool-error
              (format "The locked command cannot run: %s" (harness-error-message err))))))))))

;;;; Tools

(harness-define-tool "run_with_secret"
  :label "Run with secret"
  :description "Run one shell command in a locked sandbox with a secret it may read out of a file. Use it when a command needs a credential (an API token, a deploy key, a password) that its tool would otherwise read from a file. The secret is a label from list_secrets. The command runs with bash -c in the working directory, which is read-only, with only its private temporary directory writable and no network; the value is in $HARNESS_SECRET_FILE. Its output is not returned: stdout, stderr, the exit status and the duration are withheld, so nothing a command prints reaches you. Use it for what the command does, not to learn anything it prints. The user approves every use, once, seeing the exact command; nothing is remembered. An unknown label lists the labels; a locked run the sandbox cannot give fails before anything runs."
  :schema '(:type "object"
            :properties (:secret (:type "string" :description "The label of a secret, as list_secrets names it.")
                         :command (:type "string" :description "One shell command line, run by bash -c in the working directory. Read the value from $HARNESS_SECRET_FILE. Its output is not returned.")
                         :timeout (:type "integer" :description "Seconds the command may run. Default 120, at most 600."))
            :required ("secret" "command"))
  :kind 'exec
  :timeout harness-secret-sandbox--result-timeout
  :subject (lambda (input)
             (when-let* ((label (plist-get input :secret)))
               (format "%s: %s" label (harness-truncate-end (or (plist-get input :command) "") 60))))
  :handler (lambda (input ctx)
             (harness-call 'secret-sandbox/run
                           (or (plist-get ctx :session-id)
                               (bound-and-true-p harness-tools-calling-session))
                           (plist-get input :secret)
                           (plist-get input :command)
                           (plist-get input :timeout))))

(defun harness-secret-sandbox--public-entry (secret)
  "Return SECRET as `list_secrets' may show it: no path, value or fingerprint."
  (append (list :label (plist-get secret :label)
                :available (not (plist-get secret :error)))
          (when-let* ((error-text (plist-get secret :error)))
            (list :error error-text))))

(harness-define-tool "list_secrets"
  :label "List secrets"
  :description "List the secrets a locked command may use, by label. It never shows a value, a path or a fingerprint; a secret that cannot be used says why. An entry with \"available\": false cannot be used. Use a label with run_with_secret."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :timeout 30
  :handler (lambda (_input _ctx)
             (harness-tool-ok
              (harness-json-encode
               (list :secrets (harness-json-array
                               (mapcar #'harness-secret-sandbox--public-entry
                                       (harness-secret-sandbox--secrets))))))))

;;;; Keeping the agent out and asking the user

(defun harness-secret-sandbox--real (path)
  "Return PATH with its symbolic links followed where it exists, else expanded."
  (directory-file-name
   (or (ignore-errors (file-truename path))
       (expand-file-name path))))

(defun harness-secret-sandbox--overlap (path file)
  "Return non-nil when PATH and FILE touch.
They touch when they name the same file, or one holds the other, as they
are named and as their symbolic links lead."
  (and (stringp file) (stringp path)
       (cl-some (lambda (pair)
                  (let ((a (car pair)) (b (cdr pair)))
                    (or (harness-path-within-p a b)
                        (harness-path-within-p b a))))
                (list (cons file path)
                      (cons (harness-secret-sandbox--real file)
                            (harness-secret-sandbox--real path))))))

(defun harness-secret-sandbox--conflict (paths)
  "Return (PATH . SECRET) for the first of PATHS that touches a source, or nil.
A path is also refused when it touches a locked run's live secret
directory; its SECRET is nil then."
  (let ((secrets (harness-secret-sandbox--secrets)))
    (catch 'conflict
      (dolist (path paths)
        (when (and (stringp path) (not (file-remote-p path)))
          (let ((real (expand-file-name path)))
            (when-let* ((secret (cl-find-if
                                 (lambda (secret)
                                   (harness-secret-sandbox--overlap
                                    real (harness-secret-sandbox--ref-file
                                          (plist-get secret :ref))))
                                 secrets)))
              (throw 'conflict (cons real secret)))
            (when (cl-some (lambda (dir) (or (harness-path-within-p dir real)
                                             (harness-path-within-p real dir)))
                           harness-secret-sandbox--live)
              (throw 'conflict (cons real nil))))))
      nil)))

(defun harness-secret-sandbox--file-gate (decision next request)
  "Refuse a call that would read or write a secret's source.
A `permission/decide' stage at priority 2, before the jail, the mode and
the judge: the refusal is final and no answer can approve it, because
the only way to use the value is `run_with_secret'.  `list_dir', `glob'
and `file_info' still say the file exists; they read no contents.  A
shell or elisp call is left to the sandbox's `:hide', which the
`tools/sandbox-options' filter below gives every command.  REQUEST is
the call; DECISION is handed to NEXT as it is for every other call."
  (let* ((kind (plist-get request :kind))
         (tool (format "%s" (plist-get request :tool)))
         (paths (plist-get request :paths))
         (conflict (and paths (memq kind '(read write))
                        (not (member tool harness-secret-sandbox--listing-tools))
                        (harness-secret-sandbox--conflict paths))))
    (if (null conflict)
        (funcall next decision)
      (let* ((path (car conflict))
             (secret (cdr conflict))
             (what (if secret
                       (format "the source of the secret %S" (plist-get secret :label))
                     "a locked run's secret file")))
        (funcall next
                 (list :behavior 'deny :final t
                       :reason (format "it would read %s, which is %s"
                                       (abbreviate-file-name path) what)
                       :hint "Do not read or write it: use the secret with run_with_secret, or leave it alone. No approval can open it to a file tool."))))))

(defun harness-secret-sandbox--prompt-reason (request secret)
  "Return what the user is told about REQUEST, a call for SECRET."
  (let* ((input (plist-get request :input))
         (cwd (or (plist-get (plist-get request :session) :cwd) default-directory)))
    (format "Use secret %S\nSource       %s\nFingerprint  sha256:%s\nCommand      %s\nRuns in      %s (read-only)\nNetwork      none\nSandbox      locked: only this secret and the system runtime; the command's output, exit status and duration are not returned to the agent."
            (plist-get secret :label)
            (or (plist-get secret :source) "unknown")
            (or (plist-get secret :fingerprint) "unknown")
            (plist-get input :command)
            (abbreviate-file-name cwd))))

(defun harness-secret-sandbox--permission (decision next request)
  "Ask the user about a call to `run_with_secret'; only they may answer.
A `permission/decide' stage at priority 21, after the mode and the
standing rules (20) and before the auto-mode judge (30): a standing
deny still denies, and a standing allow or yolo does not decide this
call.  The prompt offers allow-once and deny-once and nothing is
recorded, so every use is looked at.  Before the prompt the stage
refuses a run the module cannot make: masking off, a backend without
the locked profile, an unknown label, a secret no locked run can use or
a source inside the session's own directories.  A non-interactive
session is denied at once by `harness-perms-confirm'.  REQUEST is the
call, and DECISION is handed to NEXT as it is for every other call."
  (if (not (equal (plist-get request :tool) "run_with_secret"))
      (funcall next decision)
    (let* ((input (plist-get request :input))
           (label (plist-get input :secret))
           (session (plist-get request :session))
           (secret (harness-secret-sandbox--find label))
           (problem (if (harness-perms--non-interactive-p session)
                        nil
                      (cond
                       ((not (stringp label))
                        "the call needs the label of a secret; list_secrets names them")
                       ((null secret)
                        (format "no secret is labelled %S; list_secrets names the ones you may use" label))
                       (t (harness-secret-sandbox--run-problem session secret (plist-get input :command)))))))
      (cond
       ((eq (harness-perms--sym (plist-get decision :behavior)) 'deny)
        (funcall next decision))
       (problem
        (funcall next (list :behavior 'deny :final t :reason problem
                            :hint "Do not retry the same call; say in your answer what is missing, so the user can set it up.")))
       (t
        (harness-perms-confirm
         request next
         :title (format "Use secret %S" label)
         :reason (harness-secret-sandbox--prompt-reason request secret)
         :paths nil
         :hint "Do not ask again unless the user wants it; say in your answer what you needed the secret for."))))))

(defun harness-secret-sandbox--sandbox-options (options &rest _)
  "Give every command the sources of the secrets to hide.
The `tools/sandbox-options' handler: OPTIONS comes back as it is without
a source, and then `:hide' lists every source and every live secret
directory, which `sandbox/wrap' keeps out of the command's sight."
  (let ((paths (harness-secret-sandbox--hide-paths)))
    (if (null paths)
        options
      (plist-put (copy-sequence options) :hide
                 (delete-dups (append (plist-get options :hide) paths))))))

;;;; Methods

(defun harness-secret-sandbox--describe (secret)
  "Return SECRET for a client: source, fingerprint and last use, never a value."
  (append (list :label (plist-get secret :label)
                :source (plist-get secret :source)
                :fingerprint (plist-get secret :fingerprint)
                :usable (not (plist-get secret :error)))
          (when-let* ((error-text (plist-get secret :error)))
            (list :error error-text))
          (when-let* ((time (gethash (plist-get secret :label) harness-secret-sandbox--last-use)))
            (list :last-use time))))

(harness-defmethod secret-sandbox/secrets ()
  "List the secrets, without a value.
Each is (:label :source :fingerprint :usable :error :last-use): the
label the agent asks for, where the value is read, the first 8 hex
digits of its SHA-256, whether a locked run can use it now, why not when
it cannot, and when it was last used.  A value is never part of the
answer, and neither is anything that holds one."
  (mapcar #'harness-secret-sandbox--describe (harness-secret-sandbox--secrets)))

(harness-defmethod secret-sandbox/status ()
  "Say whether a locked run can be made now, and why not when it cannot.
Return (:mask BOOL :backend BACKEND :profiles (PROFILE…) :locked BOOL
:why TEXT :secrets N :usable N :broken N :live N).  `:mask' says
whether tool output is masked (`harness-secrets-mask'), which a locked
run requires; `:locked' whether the backend can give the locked profile
\(see `sandbox/profiles'); `:why' what stands in the way, when something
does; the counts are the secrets the harness masks, those a locked run
can use, those it cannot, and the locked runs going on now."
  (let* ((profiles (harness-call 'sandbox/profiles nil))
         (secrets (harness-secret-sandbox--secrets))
         (usable (cl-count-if (lambda (secret) (not (plist-get secret :error))) secrets))
         (total (length secrets))
         (locked (and harness-secrets-mask (memq 'locked (plist-get profiles :profiles)) t))
         (why (cond ((not harness-secrets-mask)
                     "masking is off (harness-secrets-mask), so the secret's value would not be kept out of what the harness stores")
                    ((not (memq 'locked (plist-get profiles :profiles)))
                     (or (plist-get profiles :why) "no sandbox backend can give the locked profile")))))
    (list :mask (and harness-secrets-mask t)
          :backend (plist-get profiles :backend)
          :profiles (plist-get profiles :profiles)
          :locked locked
          :why why
          :secrets total
          :usable usable
          :broken (- total usable)
          :live (length harness-secret-sandbox--live))))

;;;; Installing

(defun harness-secret-sandbox--install ()
  "Install the stages and the hide handler, and auto-allow the listing.
Safe to call again."
  (harness-add-filter 'permission/decide #'harness-secret-sandbox--file-gate 2)
  (harness-add-filter 'permission/decide #'harness-secret-sandbox--permission 21)
  (harness-add-filter 'tools/sandbox-options #'harness-secret-sandbox--sandbox-options 50)
  (add-to-list 'harness-perms-extra-auto-allow-tools "list_secrets"))

(defun harness-secret-sandbox--uninstall ()
  "Remove the stages and the hide handler, and forget the live runs."
  (harness-remove-filter 'permission/decide #'harness-secret-sandbox--file-gate)
  (harness-remove-filter 'permission/decide #'harness-secret-sandbox--permission)
  (harness-remove-filter 'tools/sandbox-options #'harness-secret-sandbox--sandbox-options)
  (setq harness-perms-extra-auto-allow-tools
        (delete "list_secrets" harness-perms-extra-auto-allow-tools))
  (setq harness-secret-sandbox--live nil))

(defun harness-secret-sandbox--init ()
  "Install the stages and the hide handler."
  (harness-secret-sandbox--install))

;; A reload does not run `:init' again for a ready module.
(harness-secret-sandbox--install)

(harness-define-module 'secret-sandbox
  :doc "Secret files a locked sandbox lets a command use, never the agent."
  :requires '(secrets sandbox perms session)
  :init #'harness-secret-sandbox--init
  :shutdown #'harness-secret-sandbox--uninstall)

(provide 'harness-secret-sandbox)
;;; harness-secret-sandbox.el ends here
