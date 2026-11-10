;;; harness-computers.el --- Computers: the machines that offer tools and resources  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A client and a computer are not the same thing.  A *client* is a
;; program that speaks ACP to the harness to see its state and act on
;; it: the Emacs UI, a phone, a browser tab.  A *computer* is a machine
;; the harness may use.  It offers tools, as MCP servers a client on it
;; runs and keeps, and resources: a git repository, a directory, a
;; display, a graphics card.  A client may run on a computer, and says
;; so when it connects; that is a fact about the client, not a
;; registration.
;;
;; The harness server keeps every record of this module and runs the
;; event loop.  A computer keeps none: it answers the MCP messages the
;; harness sends over the ACP connection of the client that runs there,
;; and that client runs and manages the MCP servers.  The harness is an
;; MCP host like any other; it is never a program on the computer.
;;
;; A client may run the server itself, and this Emacs's UI does: with
;; `harness-process' on, `harness-server-spawn' starts an `emacs --batch'
;; child of the client's own Emacs.  That gives the server no computer:
;; its state, its model and its web requests are what it offers, and
;; every machine's tools come from a client that registered the computer
;; it runs on.  The coding tools the harness ships (`bash', the file
;; tools, `elisp') run in a session's sandbox beside the server, not on
;; a computer; a deployment that leaves their modules out is a chat.
;;
;; * Registration
;;
;; The machine a client runs on is a fact the client advertises in its
;; `initialize' (`clientCapabilities._harness.computer'), and a fact is
;; not a registration: it tells the harness where the client is, and
;; makes a session the client creates able to ask for that computer.  A
;; computer is registered only by an explicit act from a client on it,
;; the server's own machine included, and only that client runs its MCP
;; servers.  Nothing is registered on a client's behalf, and the harness
;; server keeps no computer of its own.  Until a computer is registered,
;; the computer tools and the modes that need one say what is missing
;; and wait for a grant.
;;
;; * Registration, identity and authentication
;;
;; `computer/register' is the explicit act that gives the harness access
;; to a machine.  The client makes a 256-bit secret and sends it
;; once; the record keeps a salted SHA-256 of it, never the secret, and
;; the client keeps the secret (mode 600, in
;; `harness-computer-endpoint-secret-file').  `computer/attach' presents
;; it again after a reconnect, in constant time comparison.  The
;; registration also hands the client a token, which the harness sends
;; with every `_harness/computer/mcp' request: the client checks it, so
;; the MCP session is bound to the registration in both directions.  A
;; transport proves less than the secret: the ACP token lets a client
;; speak ACP, the secret lets this computer's MCP servers speak for it.
;; Both are required, and the harness serves a computer's MCP only on
;; the connection of the client bound to it.
;;
;; * Capabilities: computer use, like completion providers
;;
;; Computer use (seeing a GUI, moving the pointer, typing, the clipboard,
;; audio) is a generic interface: the harness offers a fixed vocabulary
;; of tools (`harness-tools-computers'), and a computer declares which
;; capabilities its implementation has -- `view', `windows', `pointer',
;; `keyboard', `clipboard', `audio', `camera', `files', `sandbox',
;; `exec' -- with
;; `harness-computers-define-capability' for more.  An implementation
;; may be window-scoped (`:window-scoped'): its `view' can name one
;; window, not only the desktop, and a session's grant may name that
;; window and no other.  That is the shape a Wayland compositor's
;; portals fit (a window's stream, and input for it), as it is the shape
;; of a sandboxed desktop: least privilege is a window or a desktop, not
;; the whole machine.
;;
;; Each capability is a permission of its own.  A session's grant of a
;; computer is `(:computer ID :capabilities (NAMES...) :window NAME)';
;; the access profile keeps them in `:computers', the computers it may
;; not use in `:computers-off'.  The permission chain's gate at 7
;; (`harness-computers--gate') refuses, for good, a call whose computer
;; is not allowed or whose grant does not hold the capability it needs.
;; The user raises a grant with `request_escalation' (attribute
;; `computer', `capabilities', `window') and the agent gives it up with
;; `drop_access' (attribute `computer'); `computer/grant' and
;; `computer/revoke' are the same change for the user, who is asked
;; nothing.  The defaults are least privilege:
;;
;; - no computer is allowed by default (`auto');
;; - a session the user creates from a client on a registered computer
;;   may use that computer, and is not pinned to it;
;; - a task session may use the computer of the project resource it
;;   works on;
;; - a workspace episode may use every computer (`all');
;; - `harness-computers-access' and `harness-computer' are settings that
;;   layer by project and directory like the permission mode
;;   (`harness-config-keys'), and a session's ext overrides them.
;;
;; Viewing a computer is not a session's to be given: a client may watch
;; any computer it can reach, and the page that lists computers shows
;; what each one's screen is, with a button to take control and give it
;; back.  Only what a session's agent may do there is gated, and while a
;; person has control of a computer the agent's pointer, keyboard,
;; clipboard writes and programs wait (`:control' below).
;;
;; * Resources and projects
;;
;; A computer offers resources: `git-repo', `directory', `display',
;; `gpu', `audio', and anything else a client names.  A resource is
;; identified by its computer and a stable id, not by a path of this
;; machine: the same repository can be a resource of several computers,
;; each with its own path, branch and worktrees.  `computer/projects' is
;; the computer-independent list of git repositories, which is empty
;; until a client registers the computer that offers them.
;; A path is what a tool needs to run, and each resource carries the
;; path its own computer knows.
;;
;; * Sidecars and programs
;;
;; A program the harness runs for itself (a transcription program, a
;; voice pipeline's WebRTC endpoint) is not a computer's tool server.
;; It runs where its work is: next to the harness server when it offers
;; an API other processes share (the live voice pipeline, so every
;; client can connect to one), or in a session's sandbox when it only
;; serves that session.  None of it runs on a computer's client for the
;; harness's own work; a computer runs an MCP server only when its tools
;; act on that computer.
;;
;; * Methods and events
;;
;; `computer/list', `computer/get', `computer/access',
;; `computer/projects', `computer/resources', `computer/register',
;; `computer/register-remote', `computer/attach', `computer/update',
;; `computer/unregister', `computer/grant', `computer/revoke',
;; `computer/set-preference', `computer/take-control' and
;; `computer/release-control'.  `computers/check', `computers/call',
;; `computers/tools' and `computers/update-resources' are the harness's
;; own, not callable over ACP.
;; `computers/changed' (ID WHAT) says one changed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-instance)
(require 'harness-store)
(require 'harness-acp)
(require 'harness-mcp)

(defvar harness-acp--calling-client)
(declare-function harness-acp-client-remote-info "harness-acp" (client))
(declare-function harness-acp-client-kind "harness-acp" (client))
(declare-function harness-acp--client-request "harness-acp" (client method params callback))
(declare-function harness-mcp-define-server "harness-mcp" (&rest args))
(declare-function harness-mcp-attach "harness-mcp" (server send &rest args))
(declare-function harness-mcp-detach "harness-mcp" (conn &optional reason))
(declare-function harness-mcp-call-tool "harness-mcp" (server tool input ctx &optional timeout meta key))
(declare-function harness-mcp-tools "harness-mcp" (server &optional ctx key))

(defgroup harness-computers nil
  "Computers the harness may use."
  :group 'harness
  :prefix "harness-computer")

(defconst harness-computers--store "computers.json"
  "The store document that keeps the registered computers.")

(defconst harness-computers--secret-bytes 32
  "Bytes of entropy in a computer's MCP token.")

(defcustom harness-computers-access 'auto
  "Which computers a session may use by default.
`auto' is least privilege: the computer of the client the session was
made from when that computer is registered, the computers of the
session's resources, and a workspace's every computer; `all' is every
registered computer; `none' is no computer at all, so the session is a
chat with the harness's state and its model, and the tools that need a
machine say so.  A project or a directory overrides it in
.dir-locals.el, and a session's own grants and revocations override
that."
  :type '(choice (const :tag "The client's and resources' computers" auto)
                 (const :tag "Every computer" all)
                 (const :tag "No computer" none))
  :safe (lambda (v) (memq v '(auto all none)))
  :group 'harness-computers)

(defcustom harness-computer nil
  "The computer a session uses when a call names none, or nil.
A computer's id or name, as `computer/list' shows them.  It is a setting
like the model: a project or a directory overrides it in
.dir-locals.el, and a session's own preference
\(`computer/set-preference') overrides that.  A call that names a
computer, and a resource that belongs to one, still go to the computer
they name: this is a default, not a pin."
  :type '(choice (const :tag "The first that fits" nil) string)
  :safe #'stringp
  :group 'harness-computers)

(defconst harness-computers-capability-names
  '("view" "windows" "pointer" "keyboard" "clipboard" "audio" "camera" "files"
    "sandbox" "exec" "skills")
  "The capabilities of the computer-use interface.
`view' sees the screen or one window, `windows' lists the windows of the
desktop, `pointer' moves the pointer, clicks and scrolls, `keyboard'
types text and presses keys, `clipboard' reads and writes the clipboard,
`audio' uses the microphone and the speakers, `sandbox' is a desktop
separate from the computer's own, `exec' runs programs there, and
`skills' reads the skills the computer advertises, by their stable id.
An implementation declares the ones it has, and may define more with
`harness-computers-define-capability'.")

(defconst harness-computers--capability-docs
  '(("view" . "See the screen or one window.")
    ("windows" . "List the windows of the desktop.")
    ("pointer" . "Move the pointer, click and scroll.")
    ("keyboard" . "Type text and press keys.")
    ("clipboard" . "Read and write the clipboard.")
    ("audio" . "Use the microphone and the speakers.")
    ("camera" . "Take a picture with the computer's camera.")
    ("files" . "Read and write the files the computer offers, and no others.")
    ("sandbox" . "A desktop separate from the computer's own.")
    ("exec" . "Run programs on the computer.")
    ("skills" . "Read the skills the computer advertises, and no file of it."))
  "What each capability lets a call do, for prompts and pages.")

(defvar harness-computers--capabilities nil
  "The computer-use capabilities this harness knows, by name.
`harness-computers-capability-names' to begin with; modules add theirs
with `harness-computers-define-capability'.")

(defun harness-computers-define-capability (name &optional doc)
  "Define a computer-use capability NAME, with DOC for people to read.
An implementation may declare it in `:capabilities', and a tool may need
it.  A capability `harness-computers-capability-names' already names
keeps its doc when DOC is nil."
  (let* ((name (harness-computers--name name))
         (doc (or doc (cdr (assoc name harness-computers--capability-docs)))))
    (when name
      (unless (member name harness-computers-capability-names)
        (setq harness-computers-capability-names
              (append harness-computers-capability-names (list name))))
      (setf (alist-get name harness-computers--capability-docs nil nil #'equal) doc)
      name)))

(defun harness-computers-capability-doc (name)
  "Return what computer-use capability NAME lets a call do."
  (or (cdr (assoc name harness-computers--capability-docs))
      "A capability of the computer's implementation."))

;;;; Small helpers

(defun harness-computers--name (value)
  "Return VALUE as a trimmed non-blank string, or nil."
  (cond ((stringp value) (and (not (harness-string-blank-p value)) (string-trim value)))
        ((and value (symbolp value) (not (keywordp value))) (symbol-name value))))

(defun harness-computers--sym (value)
  "Return VALUE as a symbol when it names one, else nil."
  (cond ((and value (symbolp value)) value)
        ((and (stringp value) (not (harness-string-blank-p value))) (intern value))))

(defun harness-computers--state (value)
  "Return VALUE, a computer's state, as a symbol."
  (let ((sym (harness-computers--sym value)))
    (if (memq sym '(connected registered disconnected)) sym 'registered)))

(defun harness-computers--strings (value)
  "Return VALUE as a list of non-blank lowercase strings, without duplicates."
  (let ((items (cond ((stringp value) (list value))
                     ((listp value) value)
                     (t nil))))
    (delete-dups
     (delq nil (mapcar (lambda (v)
                         (let ((s (harness-computers--name v)))
                           (and s (downcase s))))
                       items)))))

(defun harness-computers--id (value)
  "Return VALUE as a computer id: lowercase letters, digits and dashes."
  (when-let* ((name (harness-computers--name value)))
    (let* ((slug (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase name)))
           (slug (string-trim slug "-" "-")))
      (unless (harness-string-blank-p slug)
        (if (string-prefix-p "cmp-" slug) slug (concat "cmp-" slug))))))

(defun harness-computers--now () (float-time))

;; The known capabilities, once the helpers below can read their names.
(dolist (pair harness-computers--capability-docs)
  (harness-computers-define-capability (car pair) (cdr pair)))

;;;; Records

(defvar harness-computers--computers (make-hash-table :test 'equal)
  "Computer id -> its record, a plist the harness keeps.
Runtime keys `:client', `:mcp' and `:mcp-token' never reach the store.")

(defvar harness-computers--client-info (make-hash-table :test #'eq)
  "ACP client -> the computer it runs on, as its `initialize' described it.
The description is a fact about the client, not a registration.")

(defvar harness-computers--client-binding (make-hash-table :test #'eq)
  "ACP client -> the id of the computer whose MCP it serves.")

(defvar harness-computers--loaded nil
  "Non-nil once the registry has been read from the store.")

(defun harness-computers--public (record)
  "Return RECORD as a client may see it: no secret and no transport."
  (when (consp record)
    (let ((copy (harness-plist-remove
                 (copy-sequence record) :secret :mcp :mcp-token :client :server-symbols)))
      (plist-put copy :connected (harness-computers-connected-p copy)))))

(defun harness-computers--stored (record)
  "Return RECORD as it goes to the store: what outlives the process."
  (harness-plist-remove (copy-sequence record)
                        :client :mcp :mcp-token :server-symbols :connected))

(defun harness-computers--sorted-records ()
  "Return every computer record, by name."
  (let ((records (let (out)
                   (maphash (lambda (_ r) (push r out)) harness-computers--computers)
                   out)))
    (sort records (lambda (a b)
                    (string-lessp (downcase (or (plist-get a :name) ""))
                                  (downcase (or (plist-get b :name) "")))))))

(defun harness-computers--unique-name (name &optional except)
  "Return NAME, with a number after it when another computer has it.
EXCEPT is an id whose record may keep its name."
  (let ((base (or (harness-computers--name name) "computer"))
        (n 1) candidate)
    (setq candidate base)
    (while (cl-some (lambda (r)
                      (and (not (equal (plist-get r :id) except))
                           (string-equal (downcase (or (plist-get r :name) ""))
                                         (downcase candidate))))
                    (harness-computers--sorted-records))
      (cl-incf n)
      (setq candidate (format "%s (%d)" base n)))
    candidate))

(defun harness-computers--normalise-resource (resource &optional computer)
  "Return RESOURCE, a plist a client sent, as the record keeps it.
COMPUTER is the id that offers it.  A resource without a path keeps none,
and one without an id gets a stable one from its kind and path."
  (when (listp resource)
    (let* ((kind (or (harness-computers--name (plist-get resource :kind)) "directory"))
           (path (harness-computers--name (plist-get resource :path)))
           (name (or (harness-computers--name (plist-get resource :name))
                     (and path (file-name-nondirectory (directory-file-name path)))
                     kind))
           (id (or (harness-computers--name (plist-get resource :id))
                   (and path (concat (downcase kind) "-"
                                     (substring (secure-hash 'sha1 path) 0 10))))))
      (when id
        (append (list :id id :kind (downcase kind) :name name)
                (and computer (list :computer computer))
                (and path (list :path path))
                (and (plist-get resource :branch)
                     (list :branch (harness-computers--name (plist-get resource :branch))))
                (and (plist-get resource :properties)
                     (list :properties (plist-get resource :properties))))))))

(defun harness-computers--normalise-capabilities (value)
  "Return VALUE, what a client said its implementation offers, as names.
A plist of `:view' etc. and a list of names both read the same way."
  (let ((names (cond ((and (consp value) (keywordp (car value)))
                      (cl-loop for (k v) on value by #'cddr
                               when (harness-json-true-p v)
                               collect (harness-computers--name k)))
                     (t (harness-computers--strings value)))))
    (delete-dups (delq nil (mapcar #'harness-computers--name names)))))

(defun harness-computers--normalise-servers (value)
  "Return VALUE, the tool servers a client runs, as plists with a name."
  (delq nil
        (mapcar (lambda (server)
                  (let ((name (if (listp server)
                                  (or (harness-computers--name (plist-get server :name))
                                      (harness-computers--name server))
                                (harness-computers--name server))))
                    (and name
                         (list :name (downcase name)
                               :title (or (and (listp server) (plist-get server :title)) name)))))
                (cond ((stringp value) (list value))
                      ((listp value) value)
                      (t nil)))))

;;;; Storage

(defun harness-computers--save ()
  "Write the registry to the store."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (harness-call 'store/save harness-computers--store
                      (mapcar #'harness-computers--stored
                              (harness-computers--sorted-records)))
      (error (harness-log 'error "computers: saving the registry failed: %S" err)))))

(defun harness-computers--load ()
  "Read the registry from the store, once."
  (unless harness-computers--loaded
    (setq harness-computers--loaded t)
    (let ((records (and (harness-method-exists-p 'store/load)
                        (condition-case err
                            (harness-call 'store/load harness-computers--store)
                          (error (harness-log 'error "computers: reading the registry failed: %S" err)
                                 nil)))))
      (dolist (record (if (listp records) records nil))
        ;; A store written by an older harness may hold the computer
        ;; `local', which the server used to make for itself.  The server
        ;; has no computer now: it is dropped here, and the next save
        ;; writes the registry without it.
        (when (and (listp record) (plist-get record :implicit))
          (setq record nil))
        (when (and (listp record) (equal (harness-computers--name (plist-get record :id))
                                         "local"))
          (setq record nil))
        (when (and (listp record) (harness-computers--name (plist-get record :id)))
          (let* ((id (harness-computers--name (plist-get record :id)))
                 (record (plist-put (copy-sequence record) :id id))
                 (record (plist-put record :state
                                    (harness-computers--state (plist-get record :state))))
                 (record (plist-put record :capabilities
                                    (harness-computers--normalise-capabilities
                                     (plist-get record :capabilities))))
                 (record (plist-put record :servers
                                    (harness-computers--normalise-servers
                                     (plist-get record :servers)))))
            ;; No client is here after a start, whatever the record saw.
            (dolist (key '(:client :mcp :mcp-token :server-symbols))
              (setq record (harness-plist-remove record key)))
            (setq record (plist-put record :state 'disconnected))
            (puthash id record harness-computers--computers)))))))

;;;; Reading computers

(defun harness-computers-get (id-or-name)
  "Return the record of the computer ID-OR-NAME names, or nil.
A name is matched without case; a prefix of an id matches when it is the
only one."
  (harness-computers--load)
  (let ((key (harness-computers--name id-or-name)))
    (when key
      (or (gethash key harness-computers--computers)
          (let ((want (downcase key)))
            (cl-find-if (lambda (r)
                          (string-equal (downcase (or (plist-get r :name) "")) want))
                        (harness-computers--sorted-records)))
          (let ((matches (let (out)
                           (maphash (lambda (id _)
                                      (when (string-prefix-p (downcase key) id)
                                        (push id out)))
                                    harness-computers--computers)
                           out)))
            (and (= (length matches) 1)
                 (gethash (car matches) harness-computers--computers)))))))

(defun harness-computers-resolve (id-or-name)
  "Return the id of the computer ID-OR-NAME names, or nil."
  (when-let* ((record (harness-computers-get id-or-name)))
    (plist-get record :id)))

(defun harness-computers--capabilities (record)
  "Return the computer-use capabilities RECORD offers, as names."
  (harness-computers--normalise-capabilities (plist-get record :capabilities)))

(defun harness-computers-capability-p (record name)
  "Non-nil when RECORD offers computer-use capability NAME."
  (and record (member (harness-computers--name name)
                      (harness-computers--capabilities record))
       t))

(defun harness-computers-connected-p (record)
  "Non-nil when RECORD can serve a tool call now."
  (and record
       (eq (harness-computers--state (plist-get record :state)) 'connected)))

(defun harness-computers--control-holder (record)
  "Return who has control of RECORD's pointer and keyboard, or nil."
  (let ((control (plist-get record :control)))
    (and (listp control) (harness-computers--name (plist-get control :holder)))))

;;;; Resources and projects

(defun harness-computers--resources-of (record)
  "Return RECORD's resources, each naming its computer."
  (let ((id (plist-get record :id))
        (name (plist-get record :name)))
    (delq nil
          (mapcar (lambda (resource)
                    (when (listp resource)
                      (plist-put (plist-put (copy-sequence resource) :computer id)
                                 :computer-name name)))
                  (plist-get record :resources)))))

(defun harness-computers-resource-list (&optional computer kind)
  "Return the resources of COMPUTER (default every one), of KIND.
Each is a plist with `:id', `:kind', `:name', `:path' when it has one,
`:computer' and `:computer-name'.  A computer's resources are what its
client reported when it registered."
  (harness-computers--load)
  (let* ((kind (and kind (downcase (or (harness-computers--name kind) ""))))
         (records (if computer
                      (let ((one (harness-computers-get computer)))
                        (and one (list one)))
                    (harness-computers--sorted-records)))
         out)
    (dolist (record records)
      (dolist (resource (harness-computers--resources-of record))
        (when (and resource
                   (or (null kind)
                       (string-equal kind (downcase (or (plist-get resource :kind) "")))))
          (push resource out))))
    (nreverse out)))

(defun harness-computers--session-resource-computers (session)
  "Return the ids of the computers whose resources SESSION works on."
  (let* ((paths (delq nil (list (plist-get session :worktree)
                                (plist-get session :project)
                                (plist-get session :cwd))))
         (normal (lambda (path)
                   (and (stringp path)
                        (if (harness-file-remote-p path)
                            (directory-file-name path)
                          (ignore-errors
                            (directory-file-name (expand-file-name path))))))))
    (delete-dups
     (delq nil
           (mapcar (lambda (record)
                     (let ((match
                            (cl-some
                             (lambda (resource)
                               (let ((resource-path (plist-get resource :path)))
                                 (and resource-path
                                      (cl-some (lambda (path)
                                                 (let ((path (funcall normal path)))
                                                   (and path (equal path
                                                                    (funcall normal resource-path)))))
                                               paths))))
                             (plist-get record :resources))))
                       (and match (plist-get record :id))))
                   (harness-computers--sorted-records))))))

;;;; The grant of a computer to a session

(defun harness-computers--grant (value)
  "Return VALUE, one entry of a session's `:computers', as a grant plist.
A grant is (:computer ID :capabilities (NAMES...) :window NAME); a bare
string is a grant of everything the computer offers."
  (let* ((id (cond ((stringp value) (harness-computers--name value))
                   ((listp value) (harness-computers--name (plist-get value :computer)))
                   (t nil)))
         (id (and id (or (harness-computers-resolve id) id))))
    (when id
      (list :computer id
            :capabilities (and (listp value)
                               (harness-computers--normalise-capabilities
                                (plist-get value :capabilities)))
            :window (and (listp value)
                         (harness-computers--name (plist-get value :window)))))))

(defun harness-computers--grants (ext)
  "Return the grants of a session's ext as grant plists, newest last."
  (delq nil (mapcar #'harness-computers--grant
                    (let ((v (plist-get ext :computers)))
                      (cond ((stringp v) (list v))
                            ((listp v) v)
                            (t nil))))))

(defun harness-computers--revoked (ext)
  "Return the ids a session's ext keeps it from using."
  (let ((v (plist-get ext :computers-off)))
    (delete-dups
     (delq nil (mapcar (lambda (id) (or (harness-computers-resolve id) (harness-computers--name id)))
                       (cond ((stringp v) (list v))
                             ((listp v) v)
                             (t nil)))))))

(defun harness-computers--setting (key cwd)
  "Return the effective value of KEY at CWD, with the option as a fallback."
  (let ((value (and cwd (harness-method-exists-p 'config/get)
                    (condition-case err
                        (harness-call 'config/get key cwd)
                      (error (harness-log 'debug "computers: %s at %s: %S" key cwd err) nil)))))
    (or value (and (boundp key) (symbol-value key)))))

(defun harness-computers--policy (session)
  "Return the computer-access policy of SESSION, a symbol."
  (let* ((cwd (or (plist-get session :worktree) (plist-get session :cwd)))
         (value (harness-computers--sym
                 (harness-computers--setting 'harness-computers-access cwd))))
    (cond
     ;; A workspace is the user's whole desk: by default every computer,
     ;; unless the setting says otherwise.
     ((and (eq (plist-get session :kind) 'workspace) (memq value '(auto nil))) 'all)
     ((memq value '(auto all none)) value)
     (t 'auto))))

(defun harness-computers--preference (session)
  "Return the id of the computer SESSION prefers, or nil."
  (let* ((ext (plist-get session :ext))
         (own (harness-computers--name (plist-get ext :computer)))
         (own (and own (or (harness-computers-resolve own) own)))
         (cwd (or (plist-get session :worktree) (plist-get session :cwd)))
         (set (harness-computers--name
               (harness-computers--setting 'harness-computer cwd)))
         (set (and set (or (harness-computers-resolve set) set))))
    (or own set)))

(defun harness-computers--client-computer-id (value)
  "Return VALUE, the computer a client said it runs on, as an id."
  (let ((value (harness-computers--name value)))
    (cond ((null value) nil)
          ((harness-computers-get value) (plist-get (harness-computers-get value) :id))
          (t (or (harness-computers--id value) value)))))

(defun harness-computers--defaults (session policy)
  "Return the computers SESSION may use before its own grants and revocations.
The value is (:ids IDS :why ((ID . TEXT) ...)).  POLICY is its access
policy: `all' is every computer, `none' is none, and `auto' is least
privilege -- the computer of the client the session was made from, when
that computer is registered, and the computers of the resources it
works on.  A workspace episode is the user's whole desk and gets every
computer unless the policy is `none'."
  (let* ((kind (plist-get session :kind))
         (ext (plist-get session :ext))
         (client (harness-computers--client-computer-id (plist-get ext :client-computer)))
         (all (mapcar (lambda (r) (plist-get r :id)) (harness-computers--sorted-records)))
         (why nil)
         (add (lambda (id reason)
                (when (and id (not (member id (mapcar #'car why))))
                  (push (cons id reason) why)))))
    (cond ((eq policy 'none))
          ((or (eq policy 'all) (eq kind 'workspace))
           (dolist (id all) (funcall add id "every computer")))
          (t nil))
    (unless (eq policy 'none)
      (when client
        (funcall add client "the client's computer"))
      (dolist (id (harness-computers--session-resource-computers session))
        (funcall add id "a resource of the session")))
    (list :ids (nreverse (mapcar #'car why))
          :why (nreverse why))))

(defun harness-computers-access (session-id)
  "Return the computers SESSION-ID may use, and how each stands.
A plist: `:policy' (auto, all or none), `:preferred' (an id or nil),
`:computers' (each `:id', `:name', `:state', `:allowed', `:why',
`:grant', `:capabilities-allowed', `:window'), `:revoked' and
`:available' (the computers that are registered)."
  (let* ((session (or (and (harness-method-exists-p 'session/get)
                           (ignore-errors (harness-call 'session/get session-id)))
                      (signal 'harness-error (list (format "No session %s" session-id)))))
         (ext (plist-get session :ext))
         (policy (harness-computers--policy session))
         (preferred (harness-computers--preference session))
         (grants (harness-computers--grants ext))
         (revoked (harness-computers--revoked ext))
         (defaults (harness-computers--defaults session policy))
         (ids (cl-remove-if (lambda (id) (member id revoked)) (plist-get defaults :ids)))
         (granted (cl-remove-if (lambda (g) (member (plist-get g :computer) revoked)) grants))
         (records (harness-computers--sorted-records)))
    (list :session session-id
          :policy policy
          :preferred preferred
          :revoked revoked
          :computers
          (mapcar
           (lambda (record)
             (let* ((id (plist-get record :id))
                    (grant (cl-find id granted :key (lambda (g) (plist-get g :computer))
                                    :test #'equal))
                    (allowed (or (member id ids) (and grant t)))
                    (caps (harness-computers--capabilities record))
                    (wanted (plist-get grant :capabilities))
                    (allowed-caps (if wanted
                                      (cl-remove-if-not (lambda (c) (member c caps)) wanted)
                                    caps)))
               (list :id id
                     :name (plist-get record :name)
                     :kind (plist-get record :kind)
                     :state (harness-computers--state (plist-get record :state))
                     :connected (harness-computers-connected-p record)
                     :allowed (and allowed t)
                     :why (and allowed (or (cdr (assoc id (plist-get defaults :why)))
                                           "a grant of the session"))
                     :grant grant
                     :window (plist-get grant :window)
                     :capabilities-allowed (and allowed allowed-caps)
                     :control (harness-computers--control-holder record))))
           records)
          :available (mapcar (lambda (r) (plist-get r :id)) records))))

(harness-defmethod computer/access (session-id)
  "Return the computers SESSION-ID may use, and how each stands.
See `harness-computers-access' for the plist."
  (harness-computers-access session-id))

(defun harness-computers--session (session-id)
  "Return the session plist of SESSION-ID, or signal a `harness-error'."
  (or (and (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get session-id)))
      (signal 'harness-error (list (format "No session %s" session-id)))))

(defun harness-computers--entry (access id)
  "Return the entry of ID in ACCESS, a plist `computer/access' returned."
  (cl-find id (plist-get access :computers)
           :key (lambda (c) (plist-get c :id)) :test #'equal))

;;;; Checking a call

(defun harness-computers--missing (reason hint &rest props)
  "Return a missing-requirement plist with REASON and HINT."
  (append (list :ok nil :reason reason :hint hint) props))

(defun harness-computers--check-computer (session subject)
  "Return the requirement of SUBJECT for SESSION, a session plist.
SUBJECT is `(:computer NAME :capability NAME :window NAME :input BOOL)';
a missing requirement says why and what to do, in words for the model."
  (let* ((access (harness-computers-access (plist-get session :id)))
         (requested (harness-computers--name (plist-get subject :computer)))
         (capability (harness-computers--name (plist-get subject :capability)))
         (window (harness-computers--name (plist-get subject :window)))
         (input (harness-json-true-p (plist-get subject :input)))
         (preferred (plist-get access :preferred))
         (id (cond
              (requested (or (harness-computers-resolve requested) requested))
              (preferred preferred)
              (t (let ((fits (cl-remove-if-not
                              (lambda (c)
                                (and (plist-get c :allowed)
                                     (plist-get c :connected)
                                     (or (null capability)
                                         (member capability
                                                 (plist-get c :capabilities-allowed)))))
                              (plist-get access :computers))))
                   (and (= (length fits) 1) (plist-get (car fits) :id))))))
         (record (and id (harness-computers-get id)))
         (entry (and id (harness-computers--entry access id)))
         (holder (and record (harness-computers--control-holder record))))
    (cond
     ((null id)
      (harness-computers--missing
       (cond (requested (format "No computer is named %s" requested))
             ((let ((allowed (cl-remove-if-not
                              (lambda (c) (plist-get c :allowed))
                              (plist-get access :computers))))
                (> (length allowed) 1))
              "Several computers fit; name the one this call uses")
             (t "This call needs a computer and none is chosen"))
       (if requested
           "Call computer_list for the computers the harness has, or ask the user to register one from a client on it."
         "Call computer_list, name one with computer_use, or ask the user to register a computer from a client on it.")))
     ((null record)
      (harness-computers--missing
       (format "No computer is named %s" requested)
       "Call computer_list for the computers the harness has, or ask the user to register one from a client on it."))
     ((not (plist-get entry :allowed))
      (harness-computers--missing
       (format "This session may not use the computer %s" (plist-get record :name))
       (format "Ask the user for it with request_escalation (attribute computer, value %s%s)."
               (plist-get record :id)
               (if capability (format ", capabilities %s" capability) ""))))
     ((not (harness-computers-connected-p record))
      (harness-computers--missing
       (format "The computer %s is not connected" (plist-get record :name))
       "Ask the user to start a client on that computer and register it, or use another computer."))
     ((and input holder)
      (harness-computers--missing
       (format "The user has control of the computer %s" (plist-get record :name))
       "Wait until they give control back; you may still look at its screen with computer_view."))
     ((and capability
           (not (member capability (harness-computers--capabilities record))))
      (harness-computers--missing
       (format "The computer %s has no %s capability (it offers %s)"
               (plist-get record :name) capability
               (or (string-join (harness-computers--capabilities record) ", ") "none"))
       "Use a computer whose implementation offers it (computer_list says which), or carry on without it."))
     ((and capability
           (not (member capability (plist-get entry :capabilities-allowed))))
      (harness-computers--missing
       (format "This session may not use %s on the computer %s"
               capability (plist-get record :name))
       (format "Ask the user for it with request_escalation (attribute computer, value %s, capabilities %s)."
               (plist-get record :id) capability)))
     ((and window (not (plist-get record :window-scoped)))
      (harness-computers--missing
       (format "The computer %s cannot see one window alone" (plist-get record :name))
       "Ask for the desktop instead (leave window out), or use a computer whose implementation is window-scoped."))
     ((and window (plist-get entry :window)
           (not (string-equal (downcase window) (downcase (plist-get entry :window)))))
      (harness-computers--missing
       (format "This session may use only the window %s on %s"
               (plist-get entry :window) (plist-get record :name))
       (format "Ask the user for %s with request_escalation (attribute computer, value %s, window %s)."
               window (plist-get record :id) window)))
     (t
      (list :ok t :id (plist-get record :id) :record record :entry entry
            :computer (harness-computers--public record)
            :capability capability :window (or window (plist-get entry :window)))))))

(harness-defmethod computers/check (session-id &rest subject)
  "Return whether SESSION-ID may use the computer SUBJECT names for a call.
SUBJECT is `(:computer NAME :capability NAME :window NAME :input BOOL)',
any of them optional.  The answer is `(:ok t :id ID :record RECORD
:entry ENTRY :capability NAME)' or `(:ok nil :reason TEXT :hint TEXT)',
worded for the model."
  (harness-computers--check-computer
   (harness-computers--session session-id) subject))

;;;; Changing the grant

(defun harness-computers--set-ext (session-id key value &optional hint)
  "Set the ext KEY of SESSION-ID to VALUE, with HINT in its transcript."
  (when (harness-method-exists-p 'session/set-ext)
    (harness-call 'session/set-ext session-id key value hint)))

(defun harness-computers-grant (session-id computer &optional capabilities window who)
  "Let SESSION-ID use COMPUTER, with CAPABILITIES (default all) and WINDOW.
WHO is `user' by default, or `agent'.  Return the access plist."
  (let* ((session (harness-computers--session session-id))
         (id (or (harness-computers-resolve computer) (harness-computers--name computer)))
         (record (and id (harness-computers-get id))))
    (unless record (signal 'harness-error (list (format "No computer is named %s" computer))))
    (let* ((ext (plist-get session :ext))
           (caps (harness-computers--normalise-capabilities capabilities))
           (grants (cl-remove (plist-get record :id) (harness-computers--grants ext)
                              :key (lambda (g) (plist-get g :computer))))
           (window (harness-computers--name window))
           (grant (harness-computers--grant
                   (append (list :computer (plist-get record :id))
                           (and caps (list :capabilities caps))
                           (and window (list :window window)))))
           (revoked (cl-remove (plist-get record :id) (harness-computers--revoked ext))))
      (harness-computers--set-ext
       session-id :computers (append grants (list grant))
       (format "Access: the computer %s, with %s%s (%s)."
               (plist-get record :name)
               (or (and caps (string-join caps ", ")) "any capability")
               (if window (format " in window %s" window) "")
               (if (eq who 'agent) "granted by the agent" "set by the user")))
      (when revoked
        (harness-computers--set-ext session-id :computers-off revoked))
      (harness-emit 'computers/changed (plist-get record :id) 'granted)
      (harness-computers-access session-id))))

(defun harness-computers-revoke (session-id computer &optional capability who)
  "Keep SESSION-ID from using COMPUTER, or from CAPABILITY on it.
WHO is `user' by default, or `agent'.  Return the access plist."
  (let* ((session (harness-computers--session session-id))
         (id (or (harness-computers-resolve computer) (harness-computers--name computer)))
         (record (and id (harness-computers-get id)))
         (capability (harness-computers--name capability)))
    (unless record (signal 'harness-error (list (format "No computer is named %s" computer))))
    (let* ((access (harness-computers-access session-id))
           (entry (harness-computers--entry access (plist-get record :id)))
           (ext (plist-get session :ext)))
      (if (null capability)
          (let ((grants (cl-remove (plist-get record :id) (harness-computers--grants ext)
                                   :key (lambda (g) (plist-get g :computer))))
                (revoked (delete-dups (append (harness-computers--revoked ext)
                                              (list (plist-get record :id))))))
            (harness-computers--set-ext
             session-id :computers grants
             (format "Access: the computer %s given up (%s)."
                     (plist-get record :name)
                     (if (eq who 'agent) "given up by the agent" "set by the user")))
            (harness-computers--set-ext session-id :computers-off revoked)
            (harness-emit 'computers/changed (plist-get record :id) 'revoked))
        ;; One capability: keep the others, which the default grant may allow.
        (let* ((held (plist-get entry :capabilities-allowed))
               (left (cl-remove capability held :test #'string-equal)))
          (if (null left)
              (harness-computers-revoke session-id computer nil who)
            (harness-computers-grant session-id computer left
                                     (plist-get entry :window) who))))
      (harness-computers-access session-id))))

(harness-defmethod computer/grant (session-id computer &rest options)
  "Let SESSION-ID use COMPUTER, for the user.
OPTIONS: `:capabilities' (names, default all) and `:window' (one window,
when the implementation is window-scoped)."
  (harness-computers-grant session-id computer
                           (plist-get options :capabilities)
                           (plist-get options :window) 'user))

(harness-defmethod computer/revoke (session-id computer &rest options)
  "Keep SESSION-ID from using COMPUTER, or from `:capability' on it, for the user."
  (harness-computers-revoke session-id computer
                            (plist-get options :capability) 'user))

(harness-defmethod computer/grant-capability (session-id computer capability on)
  "Let SESSION-ID use CAPABILITY on COMPUTER when ON is true, else not; the user's.
The other capabilities it may use there stay as they are."
  (let* ((computer (harness-computers--name computer))
         (capability (harness-computers--name capability))
         (record (and computer (harness-computers-get computer))))
    (unless record (signal 'harness-error (list (format "No computer is named %s" computer))))
    (unless (member capability (harness-computers--capabilities record))
      (signal 'harness-error
              (list (format "The computer %s has no %s capability"
                            (plist-get record :name) capability))))
    (let* ((access (harness-computers-access session-id))
           (entry (harness-computers--entry access (plist-get record :id)))
           (held (plist-get entry :capabilities-allowed))
           (caps (if (harness-json-true-p on)
                     (delete-dups (append held (list capability)))
                   (cl-remove capability held :test #'string-equal))))
      (if caps
          (harness-computers-grant session-id (plist-get record :id) caps
                                   (plist-get entry :window) 'user)
        (harness-computers-revoke session-id (plist-get record :id) nil 'user)))))

(harness-defmethod computer/set-preference (session-id computer)
  "Make COMPUTER the one SESSION-ID uses when a call names none; the user's choice.
COMPUTER nil clears it.  The preference is not a pin: a call that names
a computer, and a resource of one, still goes where it names."
  (let* ((id (and computer (or (harness-computers-resolve computer)
                               (harness-computers--name computer))))
         (record (and id (harness-computers-get id))))
    (when (and computer (null record))
      (signal 'harness-error (list (format "No computer is named %s" computer))))
    (harness-computers--set-ext
     session-id :computer (and record (plist-get record :id))
     (if record
         (format "Access: the computer %s is preferred for this session."
                 (plist-get record :name))
       "Access: no preferred computer for this session."))
    (harness-emit 'computers/changed (and record (plist-get record :id)) 'preferred)
    (harness-computers-access session-id)))

(defun harness-computers-set-preference (session-id id)
  "Make ID the computer SESSION-ID prefers; return the access plist."
  (harness-call 'computer/set-preference session-id id))

;;;; Control: a person watching and driving the computer

(defun harness-computers--control (record holder)
  "Set RECORD's control to HOLDER, or clear it with nil; return RECORD."
  (let ((record (if holder
                    (plist-put record :control
                               (list :holder holder :since (harness-computers--now)))
                  (harness-plist-remove record :control))))
    (puthash (plist-get record :id) record harness-computers--computers)
    (harness-computers--save)
    (harness-emit 'computers/changed (plist-get record :id) 'control)
    record))

(defun harness-computers-take-control (id &optional holder)
  "Take control of computer ID for a person watching it; return the record.
While a person has control, the agent's pointer, keyboard, clipboard
writes and programs on that computer wait.  A client may do this for a
computer it can see; the harness does not ask a session's permission,
since it is the person's own hands."
  (let* ((record (harness-computers-get id))
         (holder (or (harness-computers--name holder)
                     (let ((client (and (boundp 'harness-acp--calling-client)
                                        harness-acp--calling-client)))
                       (if client (symbol-name (harness-acp-client-kind client)) "the user")))))
    (unless record (signal 'harness-error (list (format "No computer is named %s" id))))
    (harness-computers--control record holder)))

(defun harness-computers-release-control (id &optional holder)
  "Give control of computer ID back, for HOLDER or anyone; return the record."
  (let ((record (harness-computers-get id)))
    (unless record (signal 'harness-error (list (format "No computer is named %s" id))))
    (let ((current (harness-computers--control-holder record)))
      (when (and current holder (not (string-equal current holder)))
        (signal 'harness-error
                (list (format "The computer %s is controlled by %s" id current))))
      (harness-computers--control record nil))))

(harness-defmethod computer/take-control (id)
  "Take control of computer ID, for the person using this client.
The agent's input on it waits until `computer/release-control'."
  (let ((record (harness-computers-take-control id)))
    (harness-computers--describe record)))

(harness-defmethod computer/release-control (id)
  "Give control of computer ID back, so the agent may use it again."
  (let ((record (harness-computers-release-control id)))
    (harness-computers--describe record)))

;;;; The permission gate

(put 'harness-computers--gate 'harness-permission-stage 'computer)

(defun harness-computers--gate (decision next request)
  "Decide a call whose computer the session may not use: a stage at 7.
A call that names no computer goes on with DECISION.  One whose computer
is not registered or not connected, one whose capability the computer or
the session's grant does not hold, and one that drives a computer a
person has taken control of, is refused for good: no mode, rule or judge
decides it."
  (let ((subject (plist-get request :computer)))
    (if (null subject)
        (funcall next decision)
      (condition-case err
          (let* ((session (plist-get request :session))
                 (check (harness-computers--check-computer
                         session
                         (cond ((listp subject) subject)
                               ((stringp subject) (list :computer subject))
                               (t nil)))))
            (if (plist-get check :ok)
                (funcall next (plist-put (copy-sequence decision) :computer
                                         (plist-get check :id)))
              (funcall next (list :behavior 'deny :final t :by 'computer
                                  :reason (plist-get check :reason)
                                  :hint (plist-get check :hint)))))
        (error
         (harness-log 'error "computers: checking a call failed: %S" err)
         (funcall next (list :behavior 'deny :final t :by 'computer
                             :reason (format "the computer of this call could not be checked: %s"
                                             (harness-error-message err))
                             :hint "Call computer_list, and carry on with what you have.")))))))

;;;; The ACP side: a client that runs on a computer

(defun harness-computers--normalise-capability-states (states)
  "Return STATES, a client's per-capability state map, as a plist.
STATES is a plist of capability name to state name, from a client's
description or update; a list of (NAME . STATE) pairs is read too.  The
names are downcased, and a state is one of `available', `denied',
`revoked', `unavailable', `foreground-only', `suspended' or `error'."
  (let (out)
    (cond
     ((and (listp states) (keywordp (car states)))
      (cl-loop for (key value) on states by #'cddr
               when (keywordp key)
               do (push (cons key (harness-computers--name value)) out)))
     ((listp states)
      (dolist (pair states)
        (when (and (consp pair) (stringp (car pair)))
          (push (cons (intern (concat ":" (downcase (car pair))))
                      (harness-computers--name (cdr pair)))
                out)))))
    (nreverse out)))

(defun harness-computers--normalise-info (info &optional _client)
  "Return INFO, a client's description of its computer, as records keep it."
  (when (and (consp info) (keywordp (car info)))
    (let* ((given (or (harness-computers--name (plist-get info :id))
                      (harness-computers--name (plist-get info :name))
                      (plist-get info :host)))
           (id (or (harness-computers--id given) (harness-computers--id "computer"))))
      (list :id id
            :name (or (harness-computers--name (plist-get info :name))
                      (harness-computers--name given) id)
            :host (harness-computers--name (plist-get info :host))
            :os (harness-computers--name (plist-get info :os))
            :arch (harness-computers--name (plist-get info :arch))
            :display (harness-computers--name (plist-get info :display))
            :vnc (harness-computers--name (plist-get info :vnc))
            :vnc-socket (harness-computers--name (plist-get info :vnc-socket))
            :window-scoped (and (harness-json-true-p (plist-get info :window-scoped)) t)
            :capabilities (harness-computers--normalise-capabilities
                           (plist-get info :capabilities))
            :capability-states (harness-computers--normalise-capability-states
                                (plist-get info :capability-states))))))

(defun harness-computers-computer-info (client)
  "Return the computer CLIENT said it runs on at `initialize', or nil.
The plist is the client's description: `:id', `:name', `:host', `:os',
`:arch', `:display', `:vnc' and `:capabilities'.  It is no
registration; it says where the client is, which a session it makes may
use."
  (gethash client harness-computers--client-info))

(defun harness-computers-client-computer (client)
  "Return the id of the computer CLIENT runs on, or nil."
  (plist-get (harness-computers-computer-info client) :id))

(defun harness-computers--on-initialize (client params)
  "Record the computer CLIENT says it runs on, from its `initialize' PARAMS.
The description is a fact about the client, not a registration: it
registers its computer with `computer/register', and until it does, the
harness has no tools there."
  (let* ((capabilities (plist-get params :clientCapabilities))
         (info (plist-get (plist-get capabilities :_harness) :computer))
         (normal (harness-computers--normalise-info info client)))
    (when normal
      (puthash client normal harness-computers--client-info)
      (harness-log 'debug "computers: %s client on %s"
                   (harness-acp-client-kind client) (plist-get normal :id)))))

(defun harness-computers--on-session-created (session-id _plist)
  "Record the computer of the client a session was made from.
A session the user starts from a client on a computer may use that
computer; it is not pinned to it.  Sessions made by the harness itself
\(a task, a sub-agent) are not touched."
  (let ((client (and (boundp 'harness-acp--calling-client)
                     harness-acp--calling-client)))
    (when client
      (when-let* ((id (harness-computers-client-computer client)))
        (ignore-errors
          (harness-call 'session/set-ext session-id :client-computer id))))))

(defun harness-computers--on-client-left (client)
  "Forget CLIENT: the computers it served read disconnected, and detach."
  (remhash client harness-computers--client-info)
  (let ((id (gethash client harness-computers--client-binding)))
    (remhash client harness-computers--client-binding)
    (when-let* ((record (and id (gethash id harness-computers--computers))))
      (setq record (harness-computers--detach-mcp record "its client left"))
      (setq record (harness-plist-remove record :client :mcp :mcp-token))
      (when (string-equal (or (harness-computers--control-holder record) "")
                          (symbol-name (harness-acp-client-kind client)))
        (setq record (harness-plist-remove record :control)))
      (setq record (plist-put record :state 'disconnected))
      (puthash id record harness-computers--computers)
      (harness-computers--save)
      (harness-emit 'computers/changed id 'disconnected))))

;;;; The MCP servers of a computer

(defun harness-computers--server-symbol (record server)
  "Return the MCP server symbol of SERVER, a tool server of RECORD."
  (let ((id (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase (plist-get record :id))))
        (server (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase (or server "computer")))))
    (intern (format "computer-%s-%s" id server))))

(defun harness-computers--servers (record)
  "Return the names of the tool servers RECORD runs, `computer' by default."
  (let ((servers (mapcar (lambda (s) (or (plist-get s :name) s))
                         (plist-get record :servers))))
    (or (delq nil servers) (list "computer"))))

(defun harness-computers--detach-mcp (record &optional reason)
  "Close every MCP connection of RECORD, for REASON; return RECORD."
  (dolist (conn (plist-get record :mcp))
    (when (and conn (fboundp 'harness-mcp-detach))
      (ignore-errors (harness-mcp-detach conn (or reason "the computer went away")))))
  (harness-plist-remove record :mcp :mcp-token))

(defun harness-computers--attach-mcp (record client token)
  "Attach the tool servers of RECORD over CLIENT's connection, with TOKEN.
Return RECORD.  Every message names the computer and carries its token,
and the client answers with its MCP server."
  (let ((conns nil))
    (dolist (server (harness-computers--servers record))
      (let* ((symbol (harness-computers--server-symbol record server))
             (id (plist-get record :id))
             (cell (list nil)))
        (harness-mcp-define-server
         symbol
         :title (format "Computer %s (%s)" (plist-get record :name) server)
         :doc "The tools a computer offers the harness, over the ACP connection of the client that runs there."
         :external t)
        (push
         (setcar
          cell
          (harness-mcp-attach
           symbol
           (lambda (message)
             (harness-acp--client-request
              client "_harness/computer/mcp"
              (append (list :computer id :server server :message message)
                      (and token (list :token token)))
              (lambda (result error)
                (let ((conn (car cell)))
                  (cond
                   ((null conn) nil)
                   (error
                    (ignore-errors
                      (harness-mcp-detach
                       conn (format "the computer could not be asked: %s"
                                    (or (and (listp error) (plist-get error :message)) error)))))
                   (result (harness-mcp-receive conn result)))))))
           :key t))
         conns)))
    (plist-put record :mcp (nreverse conns))))

(defun harness-computers--mcp-token ()
  "Return a fresh token that binds MCP messages to a registration."
  (base64url-encode-string
   (with-temp-buffer
     (set-buffer-multibyte nil)
     (dotimes (_ harness-computers--secret-bytes)
       (insert-byte (random 256) 1))
     (buffer-string))
   t))

(defun harness-computers--hash-secret (secret)
  "Return the salted hash of SECRET that the record keeps, as (SALT HASH).
The salt is random for each record, so two computers with the same
secret do not read alike, and the secret itself is never stored.  It
is a list, not a cons: a dotted pair as a plist value would become
part of the plist itself, and the keys after it would write into it."
  (let ((salt (harness-computers--mcp-token)))
    (list salt (secure-hash 'sha256 (concat salt ":" secret)))))

(defun harness-computers--secret-ok-p (record secret)
  "Non-nil when SECRET is the secret RECORD was registered with."
  (let* ((stored (plist-get record :secret))
         (salt (nth 0 stored))
         (hash (nth 1 stored)))
    (and (stringp salt) (stringp hash) (stringp secret)
         (harness-instance-equal-p
          hash (secure-hash 'sha256 (concat salt ":" secret))))))

(defun harness-computers--check-secret (record secret)
  "Signal unless SECRET is RECORD's.  Return RECORD."
  (unless (harness-computers--secret-ok-p record secret)
    (signal 'harness-error
            (list (format "The computer %s did not authenticate: its secret does not match"
                          (plist-get record :id)))))
  record)

(defun harness-computers--current-client ()
  "Return the ACP client whose message is being dispatched, or nil."
  (and (boundp 'harness-acp--calling-client) harness-acp--calling-client))

(defun harness-computers--client-hosts-record-p (client record)
  "Non-nil when CLIENT may speak for RECORD.
That is the computer it registered or attached to, and no other."
  (and client
       (equal (gethash client harness-computers--client-binding)
              (plist-get record :id))))

;;;; Registering a computer

(defun harness-computers--register-record (info client secret resources servers)
  "Make or update the record INFO describes, for CLIENT with SECRET.
RESOURCES and SERVERS are what the client runs.  Return the record."
  (let* ((id (plist-get info :id))
         (old (gethash id harness-computers--computers))
         (old (or old (cl-find-if (lambda (r)
                                    (and (eq (harness-computers--state
                                              (plist-get r :state))
                                             'registered)
                                         (let ((host (plist-get info :host)))
                                           (and host (plist-get r :host)
                                                (string-equal (downcase host)
                                                              (downcase (plist-get r :host)))))))
                                  (harness-computers--sorted-records))))
         (id (or (and old (plist-get old :id)) id)))
    (when (and old (plist-get old :secret)
               (not (harness-computers--secret-ok-p old secret)))
      (signal 'harness-error
              (list (format "The computer %s is registered already: attach to it with its secret, or unregister it first"
                            id))))
    (let* ((record (or old (list :id id)))
           (record (plist-put record :name
                              (harness-computers--unique-name
                               (or (plist-get info :name) id) id)))
           (record (plist-put record :kind (or (plist-get info :kind) 'client)))
           (record (plist-put record :host (plist-get info :host)))
           (record (plist-put record :user (plist-get info :user)))
           (record (plist-put record :os (plist-get info :os)))
           (record (plist-put record :arch (plist-get info :arch)))
           (record (plist-put record :display (plist-get info :display)))
           (record (plist-put record :vnc (plist-get info :vnc)))
           (record (plist-put record :vnc-socket (plist-get info :vnc-socket)))
           (record (plist-put record :window-scoped
                              (and (plist-get info :window-scoped) t)))
           (record (plist-put record :capabilities
                              (or (plist-get info :capabilities)
                                  (plist-get old :capabilities))))
           (record (plist-put record :capability-states
                              (or (plist-get info :capability-states)
                                  (plist-get old :capability-states))))
           (record (plist-put record :servers
                              (or (harness-computers--normalise-servers servers)
                                  (plist-get old :servers)
                                  (list (list :name "computer" :title "Computer")))))
           (record (plist-put record :resources
                              (or (delq nil (mapcar (lambda (r)
                                                      (harness-computers--normalise-resource
                                                       r id))
                                                    (if (listp resources) resources nil)))
                                  (plist-get old :resources))))
           (record (plist-put record :state 'connected))
           (record (plist-put record :last-seen (harness-computers--now)))
           (record (plist-put record :registered-at
                              (or (plist-get old :registered-at)
                                  (harness-computers--now))))
           (record (plist-put record :secret
                              (or (and (harness-computers--secret-ok-p old secret)
                                       (plist-get old :secret))
                                  (harness-computers--hash-secret secret))))
           (record (plist-put record :client client))
           (token (harness-computers--mcp-token)))
      ;; Detaching drops the token of the connection it closes, so the
      ;; new one goes on after it.
      (setq record (harness-computers--detach-mcp record "it registered again"))
      (setq record (plist-put record :mcp-token token))
      (setq record (harness-computers--attach-mcp record client token))
      (puthash id record harness-computers--computers)
      (puthash client id harness-computers--client-binding)
      (harness-computers--save)
      (harness-emit 'computers/changed id 'registered)
      (harness-log 'info "computers: registered %s from a %s client, %d resources, %d servers"
                   id (harness-acp-client-kind client)
                   (length (plist-get record :resources))
                   (length (harness-computers--servers record)))
      record)))

(harness-defmethod computer/register (&rest params)
  "Register the computer the calling client runs on, with its tool servers.
PARAMS: `:computer' (the description the client advertised in
`initialize'), `:secret' (made by the client, kept only as a salted
hash), `:resources' and `:servers'.  Return `(:computer RECORD :token
TOKEN)': TOKEN is what the client checks in the MCP messages that
follow.  Only a client on the computer can register it, and nothing is
registered without this."
  (let* ((client (harness-computers--current-client))
         (info (or (harness-computers--normalise-info (plist-get params :computer) client)
                   (and client (harness-computers-computer-info client))))
         (secret (harness-computers--name (plist-get params :secret))))
    (unless client
      (signal 'harness-error (list "A computer is registered from a client running on it")))
    (unless info
      (signal 'harness-error (list "Tell the harness which computer you register (its name at least)")))
    (unless (and secret (>= (length secret) 32))
      (signal 'harness-error
              (list "A computer's registration needs a secret of at least 32 characters")))
    (let* ((record (harness-computers--register-record
                    info client secret (plist-get params :resources)
                    (plist-get params :servers))))
      (list :computer (harness-computers--describe record)
            :token (plist-get record :mcp-token)))))

(harness-defmethod computer/register-remote (name &rest params)
  "Register a computer reached over SSH, for the user.
PARAMS: `:host', `:user', `:resources', `:vnc' and `:vnc-socket'.  Its tools start when
a client on that machine attaches with `computer/attach' and the
secret, which the person installs there; until then it reads
`registered'.  Return the record."
  (let ((client (harness-computers--current-client)))
    (when (and client (harness-acp-client-remote-info client))
      (signal 'harness-error
              (list "Only a client on this machine registers another computer")))
    (let* ((host (or (harness-computers--name (plist-get params :host))
                     (harness-computers--name name)))
           (id (or (harness-computers--id name) (harness-computers--id host)))
           (old (gethash id harness-computers--computers))
           (record (or old (list :id id))))
      (when (and old (not (memq (harness-computers--state (plist-get old :state))
                                '(registered disconnected))))
        (signal 'harness-error
                (list (format "The computer %s is in use already" id))))
      (setq record (plist-put record :name (harness-computers--unique-name name id)))
      (setq record (plist-put record :kind 'ssh))
      (setq record (plist-put record :host host))
      (setq record (plist-put record :user (harness-computers--name (plist-get params :user))))
      (setq record (plist-put record :vnc (harness-computers--name (plist-get params :vnc))))
      (setq record (plist-put record :vnc-socket
                              (harness-computers--name (plist-get params :vnc-socket))))
      (setq record (plist-put record :state 'registered))
      (setq record (plist-put record :resources
                              (or (delq nil (mapcar (lambda (r)
                                                      (harness-computers--normalise-resource r id))
                                                    (if (listp (plist-get params :resources))
                                                        (plist-get params :resources)
                                                      nil)))
                                  (plist-get record :resources))))
      (setq record (plist-put record :servers
                              (or (plist-get record :servers)
                                  (list (list :name "computer" :title "Computer")))))
      (setq record (plist-put record :registered-at
                              (or (plist-get record :registered-at)
                                  (harness-computers--now))))
      (puthash id record harness-computers--computers)
      (harness-computers--save)
      (harness-emit 'computers/changed id 'registered)
      (harness-computers--describe record))))

(harness-defmethod computer/attach (id secret)
  "Attach the calling client to the registered computer ID, with SECRET.
For a client that reconnects to a computer registered before: it binds
the client, updates the resources, and hands it a token for the MCP
messages.  Return `(:computer RECORD :token TOKEN)'."
  (let* ((client (harness-computers--current-client))
         (record (harness-computers-get id)))
    (unless client
      (signal 'harness-error (list "Only a client can attach to a computer")))
    (unless record
      (signal 'harness-error (list (format "No computer is named %s" id))))
    (harness-computers--check-secret record secret)
    (when (and (plist-get record :client)
               (not (eq (plist-get record :client) client))
               (not (equal (gethash client harness-computers--client-binding)
                           (plist-get record :id))))
      (signal 'harness-error
              (list (format "The computer %s is serving another client" (plist-get record :id)))))
    (let ((record (harness-computers--detach-mcp record "it attached again"))
          (token (harness-computers--mcp-token)))
      (setq record (plist-put record :state 'connected))
      (setq record (plist-put record :client client))
      (setq record (plist-put record :last-seen (harness-computers--now)))
      (setq record (plist-put record :mcp-token token))
      (setq record (harness-computers--attach-mcp record client token))
      (puthash (plist-get record :id) record harness-computers--computers)
      (puthash client (plist-get record :id) harness-computers--client-binding)
      (harness-computers--save)
      (harness-emit 'computers/changed (plist-get record :id) 'attached)
      (list :computer (harness-computers--describe record)
            :token token))))

(harness-defmethod computer/update (id &rest params)
  "Update the resources, capabilities and screen of computer ID.
PARAMS: `:secret', `:resources', `:capabilities',
`:capability-states', `:display', `:vnc', `:vnc-socket' and
`:window-scoped'.  The tool servers are not changed: a client that runs
another server registers again."
  (let* ((client (harness-computers--current-client))
         (record (harness-computers-get id))
         (resources (plist-get params :resources))
         (capabilities (plist-get params :capabilities))
         (states (plist-get params :capability-states))
         (sets (cl-loop for (key field) on '(:display :display
                                             :vnc :vnc
                                             :vnc-socket :vnc-socket
                                             :window-scoped :window-scoped)
                        by #'cddr
                        when (plist-member params key)
                        collect (cons field (plist-get params key)))))
    (unless record (signal 'harness-error (list (format "No computer is named %s" id))))
    (harness-computers--check-secret record (plist-get params :secret))
    (unless (harness-computers--client-hosts-record-p client record)
      (signal 'harness-error
              (list (format "This client does not speak for the computer %s" id))))
    (setq record (plist-put record :resources
                            (if (listp resources)
                                (delq nil (mapcar (lambda (r)
                                                    (harness-computers--normalise-resource
                                                     r (plist-get record :id)))
                                                  resources))
                              (plist-get record :resources))))
    (setq record (plist-put record :capabilities
                            (if capabilities
                                (harness-computers--normalise-capabilities capabilities)
                              (plist-get record :capabilities))))
    (when (plist-member params :capability-states)
      (setq record (plist-put record :capability-states
                              (harness-computers--normalise-capability-states states))))
    (dolist (set sets)
      (setq record (plist-put record (car set) (cdr set))))
    (when (plist-member params :window-scoped)
      (setq record (plist-put record :window-scoped
                              (and (harness-json-true-p (plist-get params :window-scoped))
                                   t))))
    (setq record (plist-put record :last-seen (harness-computers--now)))
    (puthash (plist-get record :id) record harness-computers--computers)
    (harness-computers--save)
    (harness-emit 'computers/changed (plist-get record :id) 'updated)
    (harness-computers--describe record)))

(harness-defmethod computers/update-resources (id kind resources)
  "Replace the resources of KIND that computer ID offers with RESOURCES.
RESOURCES are plists as `computer/update' takes them, normally the ones
its MCP server answered for KIND; a resource of KIND the list leaves out
is removed, so a change the computer reports reconciles with nothing
left behind.  The harness's own method: a client reports through
`computer/update', and a module that asks a computer something it only
knows when asked -- its skills, say -- calls this with the answer.
Return the computer as `computer/get' describes it."
  (unless (harness-computers-get id)
    (signal 'harness-error (list (format "No computer is named %s" id))))
  (let* ((record (harness-computers-get id))
         (kind (or (harness-computers--name kind) "directory"))
         (others (cl-remove-if (lambda (r)
                                 (string-equal (downcase (or (plist-get r :kind) ""))
                                               (downcase kind)))
                               (plist-get record :resources)))
         (replaced (delq nil (mapcar (lambda (r)
                                       (harness-computers--normalise-resource
                                        (plist-put (copy-sequence r) :kind kind)
                                        (plist-get record :id)))
                                     (if (listp resources) resources nil)))))
    (setq record (plist-put record :resources (append (append others nil) replaced)))
    (setq record (plist-put record :last-seen (harness-computers--now)))
    (puthash (plist-get record :id) record harness-computers--computers)
    (harness-computers--save)
    (harness-emit 'computers/changed (plist-get record :id) 'updated)
    (harness-computers--describe record)))

(harness-defmethod computer/unregister (id)
  "Remove computer ID from the registry, for the user.
A client may unregister a computer it registered, and a client on this
machine any computer; a client on another machine only its own."
  (let* ((client (harness-computers--current-client))
         (record (harness-computers-get id)))
    (unless record (signal 'harness-error (list (format "No computer is named %s" id))))
    (when (and client (not (harness-computers--client-hosts-record-p client record)))
      (signal 'harness-error
              (list (format "This client does not manage the computer %s" id))))
    (harness-computers--detach-mcp record "it was unregistered")
    (remhash (plist-get record :id) harness-computers--computers)
    (when (equal (gethash client harness-computers--client-binding)
                 (plist-get record :id))
      (remhash client harness-computers--client-binding))
    (harness-computers--save)
    (harness-emit 'computers/changed (plist-get record :id) 'removed)
    t))

;;;; Calling a computer's tools

(defun harness-computers--required (id)
  "Return the record ID names, signalling when there is none or no client."
  (let ((record (harness-computers-get id)))
    (unless record (signal 'harness-error (list (format "No computer is named %s" id))))
    (unless (plist-get record :mcp)
      (signal 'harness-error
              (list (format "The computer %s has no tool server connected: is a client running on it?"
                            (plist-get record :name)))))
    record))

(defun harness-computers--server (record server)
  "Return the MCP server symbol of RECORD's SERVER, or signal."
  (let ((name (or (harness-computers--name server) "computer")))
    (unless (member name (harness-computers--servers record))
      (signal 'harness-error
              (list (format "The computer %s runs no tool server named %s"
                            (plist-get record :name) name))))
    (harness-computers--server-symbol record name)))

(defun harness-computers-call (computer tool input &optional server ctx)
  "Call TOOL of COMPUTER's SERVER with INPUT; return a promise of the MCP result.
CTX is the context of the harness tool call, for progress and notes."
  (let* ((record (harness-computers--required computer))
         (symbol (harness-computers--server record server)))
    (harness-mcp-call-tool symbol tool input ctx nil nil t)))

(defun harness-computers-tools (computer &optional server)
  "Return a promise of the tools COMPUTER's SERVER lists."
  (let* ((record (harness-computers--required computer))
         (symbol (harness-computers--server record server)))
    (harness-mcp-tools symbol nil t)))

(harness-defmethod computers/call (computer tool input &optional server)
  "Call TOOL of COMPUTER's SERVER with INPUT; return the MCP result.
The harness's own; not callable over ACP."
  (harness-computers-call computer tool input server))

(harness-defmethod computers/tools (computer &optional server)
  "Return the tools COMPUTER's SERVER lists.  The harness's own."
  (harness-computers-tools computer server))

;;;; Describing a computer

(defun harness-computers--describe (record &optional access)
  "Return RECORD as the pages and the model read it.
ACCESS, when given, adds `:allowed', `:why', `:grant' and
`:capabilities-allowed'."
  (let* ((public (harness-computers--public record))
         (caps (harness-computers--capabilities record))
         (control (plist-get record :control)))
    (append
     (list :id (plist-get public :id)
           :name (plist-get public :name)
           :kind (plist-get public :kind)
           :state (harness-computers--state (plist-get public :state))
           :connected (and (plist-get public :connected) t)
           :host (plist-get public :host)
           :user (plist-get public :user)
           :os (plist-get public :os)
           :arch (plist-get public :arch)
           :display (plist-get public :display)
           :vnc (plist-get public :vnc)
           :vnc-socket (plist-get public :vnc-socket)
           :window-scoped (and (plist-get public :window-scoped) t)
           :control (and control (plist-get control :holder))
           :control-since (and control (plist-get control :since))
           :capabilities (mapcar (lambda (c)
                                   (list :name c :doc (harness-computers-capability-doc c)))
                                 caps)
           :capability-names caps
           :capability-states (plist-get public :capability-states)
           :servers (mapcar (lambda (s) (plist-get s :name))
                            (plist-get public :servers))
           :resources (harness-computers--resources-of record)
           :last-seen (plist-get public :last-seen)
           :registered-at (plist-get public :registered-at))
     (and access
          (list :allowed (and (plist-get access :allowed) t)
                :why (plist-get access :why)
                :grant (plist-get access :grant)
                :capabilities-allowed (plist-get access :capabilities-allowed))))))

;;;; Methods a page reads

(harness-defmethod computer/list (&optional session-id)
  "Return the registered computers, by name.
With SESSION-ID, each says whether that session may use it, and with
which capabilities (`computer/access').  Viewing is not a session's:
every client sees every computer it can reach.  The list is empty when
no client has registered a computer."
  (harness-computers--load)
  (let ((access (and session-id (harness-computers-access session-id))))
    (mapcar (lambda (record)
              (let ((entry (and access (harness-computers--entry
                                        access (plist-get record :id)))))
                (harness-computers--describe record entry)))
            (harness-computers--sorted-records))))

(harness-defmethod computer/get (id)
  "Return the computer ID names, or nil."
  (let ((record (harness-computers-get id)))
    (and record (harness-computers--describe record))))

(harness-defmethod computer/resources (&optional computer kind)
  "Return the resources of COMPUTER (default every one), of KIND."
  (harness-computers-resource-list computer kind))

(harness-defmethod computer/projects (&optional session-id)
  "Return the git repositories the harness knows, across computers.
With SESSION-ID, only those of computers it may use."
  (let* ((access (and session-id (harness-computers-access session-id)))
         (resources (harness-computers-resource-list nil "git-repo")))
    (delq nil
          (mapcar
           (lambda (resource)
             (let ((entry (and access (harness-computers--entry
                                       access (plist-get resource :computer)))))
               (when (or (null access) (plist-get entry :allowed))
                 (list :id (plist-get resource :id)
                       :kind (plist-get resource :kind)
                       :name (plist-get resource :name)
                       :path (plist-get resource :path)
                       :branch (plist-get resource :branch)
                       :computer (plist-get resource :computer)
                       :computer-name (plist-get resource :computer-name)
                       :project t))))
           resources))))

(harness-declare-event 'computers/changed
                       "(ID WHAT) after a computer changed: registered, updated, attached, disconnected, granted, revoked, preferred, control or removed.")

;;;; Module

(defun harness-computers--init ()
  "Hook the module into the bus (idempotent)."
  (harness-computers--load)
  (harness-add-filter 'permission/decide #'harness-computers--gate 7)
  (harness-on 'session/created #'harness-computers--on-session-created)
  (add-hook 'harness-acp-initialized-functions #'harness-computers--on-initialize)
  (add-hook 'harness-acp-client-left-functions #'harness-computers--on-client-left))

(defun harness-computers--shutdown ()
  "Take the module off the bus."
  (harness-remove-filter 'permission/decide #'harness-computers--gate)
  (harness-off (cons 'session/created #'harness-computers--on-session-created))
  (remove-hook 'harness-acp-initialized-functions #'harness-computers--on-initialize)
  (remove-hook 'harness-acp-client-left-functions #'harness-computers--on-client-left))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'computers)
  (harness-computers--init))

(harness-define-module 'computers
  :doc "Computers the harness may use: the ones clients register, their tool servers over MCP and their resources, the computer-use capabilities of each, who has control of it, and the session grants that limit which computer and which capability a call may use."
  :requires '(acp mcp store project session perms)
  :init #'harness-computers--init
  :shutdown #'harness-computers--shutdown)

(provide 'harness-computers)
;;; harness-computers.el ends here
