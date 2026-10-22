;;; harness-ui-access.el --- The access view: what a session may reach, and how its calls were judged  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer per session, `harness-access' (C-c h j), says what the
;; session may reach, in one place, and changes it:
;;
;; - Jail: the sandbox its commands run in -- the backend, the ones
;;   this machine has, the policy, whether commands in its directory
;;   are confined -- its permission mode, whether it is interactive,
;;   the network, writing and the Linux capabilities of its commands:
;;   the sandbox drops every one, and you give it some (`C'), by name,
;;   or take them away; why none can be given when none can (the
;;   backend is not bwrap, the session is read-only) is said there.
;; - Directories: those it may write, those it may only read and those
;;   it gave up, each with where it comes from and what can be done
;;   with it: give it up or keep it for reading only, revoke a grant,
;;   restore one given up.  New ones are allowed, for writing or for
;;   reading only, and the session moves to another working directory.
;;   `harness-directories' (C-c h d) opens the view here.
;; - Tools: those it is offered and those it is not, with why; a tool is
;;   turned off for it, and on again, here.
;; - Rules: the permission rules that apply to it, and the tools that
;;   never ask.
;; - Waiting: the permission requests it waits on, as the chat's own
;;   panels, answered here as there.
;; - Judgements: every call of it the permission chain judged, newest
;;   first: what was decided, who decided it (you, a rule, the mode, the
;;   auto-mode judge, the jail, its access settings, a module's gate),
;;   why, and the call's handle, the id `rerun_approved' runs a denied
;;   call by once you approve it.  Each call is drawn by the chat itself
;;   (`harness-chat-insert-tool-call'), [Approve] and all, so it reads as
;;   it does in the conversation.  The list is filtered by what was
;;   decided, by who decided, by tool and by text.
;;
;; What you change here takes effect at once, and the session's
;; transcript says so.  The agent cannot change any of it this way: it
;; asks you for more with request_escalation, and gives some up with
;; drop_access (harness-access.el).  The buffer follows the session:
;; grants, prompts, judgements and changes to its access redraw it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-chat)
(require 'harness-ui-pending)

(declare-function harness-decision-undo "harness-ui-decisions")

(defgroup harness-ui-access nil
  "The access view of a session."
  :group 'harness-ui)

(defface harness-ui-access-heading-face
  '((t :inherit harness-label-face :height 1.1))
  "Headings of the access view's sections."
  :group 'harness-ui-access)

(defface harness-ui-access-allowed-face '((t :inherit harness-success-face))
  "What the access view says of what is allowed."
  :group 'harness-ui-access)

(defface harness-ui-access-denied-face '((t :inherit harness-failure-face))
  "What the access view says of what is denied, off or given up."
  :group 'harness-ui-access)

(defface harness-ui-access-waiting-face '((t :inherit harness-caution-face))
  "What the access view says of a call waiting for you."
  :group 'harness-ui-access)

(defface harness-ui-access-tool-face '((t :inherit button :underline nil))
  "The names of the tools a session is offered, each a button turning it off.
Not underlined, which would hide the underscores of the names."
  :group 'harness-ui-access)

(defcustom harness-ui-access-judgements-limit 100
  "How many judgements the access view lists, the newest first."
  :type 'integer :group 'harness-ui-access)

(defconst harness-ui-access--refresh-delay 0.3
  "Seconds the view waits after a change before it fetches again.
Changes come in bursts -- a turn's calls, a grant and its event -- which
one fetch covers.")

;;;; Buffer state

(defvar-local harness-ui-access--describe nil
  "What `access/describe' said last of this buffer's session.")

(defvar-local harness-ui-access--judgements nil
  "What `access/judgements' said last, for the buffer's filter.")

(defvar-local harness-ui-access--error nil
  "Why the last fetch failed, a string, or nil.")

(defvar-local harness-ui-access--deleted nil
  "Non-nil once the view's session was deleted: there is nothing to fetch.")

(defvar-local harness-ui-access--filter nil
  "The filter of the judgements: a plist of `:behavior', `:by', `:tool', `:query'.
Each is a string, or nil for any.")

(defvar-local harness-ui-access--generation 0
  "Bumped by every fetch, so the answer to an older one is dropped.")

(defvar-local harness-ui-access--timer nil
  "Timer of the fetch the buffer waits to make, or nil.")

(defvar-local harness-ui-access--stale nil
  "Non-nil when something changed while no window showed the buffer.")

(defvar-local harness-ui-access--goto nil
  "The section to put point at once the buffer is drawn, a symbol, or nil.")

(defun harness-ui-access--str (value)
  "Return VALUE, a symbol or a string from the harness, as a string, or nil."
  (cond ((null value) nil)
        ((eq value :false) nil)
        ((stringp value) value)
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun harness-ui-access--true-p (value)
  "Non-nil when VALUE, from the harness, is true."
  (harness-json-true-p value))

;;;; The buffer

(defun harness-ui-access--buffer-name (sid)
  "Return the name of the access view of session SID."
  (format "*harness access: %s*"
          (if-let* ((session (harness-ui-session sid)))
              (or (let ((name (plist-get session :name))) (and (stringp name) (not (string-empty-p name)) name))
                  (substring sid 0 (min 8 (length sid))))
            (substring sid 0 (min 8 (length sid))))))

(defun harness-ui-access--buffers (&optional sid)
  "Return the live access views, of session SID only when it is given."
  (cl-remove-if-not (lambda (buffer)
                      (with-current-buffer buffer
                        (and (derived-mode-p 'harness-ui-access-mode)
                             (or (null sid) (equal harness-ui-session-id sid)))))
                    (buffer-list)))

(defun harness-ui-access--buffer (sid)
  "Return the access view of session SID, made when there is none."
  (or (car (harness-ui-access--buffers sid))
      (let ((buffer (generate-new-buffer (harness-ui-access--buffer-name sid))))
        (with-current-buffer buffer
          (harness-ui-access-mode)
          (harness-chat-tool-view-setup sid)
          (setq-local harness-ui-pending-session-id sid)
          (setq-local harness-ui-pending-box-hints nil))
        buffer)))

;;;###autoload
(defun harness-access (&optional session-id section)
  "Show what SESSION-ID may reach, and how its calls were judged.
Interactively the current buffer's session, or one you choose.  The
view lists the session's sandbox, mode, directories, tools and rules,
the requests it waits on and the judgements of its calls, and changes
its access.  SECTION, a symbol, puts point at that section: `jail',
`directories', `tools', `rules', `waiting' or `judgements'.  Return the
buffer."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (buffer (harness-ui-access--buffer sid)))
    (with-current-buffer buffer
      (setq harness-ui-access--goto section)
      (harness-ui-access-refresh))
    (harness-ui-display-view buffer)
    buffer))

;;;###autoload
(defun harness-directories (&optional session-id)
  "Show the directories SESSION-ID may access, in its access view.
See `harness-access'."
  (interactive)
  (harness-access session-id 'directories))

;;;; Fetching

(defun harness-ui-access--filter-params ()
  "Return the buffer's filter as `access/judgements' takes it."
  (cl-loop for (key value) on harness-ui-access--filter by #'cddr
           when (and (stringp value) (not (string-empty-p value)))
           append (list key value)))

(defun harness-ui-access-refresh (&optional buffer)
  "Fetch what BUFFER's session may reach, and its judgements, and draw them.
BUFFER is the current buffer by default."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (when (timerp harness-ui-access--timer) (cancel-timer harness-ui-access--timer))
      (setq harness-ui-access--timer nil
            harness-ui-access--stale nil)
      (if harness-ui-access--deleted
          (harness-ui-access--render)
        (harness-ui-access--fetch buffer)))))

(defun harness-ui-access--fetch (buffer)
  "Fetch what BUFFER's session may reach, and its judgements, and draw them."
  (with-current-buffer buffer
    (let* ((sid harness-ui-session-id)
           (generation (cl-incf harness-ui-access--generation))
           (describe nil) (judgements nil) (pending nil) (left 3) (failure nil)
           (current-p (lambda ()
                        (and (buffer-live-p buffer)
                             (= generation (buffer-local-value 'harness-ui-access--generation buffer)))))
           (done (lambda ()
                   (when (and (zerop (cl-decf left)) (funcall current-p))
                     (with-current-buffer buffer
                       (if failure
                           (setq harness-ui-access--error failure)
                         (setq harness-ui-access--error nil
                               harness-ui-access--describe describe
                               harness-ui-access--judgements judgements)
                         ;; The requests it waits on join the store the
                         ;; chat and the popouts draw from, so the panels
                         ;; here answer them as there.
                         (harness-ui-pending-sync sid pending))
                       (harness-ui-access--render)))))
           (failed (lambda (e)
                     (unless (harness-ui-connection-replaced-p e)
                       (setq failure (harness-error-message e)))
                     (funcall done)
                     nil)))
      (harness-ui-call "_harness/access/describe" (list :session-id sid)
                       (lambda (d) (setq describe d) (funcall done))
                       failed)
      (harness-ui-call "_harness/access/judgements"
                       (append (list :session-id sid :limit harness-ui-access-judgements-limit)
                               (harness-ui-access--filter-params))
                       (lambda (j) (setq judgements j) (funcall done))
                       failed)
      (harness-ui-call "_harness/session/pending" (list :id sid)
                       (lambda (items) (setq pending items) (funcall done))
                       failed))))

(defun harness-ui-access--schedule (buffer)
  "Fetch BUFFER again soon, or once a window shows it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (not (get-buffer-window buffer t))
          (setq harness-ui-access--stale t)
        (unless (timerp harness-ui-access--timer)
          (setq harness-ui-access--timer
                (run-at-time harness-ui-access--refresh-delay nil
                             (lambda ()
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq harness-ui-access--timer nil)
                                   (harness-ui-access-refresh buffer)))))))))))

(defun harness-ui-access--shown (&rest _)
  "Fetch the buffer again when it is shown after changes it missed.
On `window-buffer-change-functions', buffer-locally."
  (when harness-ui-access--stale
    (harness-ui-access--schedule (current-buffer))))

;;;; Drawing: helpers

(defun harness-ui-access--heading (title section &optional note)
  "Insert the heading TITLE of SECTION, a symbol, with NOTE after it."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (propertize title 'face 'harness-ui-access-heading-face)
            (if note (concat "  " (propertize note 'face 'harness-dim-face)) "")
            "\n")
    (put-text-property start (point) 'harness-ui-access-anchor (cons 'section section))))

(defun harness-ui-access--button (label action help &optional face)
  "Return a button LABEL running ACTION, a function of no arguments, with HELP.
FACE is its face, `button' when nil."
  (harness-ui-action-button label action :help help :face face))

(defun harness-ui-access--pad (text width)
  "Return TEXT padded with spaces to WIDTH columns, or cut to it."
  (let ((text (or text "")))
    (if (> (string-width text) width)
        (concat (truncate-string-to-width text (max 1 (1- width))) "…")
      (concat text (make-string (- width (string-width text)) ?\s)))))

(defun harness-ui-access--row (label value &rest buttons)
  "Insert a row of the jail: LABEL, VALUE, then BUTTONS (strings or nil)."
  (insert "  " (propertize (harness-ui-access--pad label 12) 'face 'harness-dim-face) " " value)
  (let ((buttons (delq nil buttons)))
    (when buttons (insert "  " (string-join buttons " "))))
  (insert "\n"))

(defun harness-ui-access--after (message &optional buffer)
  "Return a callback saying MESSAGE, when non-nil, and fetching BUFFER again."
  (let ((buffer (or buffer (current-buffer))))
    (lambda (result)
      (cond ((stringp result) (message "%s" result))
            (message (message "%s" message)))
      (when (buffer-live-p buffer) (harness-ui-access-refresh buffer)))))

(defun harness-ui-access--session ()
  "Return the session id of this buffer, or signal."
  (or harness-ui-session-id (user-error "No session here")))

(defun harness-ui-access--wrap (items width &optional indent separator)
  "Insert ITEMS, strings, separated by SEPARATOR, wrapped at WIDTH columns.
Each line after the first starts with INDENT."
  (let* ((indent (or indent ""))
         (separator (or separator "  "))
         (column (current-column)))
    (dolist (item items)
      (let ((w (string-width item)))
        (when (and (> column (string-width indent)) (> (+ column w) width))
          (insert "\n" indent)
          (setq column (string-width indent)))
        (insert item separator)
        (setq column (+ column w (string-width separator)))))
    (insert "\n")))

(defun harness-ui-access--width ()
  "Return the width the view lays its rows out for."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 60 (- (if window (window-body-width window) 100) 2))))

;;;; Drawing: the session and its jail

(defun harness-ui-access--insert-title (d)
  "Insert the title of the view of the session `access/describe' described as D."
  (let* ((s (plist-get d :session))
         (sid (plist-get s :id))
         (cached (harness-ui-session sid))
         (name (or (plist-get s :name) (plist-get cached :name))))
    (insert (propertize (format "Access of %s" (if (and (stringp name) (not (string-empty-p name)))
                                                    (format "«%s»" name)
                                                  (format "session %s" (substring sid 0 (min 8 (length sid))))))
                        'face 'bold)
            (propertize (format "  %s · %s%s\n"
                                (harness-abbreviate-file-name (or (plist-get s :cwd) ""))
                                (or (harness-ui-access--str (plist-get s :kind)) "main")
                                (if (plist-get s :host) (format " · on %s" (plist-get s :host)) ""))
                        'face 'harness-dim-face))
    (insert (propertize "What you change here takes effect at once; the agent asks for more with request_escalation and gives some up with drop_access.\n"
                        'face 'harness-hint-face))))

(defun harness-ui-access--sandbox-text (sandbox)
  "Return what SANDBOX, the `:sandbox' of `access/describe', says, as text."
  (let* ((backend (or (harness-ui-access--str (plist-get sandbox :backend)) "none"))
         (available (mapcar #'harness-ui-access--str (plist-get sandbox :available)))
         (policy (harness-ui-access--str (plist-get sandbox :policy)))
         (confined (harness-ui-access--true-p (plist-get sandbox :confined))))
    (concat
     (propertize backend 'face (if (equal backend "none") 'harness-ui-access-denied-face 'bold))
     (propertize
      (concat (if available (format "  available: %s" (string-join available ", ")) "")
              (if policy (format "  policy: %s" policy) "")
              (cond ((harness-ui-access--true-p (plist-get sandbox :remote))
                     "  a remote session: its commands run on its host, outside the sandbox")
                    ((not (harness-ui-access--true-p (plist-get sandbox :module)))
                     "  no sandbox module: commands run unconfined")
                    (confined "  commands here run confined")
                    (t "  commands here cannot be confined")))
      'face 'harness-dim-face))))

(defun harness-ui-access--insert-jail (d)
  "Insert the jail section of the session described as D."
  (harness-ui-access--heading "Jail" 'jail)
  (let* ((sid (plist-get (plist-get d :session) :id))
         (mode (or (harness-ui-access--str (plist-get d :mode)) "ask"))
         (mode-entry (assoc mode harness-ui-permission-modes))
         (pinned (harness-ui-access--true-p (plist-get d :mode-pinned)))
         (away (harness-ui-access--true-p (plist-get d :non-interactive)))
         (away-pinned (harness-ui-access--true-p (plist-get d :non-interactive-pinned)))
         (network (harness-ui-access--true-p (plist-get d :network)))
         (read-only (harness-ui-access--true-p (plist-get d :read-only)))
         (own-ro (harness-ui-access--true-p (plist-get d :read-only-profile)))
         (other-ro (harness-ui-access--str (plist-get d :read-only-by))))
    (harness-ui-access--row "sandbox" (harness-ui-access--sandbox-text (plist-get d :sandbox)))
    (harness-ui-access--row
     "mode" (concat (propertize (or (nth 1 mode-entry) mode) 'face 'bold)
                    (propertize (format "  %s" (or (nth 2 mode-entry) "")) 'face 'harness-dim-face))
     (if pinned
         (propertize "set by the policy" 'face 'harness-dim-face)
       (harness-ui-access--button "[Change…]" (lambda () (harness-set-permission-mode sid))
                                  "Choose the session's permission mode (M)")))
    (harness-ui-access--row
     "interaction" (if away
                       (concat (propertize "non-interactive" 'face 'harness-ui-access-waiting-face)
                               (propertize "  nobody is asked: the auto-mode judge decides" 'face 'harness-dim-face))
                     (concat (propertize "interactive" 'face 'bold)
                             (propertize "  you are asked what the mode leaves open" 'face 'harness-dim-face)))
     (if away-pinned
         (propertize "set by the policy" 'face 'harness-dim-face)
       (harness-ui-access--button (if away "[Make interactive]" "[Make non-interactive]")
                                  (lambda () (harness-toggle-non-interactive sid))
                                  "Turn non-interactive mode on or off for the session (i)")))
    (harness-ui-access--row
     "network" (if network
                   (propertize "on" 'face 'harness-ui-access-allowed-face)
                 (concat (propertize "off" 'face 'harness-ui-access-denied-face)
                         (propertize "  no web tools, ssh or emacs_eval; bash and elisp run offline"
                                     'face 'harness-dim-face)))
     (harness-ui-access--button (if network "[Turn off]" "[Turn on]")
                                (lambda () (harness-ui-access-set-network (not network)))
                                "Let the session reach the network or not (N)"))
    (harness-ui-access--row
     "writing" (cond ((not read-only) (propertize "on" 'face 'harness-ui-access-allowed-face))
                     (own-ro (concat (propertize "read-only" 'face 'harness-ui-access-denied-face)
                                     (propertize "  only the reading tools; bash read-only and offline"
                                                 'face 'harness-dim-face)))
                     (t (concat (propertize "read-only" 'face 'harness-ui-access-denied-face)
                                (propertize (format "  by %s" (or other-ro "a module")) 'face 'harness-dim-face))))
     (cond ((and read-only (not own-ro)) nil)
           (t (harness-ui-access--button (if own-ro "[Allow writing]" "[Make read-only]")
                                         (lambda () (harness-ui-access-set-read-only (not own-ro)))
                                         "Let the session write, where its directories allow, or not (w)"))))
    (harness-ui-access--insert-capabilities d)
    (when (harness-ui-access--true-p (plist-get d :corporate))
      (harness-ui-access--row "corporate" (propertize "on: no tools of kind net but web search, no ssh"
                                                      'face 'harness-dim-face)))))

(defun harness-ui-access--capability-names (names)
  "Return NAMES, capability names from the harness, as a list of strings."
  (delq nil (mapcar #'harness-ui-access--str (and (listp names) names))))

(defun harness-ui-access--capability-doc (capabilities name)
  "Return what capability NAME lets a command do, from CAPABILITIES, or nil.
CAPABILITIES is the `:capabilities' of `access/describe'."
  (plist-get (cl-find name (plist-get capabilities :docs)
                      :key (lambda (entry) (plist-get entry :name)) :test #'equal)
             :doc))

(defun harness-ui-access--capabilities ()
  "Return the capabilities this buffer's description gives, or signal.
A harness that does not say (an older one) cannot be asked for any."
  (or (plist-get harness-ui-access--describe :capabilities)
      (user-error "This harness does not say what capabilities the session's commands may have")))

(defun harness-ui-access--capabilities-held (capabilities)
  "Return the names of the capabilities CAPABILITIES says the commands hold."
  (harness-ui-access--capability-names (plist-get capabilities :held)))

(defun harness-ui-access--capabilities-offer (capabilities)
  "Return the capabilities CAPABILITIES lets an agent ask for and does not hold."
  (let ((held (harness-ui-access--capabilities-held capabilities)))
    (seq-remove (lambda (name) (member name held))
                (harness-ui-access--capability-names (plist-get capabilities :grantable)))))

(defun harness-ui-access--insert-note (text)
  "Insert TEXT, dim, under the value of a jail row, wrapped to the view's width."
  (let ((indent (make-string 15 ?\s))
        (start (point)))
    (insert indent)
    (harness-ui-access--wrap
     (mapcar (lambda (word) (propertize word 'face 'harness-dim-face)) (split-string text " " t))
     (harness-ui-access--width) indent " ")
    ;; The wrapping leaves a space after the last word of each line.
    (let ((end (copy-marker (point))))
      (save-excursion
        (goto-char start)
        (while (re-search-forward " +$" end t)
          (replace-match "")))
      (set-marker end nil))))

(defun harness-ui-access--capabilities-note (d held)
  "Return what to say under the capabilities row of the session D, or nil.
D is its `access/describe'; HELD are the capabilities its commands
hold.  It says why none can be raised, or that those held are not
passed to the commands, and when they are, what they mean."
  (let* ((c (plist-get d :capabilities))
         (why (harness-ui-access--str (plist-get c :why)))
         (enforced (harness-ui-access--true-p (plist-get c :enforced)))
         (read-only (harness-ui-access--true-p (plist-get d :read-only)))
         (grantable (harness-ui-access--capability-names (plist-get c :grantable)))
         (unlisted (seq-remove (lambda (name) (member name grantable)) held)))
    (cond
     ((and held read-only)
      "held, but a read-only session's commands get none")
     ((and held (not enforced))
      (format "held, but not passed: %s" (or why "the sandbox does not enforce them here")))
     ((and held unlisted)
      (format "%s held, but not passed: the user no longer lets agents ask for %s"
              (string-join unlisted ", ") (if (cdr unlisted) "them" "it")))
     (held
      "its bash and elisp commands run with these and no other capability, inside the sandbox only")
     (why (format "cannot be raised: %s" why)))))

(defun harness-ui-access--insert-capabilities (d)
  "Insert the capabilities row of the jail of the session described as D.
The sandbox drops every Linux capability of the commands it runs; this
row says which the user gave the session's commands, and has buttons to
give one and take them away.  Nothing is drawn when D has no
`:capabilities': a harness that does not say cannot be asked."
  (when-let* ((c (plist-get d :capabilities))
              ((consp c)))
    (let* ((held (harness-ui-access--capabilities-held c))
           (offer (harness-ui-access--capabilities-offer c))
           (why (harness-ui-access--str (plist-get c :why))))
      (harness-ui-access--row
       "capabilities"
       (if held
           (propertize (string-join held ", ") 'face 'bold)
         (concat (propertize "none" 'face 'bold)
                 (propertize "  every capability is dropped" 'face 'harness-dim-face)))
       (and offer (not why)
            (harness-ui-access--button
             "[Give…]" (lambda () (call-interactively #'harness-ui-access-grant-capability))
             "Give the session's commands a Linux capability, inside the sandbox only (C)"))
       (and held
            (harness-ui-access--button
             "[Take away…]" (lambda () (call-interactively #'harness-ui-access-revoke-capability))
             "Take one capability away from the session's commands (C)"))
       (and held
            (harness-ui-access--button
             "[Take all away]" (lambda () (harness-ui-access-set-capability "all" nil))
             "Take every capability away from the session's commands (C, all)")))
      (when-let* ((note (harness-ui-access--capabilities-note d held)))
        (harness-ui-access--insert-note note)))))

;;;; Drawing: directories

(defun harness-ui-access--source-label (entry)
  "Return how the view names where directory ENTRY comes from."
  (pcase (harness-ui-access--str (plist-get entry :source))
    ("cwd" "working directory")
    ("worktree" "worktree")
    ("tmp" "temporary directory")
    ("config" "allowed for every session")
    ("session" "granted to this session")
    ("turn" "granted for this turn")
    ("outputs" "tool outputs")
    ("read" (if (harness-ui-access--true-p (plist-get entry :given-up))
                "read only (given up)"
              "read only"))
    ("dropped" "given up")
    (s (or s ""))))

(defun harness-ui-access--dir-buttons (sid entry)
  "Return the buttons of directory ENTRY of session SID."
  (let* ((dir (plist-get entry :dir))
         (source (harness-ui-access--str (plist-get entry :source)))
         (revocable (harness-ui-access--true-p (plist-get entry :revocable)))
         (shown (harness-abbreviate-file-name dir))
         (give-up (lambda (keep)
                    (harness-ui-access--button
                     (if keep "[Read only]" "[Give up]")
                     (lambda () (harness-ui-access-drop-dir dir keep))
                     (if keep (format "Let the session read %s but not write it" shown)
                       (format "Take %s away from the session" shown))))))
    (pcase source
      ((or "cwd" "worktree" "tmp") (list (funcall give-up nil) (funcall give-up t)))
      ("config" (delq nil (list (funcall give-up nil) (funcall give-up t)
                                (and revocable
                                     (harness-ui-access--button
                                      "[Revoke everywhere]"
                                      (lambda () (harness-ui-access-revoke dir t))
                                      (format "Take %s out of the directories every session may reach" shown))))))
      ((or "session" "turn")
       (list (harness-ui-access--button "[Revoke]" (lambda () (harness-ui-access-revoke dir nil))
                                        (format "Revoke the grant of %s" shown))
             (funcall give-up t)))
      ("read" (list (harness-ui-access--button "[Remove]" (lambda () (harness-ui-access-remove-read-dir dir))
                                               (format "Stop the session reading %s" shown))
                    (if (harness-ui-access--true-p (plist-get entry :given-up))
                        (harness-ui-access--button "[Restore]" (lambda () (harness-ui-access-restore-dir dir))
                                                   (format "Give %s back to the session, for writing too" shown))
                      (harness-ui-access--button "[Make writable]" (lambda () (harness-ui-access-make-writable dir))
                                                 (format "Grant %s to the session for writing" shown)))))
      ("dropped" (list (harness-ui-access--button "[Restore]" (lambda () (harness-ui-access-restore-dir dir))
                                                  (format "Give %s back to the session" shown))))
      (_ (ignore sid) nil))))

(defun harness-ui-access--insert-dirs (d)
  "Insert the directories section of the session described as D."
  (let* ((sid (plist-get (plist-get d :session) :id))
         (dirs (plist-get d :dirs))
         (width (min 60 (max 30 (apply #'max 0 (mapcar (lambda (e) (string-width (harness-abbreviate-file-name (plist-get e :dir))))
                                                        dirs))))))
    (harness-ui-access--heading "Directories" 'directories
                                "rw may be written, ro only read, -- given up")
    (dolist (e dirs)
      (let* ((start (point))
             (dropped (harness-ui-access--true-p (plist-get e :dropped)))
             (ro (harness-ui-access--true-p (plist-get e :read-only)))
             (outputs (equal (harness-ui-access--str (plist-get e :source)) "outputs"))
             (tag (cond (dropped (propertize "--" 'face 'harness-ui-access-denied-face))
                        ((or ro outputs) (propertize "ro" 'face 'harness-ui-access-waiting-face))
                        (t (propertize "rw" 'face 'harness-ui-access-allowed-face))))
             (buttons (harness-ui-access--dir-buttons sid e)))
        (insert "  " tag "  "
                (propertize (harness-ui-access--pad (harness-abbreviate-file-name (plist-get e :dir)) width)
                            'face (if dropped 'harness-dim-face 'default))
                "  "
                (propertize (harness-ui-access--pad (harness-ui-access--source-label e) 26) 'face 'harness-dim-face)
                (if buttons (concat "  " (string-join buttons " ")) "")
                "\n")
        (add-text-properties start (point) (list 'harness-ui-access-anchor (cons 'dir (plist-get e :dir))
                                                 'harness-ui-access-dir e))))
    (insert "  "
            (harness-ui-access--button "[Allow a directory…]" #'harness-ui-access-allow-dir
                                       "Grant the session a directory to write; with a prefix argument, every session (a)")
            " "
            (harness-ui-access--button "[Allow reading a directory…]" #'harness-ui-access-allow-read-dir
                                       "Let the session read a directory, not write it (r)")
            " "
            (harness-ui-access--button "[Move the session…]" #'harness-ui-access-move
                                       "Move the session to another working directory (m)")
            "\n")
    (let ((inspect (plist-get d :inspect))
          (skills (plist-get d :skills)))
      (when (or inspect skills)
        (insert (propertize
                 (format "  Every call that only reads also reaches %s.\n"
                         (string-join (append (mapcar (lambda (dir) (format "%s (the harness)" (harness-abbreviate-file-name dir))) inspect)
                                              (mapcar (lambda (dir) (format "%s (skills)" (harness-abbreviate-file-name dir))) skills))
                                      ", "))
                 'face 'harness-dim-face))))))

;;;; Drawing: tools and rules

(defun harness-ui-access--insert-tools (d)
  "Insert the tools section of the session described as D."
  (let* ((tools (plist-get d :tools))
         (on (plist-get tools :on))
         (all-off (plist-get tools :off))
         (elsewhere (seq-filter (lambda (e) (harness-ui-access--true-p (plist-get e :elsewhere))) all-off))
         (off (seq-remove (lambda (e) (memq e elsewhere)) all-off))
         (builtin (plist-get tools :builtin)))
    (harness-ui-access--heading "Tools" 'tools
                                (format "%d offered · %d off%s" (length on) (length off)
                                        (if elsewhere (format " · %d for other sessions" (length elsewhere)) "")))
    (dolist (e off)
      (let* ((start (point))
             (name (plist-get e :name))
             (profile (harness-ui-access--true-p (plist-get e :profile)))
             (why (or (plist-get e :why) "")))
        (insert "  " (propertize "off" 'face 'harness-ui-access-denied-face) "  "
                (harness-ui-access--pad name 24) "  "
                (propertize (harness-ui-access--pad why 30) 'face 'harness-dim-face)
                (cond (profile (concat "  " (harness-ui-access--button "[Turn on]" (lambda () (harness-ui-access-set-tool name t))
                                                                       (format "Offer %s to the session again" name))))
                      ((equal why "no network")
                       (concat "  " (harness-ui-access--button "[Turn the network on]"
                                                               (lambda () (harness-ui-access-set-network t))
                                                               "Let the session reach the network again")))
                      (t ""))
                "\n")
        (put-text-property start (point) 'harness-ui-access-anchor (cons 'tool name))))
    (let ((start (point)))
      (insert "  " (propertize "on " 'face 'harness-ui-access-allowed-face) "  ")
      (harness-ui-access--wrap
       (mapcar (lambda (name)
                 (harness-ui-access--button
                  (if (member name builtin) (concat name "*") name)
                  (lambda () (when (y-or-n-p (format "Turn %s off for this session? " name))
                               (harness-ui-access-set-tool name nil)))
                  (format "%s%s: click to turn it off for this session"
                          (harness-ui-tool-label name)
                          (if (member name builtin) " (run by the session's provider)" ""))
                  'harness-ui-access-tool-face))
               on)
       (harness-ui-access--width) "       ")
      (put-text-property start (point) 'harness-ui-access-anchor (cons 'tools-on t)))
    ;; Tools of other kinds of session (a task's hand_in, a supervisor's
    ;; plan tools): nobody turned them off, so they are only named.
    (when elsewhere
      (insert "  " (propertize "n/a" 'face 'harness-dim-face) "  ")
      (harness-ui-access--wrap
       (cons (propertize "for other kinds of session:" 'face 'harness-dim-face)
             (mapcar (lambda (e) (propertize (plist-get e :name) 'face 'harness-dim-face)) elsewhere))
       (harness-ui-access--width) "       "))
    (when builtin
      (insert (propertize "  * run by the session's provider, under the harness's permission\n" 'face 'harness-dim-face)))))

(defun harness-ui-access--input-text (input)
  "Return the clause that says what the arguments INPUT of a rule hold, or nil.
It reads `whose host is exactly \"box\"' or `whose host is exactly \"box\"
and command is exactly \"ls\"', as the permission module words it (a
module this view cannot call: it may run in a process of its own).  A
rule for one host, as a lasting answer to an ssh call makes, would
otherwise read as one for every host."
  (when (and (consp input) (proper-list-p input) (cl-evenp (length input))
             (cl-loop for (k _v) on input by #'cddr always (keywordp k)))
    (let ((words (cl-loop for (k v) on input by #'cddr
                          collect (format "%s is exactly %s" (substring (symbol-name k) 1)
                                          (if (stringp v)
                                              (let* ((text (string-trim v))
                                                     (line (harness-first-line text)))
                                                (format "\"%s\""
                                                        (if (or (string-search "\n" text) (> (length line) 50))
                                                            (concat (substring line 0 (min (length line) 49)) "…")
                                                          line)))
                                            (format "%s" v))))))
      (concat "whose "
              (if (cdr words)
                  (concat (string-join (butlast words) ", ") " and " (car (last words)))
                (car words))))))

(defun harness-ui-access--rule-text (rule)
  "Return RULE, a permission rule, as one line."
  (let* ((behavior (or (harness-ui-access--str (plist-get rule :behavior)) "?"))
         (tool (harness-ui-access--str (plist-get rule :tool)))
         (kind (harness-ui-access--str (plist-get rule :kind)))
         (path (plist-get rule :path))
         (commands (plist-get rule :commands))
         (input (harness-ui-access--input-text (plist-get rule :input))))
    (concat (propertize behavior 'face (if (equal behavior "allow") 'harness-ui-access-allowed-face
                                         'harness-ui-access-denied-face))
            " "
            (cond (tool tool) (kind (format "any %s tool" kind)) (t "any tool"))
            (if commands
                (format ": %s" (mapconcat (lambda (c) (if (listp c) (string-join (mapcar (lambda (w) (format "%s" w)) c) " ")
                                                       (format "%s" c)))
                                          commands ", "))
              "")
            (if input (concat " " input) "")
            (if path (format " in %s" (harness-abbreviate-file-name path)) ""))))

(defun harness-ui-access--insert-rules (d)
  "Insert the rules section of the session described as D."
  (let* ((rules (plist-get d :rules))
         (session (plist-get rules :session))
         (always (plist-get rules :always))
         (never-ask (plist-get d :never-ask)))
    (harness-ui-access--heading "Rules" 'rules
                                "the first that matches a call decides it, after the jail")
    (if (not (or session always))
        (insert (propertize "  No rules: the mode decides, and asks you what it leaves open.\n" 'face 'harness-dim-face))
      (dolist (r session)
        (insert "  " (propertize (harness-ui-access--pad "this session" 14) 'face 'harness-dim-face)
                (harness-ui-access--rule-text r) "\n"))
      (dolist (r always)
        (insert "  " (propertize (harness-ui-access--pad "every session" 14) 'face 'harness-dim-face)
                (harness-ui-access--rule-text r) "\n")))
    (when never-ask
      (insert "  " (propertize (harness-ui-access--pad "never ask" 14) 'face 'harness-dim-face))
      (harness-ui-access--wrap (mapcar (lambda (n) (format "%s" n)) never-ask)
                               (harness-ui-access--width) (make-string 16 ?\s) " "))
    (when (fboundp 'harness-decision-undo)
      (insert "  " (harness-ui-access--button "[Undo a decision…]" #'harness-decision-undo
                                              "Take back a lasting answer: a rule recorded from a prompt, say")
              "\n"))))

;;;; Drawing: waiting requests and judgements

(defun harness-ui-access--waiting ()
  "Return the permission requests this buffer's session waits on, as records."
  (cl-remove-if-not (lambda (r) (equal (plist-get r :kind) "permission"))
                    (harness-ui-pending-items harness-ui-session-id)))

(defun harness-ui-access--insert-waiting (records)
  "Insert the permission requests RECORDS the session waits on, as panels."
  (when records
    (harness-ui-access--heading "Waiting for you" 'waiting (format "%d" (length records)))
    (dolist (r records)
      (let ((start (point)))
        (harness-ui-pending-insert-panel r)
        (put-text-property start (point) 'harness-ui-access-anchor (cons 'pending (plist-get r :id)))))))

(defconst harness-ui-access--by-labels
  '(("user" . "you") ("rule" . "a rule") ("mode" . "the mode") ("judge" . "the auto-mode judge")
    ("jail" . "the jail") ("gate" . "a module's gate") ("access" . "the access settings")
    ("away" . "nobody to ask") ("corporate" . "corporate mode"))
  "How the view names who decided a call, by the harness's name for them.")

(defun harness-ui-access--by-label (by)
  "Return how the view names BY, who decided a call."
  (let ((by (harness-ui-access--str by)))
    (cond ((null by) "the harness")
          ((cdr (assoc by harness-ui-access--by-labels)))
          (t by))))

(defun harness-ui-access--time (at)
  "Return AT, a float time, short: the time of day, with the date when not today."
  (if (not (numberp at))
      ""
    (format-time-string (if (equal (format-time-string "%F" at) (format-time-string "%F")) "%H:%M:%S" "%b %d %H:%M")
                        at)))

(defun harness-ui-access--judgement-line (item)
  "Return the line above the call of judgement ITEM: what, who, the handle."
  (let* ((behavior (harness-ui-access--str (plist-get item :behavior)))
         (by (plist-get item :by))
         (head (pcase behavior
                 ("allow" (propertize "✓ allowed" 'face 'harness-ui-access-allowed-face))
                 ("deny" (propertize "✗ denied" 'face 'harness-ui-access-denied-face))
                 ("ask" (propertize "? waiting for you" 'face 'harness-ui-access-waiting-face))
                 (_ (propertize "· not judged" 'face 'harness-dim-face))))
         (who (unless (equal behavior "ask")
                (if (and (equal behavior "deny") (equal (harness-ui-access--str by) "away"))
                    " · nobody to ask"
                  (format " by %s" (harness-ui-access--by-label by)))))
         (reason (plist-get item :reason)))
    (concat "  " head (or who "")
            (propertize (format " · handle %s · %s" (plist-get item :call-id)
                                (harness-ui-access--time (plist-get item :at)))
                        'face 'harness-dim-face)
            "\n"
            (if (and (stringp reason) (not (string-blank-p reason)))
                (propertize (format "    %s\n" (harness-ui-one-line reason)) 'face 'harness-dim-face)
              ""))))

(defun harness-ui-access--waiting-buttons (item)
  "Return the line of buttons answering the waiting call of judgement ITEM."
  (let ((sid harness-ui-session-id)
        (pid (plist-get item :pending-id)))
    (when pid
      (concat "    "
              (harness-ui-access--button "[Allow]" (lambda () (harness-ui-pending-answer-permission sid pid "allow-once"))
                                         "Allow this call once")
              " "
              (harness-ui-access--button "[Deny]" (lambda () (harness-ui-pending-answer-permission sid pid "deny-once"))
                                         "Deny this call once")
              " "
              (harness-ui-access--button "[More answers…]" (lambda () (harness-ui-access--goto-anchor (cons 'pending pid)))
                                         "Go to the request's panel, with every answer")
              "\n"))))

(defun harness-ui-access--filter-line (j)
  "Return the line of the judgements' filter.
J is what `access/judgements' said."
  (let* ((behavior (plist-get harness-ui-access--filter :behavior))
         (counts (plist-get j :counts))
         (choice (lambda (label value count)
                   (let ((b (harness-ui-access--button
                             (format "[%s%s]" label (if count (format " %d" count) ""))
                             (lambda () (harness-ui-access-filter-behavior value))
                             (format "Show %s (f)" (if value (downcase label) "every judgement")))))
                     ;; The one shown stands out.
                     (when (equal behavior value) (add-face-text-property 0 (length b) 'bold nil b))
                     b))))
    (concat "  "
            (string-join (list (funcall choice "All" nil nil)
                               (funcall choice "Denied" "deny" (plist-get counts :deny))
                               (funcall choice "Asked" "asked" nil)
                               (funcall choice "Allowed" "allow" (plist-get counts :allow))
                               (funcall choice "Waiting" "ask" (plist-get counts :ask)))
                         " ")
            "   "
            (harness-ui-access--button (format "[decided by: %s]" (if-let* ((by (plist-get harness-ui-access--filter :by)))
                                                                     (harness-ui-access--by-label by) "anyone"))
                                       #'harness-ui-access-filter-by "Show the calls one decider judged (b)")
            " "
            (harness-ui-access--button (format "[tool: %s]" (or (plist-get harness-ui-access--filter :tool) "any"))
                                       #'harness-ui-access-filter-tool "Show the calls of one tool (t)")
            " "
            (harness-ui-access--button (format "[text: %s]" (or (plist-get harness-ui-access--filter :query) "—"))
                                       #'harness-ui-access-filter-text
                                       "Show the calls whose tool, reason, handle or title has some text (s)")
            (if harness-ui-access--filter
                (concat " " (harness-ui-access--button "[Clear]" #'harness-ui-access-filter-clear "Show every judgement (c)"))
              "")
            "\n")))

(defun harness-ui-access--insert-judgements (j expanded)
  "Insert the judgements J, from `access/judgements'.
EXPANDED are the ids of the calls to draw unfolded."
  (let* ((items (plist-get j :items))
         (total (or (plist-get j :total) 0))
         (counts (plist-get j :counts)))
    (harness-ui-access--heading
     "Judgements" 'judgements
     (format "%s · allowed %d · denied %d · waiting %d"
             (if (> total (length items)) (format "the newest %d of %d" (length items) total) (format "%d" total))
             (or (plist-get counts :allow) 0) (or (plist-get counts :deny) 0) (or (plist-get counts :ask) 0)))
    (insert (harness-ui-access--filter-line j))
    (if (null items)
        (insert (propertize (if harness-ui-access--filter "  No call matches the filter.\n" "  No call was judged yet.\n")
                            'face 'harness-dim-face))
      (dolist (item items)
        (let ((start (point))
              (call (plist-get item :call)))
          ;; A blank line apart; a call's block ends with one of its own.
          (unless (looking-back "\n\n" (max (point-min) (- (point) 2)))
            (insert "\n"))
          (insert (harness-ui-access--judgement-line item))
          (when (equal (harness-ui-access--str (plist-get item :behavior)) "ask")
            (insert (or (harness-ui-access--waiting-buttons item) "")))
          (when call
            (harness-chat-insert-tool-call call (plist-get item :result)
                                           (member (plist-get item :call-id) expanded)))
          (put-text-property start (point) 'harness-ui-access-anchor (cons 'call (plist-get item :call-id))))))))

;;;; Drawing: the whole buffer

(defun harness-ui-access--anchor-at (pos)
  "Return the anchor at POS and how far POS lies into it, as (ANCHOR . OFFSET)."
  (when-let* ((anchor (get-text-property pos 'harness-ui-access-anchor)))
    (let ((start (or (previous-single-property-change (min (1+ pos) (point-max)) 'harness-ui-access-anchor)
                     (point-min))))
      (cons anchor (- pos start)))))

(defun harness-ui-access--find-anchor (anchor)
  "Return the start of the text of ANCHOR, or nil."
  (let ((pos (point-min)) found)
    (while (and pos (not found) (< pos (point-max)))
      (if (equal (get-text-property pos 'harness-ui-access-anchor) anchor)
          (setq found pos)
        (setq pos (next-single-property-change pos 'harness-ui-access-anchor))))
    found))

(defun harness-ui-access--goto-anchor (anchor)
  "Put point at the start of ANCHOR's text, when the buffer has it."
  (if-let* ((pos (harness-ui-access--find-anchor anchor)))
      (progn (goto-char pos)
             (when-let* ((w (get-buffer-window (current-buffer))))
               (set-window-point w pos)
               (with-selected-window w (recenter 0))))
    (message "Not shown here")))

(defun harness-ui-access--render ()
  "Draw the buffer from what was fetched last, keeping point and the windows."
  (let* ((inhibit-read-only t)
         (here (harness-ui-access--anchor-at (point)))
         (windows (mapcar (lambda (w) (list w (harness-ui-access--anchor-at (window-start w))
                                            (harness-ui-access--anchor-at (window-point w))))
                          (get-buffer-window-list (current-buffer) nil t)))
         (expanded (harness-chat-tool-view-expanded))
         (d harness-ui-access--describe))
    (harness-chat-tool-view-setup harness-ui-session-id)
    (erase-buffer)
    (cond
     (harness-ui-access--deleted
      (insert (propertize (format "Session %s was deleted: it reaches nothing any more.\n"
                                  (if-let* ((name (plist-get (plist-get d :session) :name)))
                                      (format "«%s»" name)
                                    (substring harness-ui-session-id 0 (min 8 (length harness-ui-session-id)))))
                          'face 'harness-dim-face)))
     (harness-ui-access--error
      (insert (propertize (format "Could not read the access of this session: %s\n" harness-ui-access--error)
                          'face 'harness-failure-face)
              (propertize "Is the access module on in the harness?  M-x harness-describe-modules says.\n"
                          'face 'harness-hint-face)))
     ((null d) (insert (propertize "Loading…\n" 'face 'harness-dim-face)))
     (t
      (harness-ui-access--insert-title d)
      (harness-ui-access--insert-jail d)
      (harness-ui-access--insert-dirs d)
      (harness-ui-access--insert-tools d)
      (harness-ui-access--insert-rules d)
      (harness-ui-access--insert-waiting (harness-ui-access--waiting))
      (harness-ui-access--insert-judgements harness-ui-access--judgements expanded)))
    (let ((restore (lambda (spot)
                     (when-let* ((pos (and spot (harness-ui-access--find-anchor (car spot)))))
                       (min (point-max) (+ pos (cdr spot)))))))
      (cond
       (harness-ui-access--goto
        (let ((pos (or (harness-ui-access--find-anchor (cons 'section harness-ui-access--goto)) (point-min))))
          (setq harness-ui-access--goto nil)
          (goto-char pos)
          (dolist (w (get-buffer-window-list (current-buffer) nil t))
            (set-window-start w pos)
            (set-window-point w pos))))
       (t
        (goto-char (or (funcall restore here) (point-min)))
        (dolist (entry windows)
          (let ((w (nth 0 entry)))
            (when (window-live-p w)
              (when-let* ((start (funcall restore (nth 1 entry))))
                (set-window-start w (save-excursion (goto-char start) (line-beginning-position)) t))
              (when-let* ((pt (funcall restore (nth 2 entry))))
                (set-window-point w pt))))))))
    (force-mode-line-update)))

(defun harness-ui-access--header ()
  "Return the header line of the view."
  (let* ((d harness-ui-access--describe)
         (s (harness-ui-session harness-ui-session-id)))
    (harness-ui-mode-line-escape
     (concat " " (propertize "Access" 'face 'bold)
             (if s (concat "  " (harness-ui-session-label s)) "")
             (if d
                 (propertize
                  (format "  ·  sandbox %s · %s · network %s%s"
                          (or (harness-ui-access--str (plist-get (plist-get d :sandbox) :backend)) "none")
                          (or (harness-ui-access--str (plist-get d :mode)) "ask")
                          (if (harness-ui-access--true-p (plist-get d :network)) "on" "off")
                          (if (harness-ui-access--true-p (plist-get d :read-only)) " · read-only" ""))
                  'face 'harness-dim-face)
               "")))))

;;;; Commands

(defun harness-ui-access-set-network (on)
  "Let this buffer's session reach the network when ON, else not."
  (interactive (list (not (harness-ui-access--true-p (plist-get harness-ui-access--describe :network)))))
  (harness-ui-call "_harness/access/set-network" (list :session-id (harness-ui-access--session) :on (if on t :false))
                   (harness-ui-access--after (if on "Network on" "Network off"))))

(defun harness-ui-access-toggle-network ()
  "Turn the network of this buffer's session on or off."
  (interactive)
  (harness-ui-access-set-network (not (harness-ui-access--true-p (plist-get harness-ui-access--describe :network)))))

(defun harness-ui-access-set-read-only (on)
  "Keep this buffer's session from writing when ON, else let it write."
  (harness-ui-call "_harness/access/set-read-only" (list :session-id (harness-ui-access--session) :on (if on t :false))
                   (harness-ui-access--after (if on "The session is read-only" "The session may write"))))

(defun harness-ui-access-toggle-writing ()
  "Make this buffer's session read-only, or let it write again."
  (interactive)
  (let ((d harness-ui-access--describe))
    (when (and (harness-ui-access--true-p (plist-get d :read-only))
               (not (harness-ui-access--true-p (plist-get d :read-only-profile))))
      (user-error "The session is read-only by %s, which this view does not change"
                  (or (harness-ui-access--str (plist-get d :read-only-by)) "another module")))
    (harness-ui-access-set-read-only (not (harness-ui-access--true-p (plist-get d :read-only-profile))))))

(defun harness-ui-access-set-tool (tool on)
  "Turn TOOL on for this buffer's session when ON, else off."
  (harness-ui-call "_harness/access/set-tool" (list :session-id (harness-ui-access--session) :tool tool :on (if on t :false))
                   (harness-ui-access--after (format "%s turned %s" tool (if on "on" "off")))))

(defun harness-ui-access-toggle-tool (tool)
  "Turn TOOL off for this buffer's session, or on again when it is off."
  (interactive
   (let* ((tools (plist-get harness-ui-access--describe :tools))
          (names (append (plist-get tools :on) (mapcar (lambda (e) (plist-get e :name)) (plist-get tools :off)))))
     (list (completing-read "Turn on or off the tool: " names nil t))))
  (let* ((off (cl-find tool (plist-get (plist-get harness-ui-access--describe :tools) :off)
                       :key (lambda (e) (plist-get e :name)) :test #'equal)))
    (cond ((null off) (harness-ui-access-set-tool tool nil))
          ((harness-ui-access--true-p (plist-get off :profile)) (harness-ui-access-set-tool tool t))
          (t (user-error "%s is off: %s; this view turns on only the tools turned off for the session"
                         tool (plist-get off :why))))))

(defun harness-ui-access-set-capability (name on)
  "Give the session's commands the capability NAME when ON, else take it away.
This buffer's session is the one.  NAME is `all' to take every one
away.  It takes effect at once, from the next bash or elisp command on;
the harness refuses to give one the sandbox would not pass on, and the
echo area says so."
  (harness-ui-call "_harness/access/set-capability"
                   (list :session-id (harness-ui-access--session) :name name :on (if on t :false))
                   (harness-ui-access--after
                    (cond ((equal name "all") "No capability left for the session's commands")
                          (on (format "%s given to the session's commands" name))
                          (t (format "%s taken away from the session's commands" name))))))

(defun harness-ui-access--read-capability (prompt candidates)
  "Read one of CANDIDATES with PROMPT, each shown with what it lets a command do.
A candidate starts with a capability's name, which the annotation looks
up in this buffer's description."
  (let* ((capabilities (plist-get harness-ui-access--describe :capabilities))
         (completion-extra-properties
          (list :annotation-function
                (lambda (candidate)
                  (let ((doc (harness-ui-access--capability-doc
                              capabilities (car (split-string candidate " ")))))
                    (if doc (concat "  " doc) ""))))))
    (completing-read prompt candidates nil t)))

(defun harness-ui-access-grant-capability (name)
  "Give this buffer's session's commands the Linux capability NAME.
Interactively choose among those an agent may ask for that they do not
hold yet, each with what it lets a command do.  Nothing is asked of
anyone else: you change the session's profile here, and the sandbox
passes it to its bash and elisp commands from the next one on, where it
can (bwrap, for a session that may write)."
  (interactive
   (let* ((c (harness-ui-access--capabilities))
          (why (harness-ui-access--str (plist-get c :why)))
          (offer (harness-ui-access--capabilities-offer c)))
     (when why (user-error "No capability can be given now: %s" why))
     (unless offer (user-error "Every capability an agent may ask for is given already"))
     (list (harness-ui-access--read-capability "Give the session's commands: " offer))))
  (harness-ui-access-set-capability name t))

(defun harness-ui-access-revoke-capability (name)
  "Take the capability NAME away from this buffer's session's commands.
NAME is `all' to take every one away.  Interactively choose one of those
the commands hold."
  (interactive
   (let ((held (harness-ui-access--capabilities-held (harness-ui-access--capabilities))))
     (unless held (user-error "The session's commands hold no capability"))
     (list (harness-ui-access--read-capability "Take away: " held))))
  (harness-ui-access-set-capability name nil))

(defun harness-ui-access-toggle-capability (name)
  "Give the session's commands the capability NAME, or take it away when held.
This buffer's session is the one.  Interactively choose among the
capabilities they hold, marked, which are taken away, and those an agent
may ask for, which are given, each with what it lets a command do;
`all' takes every one away.  Where none can be given -- the sandbox
cannot pass them on, the session is read-only -- only those held are
offered."
  (interactive
   (let* ((c (harness-ui-access--capabilities))
          (why (harness-ui-access--str (plist-get c :why)))
          (held (harness-ui-access--capabilities-held c))
          (table (append (mapcar (lambda (capability) (cons (concat capability " (held)") capability)) held)
                         (and (null why) (mapcar (lambda (capability) (cons capability capability))
                                                 (harness-ui-access--capabilities-offer c)))
                         (and held (list (cons "all (take every one away)" "all"))))))
     (when (and why (null held)) (user-error "No capability can be given now: %s" why))
     (list (cdr (assoc (harness-ui-access--read-capability "Give or take away: " (mapcar #'car table))
                       table)))))
  (harness-ui-access-set-capability
   name (not (or (equal name "all")
                 (member name (harness-ui-access--capabilities-held
                               (plist-get harness-ui-access--describe :capabilities)))))))

(defun harness-ui-access--dir-at-point ()
  "Return the directory entry at point, or signal."
  (or (get-text-property (point) 'harness-ui-access-dir)
      (user-error "No directory here")))

(defun harness-ui-access-drop-dir (dir &optional keep-read)
  "Take DIR away from this buffer's session; with KEEP-READ keep it readable."
  (harness-ui-call "_harness/access/drop-dir"
                   (append (list :session-id (harness-ui-access--session) :dir dir)
                           (and keep-read (list :keep-read t)))
                   (harness-ui-access--after nil)))

(defun harness-ui-access-revoke (dir &optional everywhere)
  "Revoke the grant of DIR to this buffer's session.
EVERYWHERE says DIR is one every session may reach: it is taken out of
`harness-allowed-directories', after you confirm."
  (when (or (not everywhere)
            (y-or-n-p (format "Revoke %s for every session? " (harness-abbreviate-file-name dir))))
    (harness-ui-call "_harness/permission/revoke-dir" (list :session-id (harness-ui-access--session) :dir dir)
                     (harness-ui-access--after (format "Revoked %s" (harness-abbreviate-file-name dir))))))

(defun harness-ui-access-remove-read-dir (dir)
  "Stop this buffer's session reading DIR."
  (harness-ui-call "_harness/access/remove-read-dir" (list :session-id (harness-ui-access--session) :dir dir)
                   (harness-ui-access--after (format "%s may no longer be read" (harness-abbreviate-file-name dir)))))

(defun harness-ui-access-make-writable (dir)
  "Grant DIR, which this buffer's session may only read, for writing too."
  (let ((sid (harness-ui-access--session)))
    (harness-ui-call "_harness/permission/allow-dir" (list :session-id sid :dir dir)
                     (lambda (_)
                       (harness-ui-call "_harness/access/remove-read-dir" (list :session-id sid :dir dir)
                                        (harness-ui-access--after (format "%s may be written" (harness-abbreviate-file-name dir))))))))

(defun harness-ui-access-restore-dir (dir)
  "Give this buffer's session back DIR, which it gave up."
  (harness-ui-call "_harness/access/restore-dir" (list :session-id (harness-ui-access--session) :dir dir)
                   (harness-ui-access--after (format "%s given back" (harness-abbreviate-file-name dir)))))

(defun harness-ui-access--start-dir ()
  "Return the directory to start reading a directory from.
That is nil for a remote session, so that no TRAMP connection opens."
  (let ((s (harness-ui-session harness-ui-session-id)))
    (unless (plist-get s :host) (plist-get s :cwd))))

(defun harness-ui-access--read-dir (prompt)
  "Read a directory with PROMPT, as text for a remote session."
  (let ((start (harness-ui-access--start-dir)))
    (if start (read-directory-name prompt start nil t) (read-string prompt))))

(defun harness-ui-access-allow-dir (dir &optional always)
  "Grant this buffer's session DIR to write.
With a prefix argument ALWAYS, every session: DIR joins
`harness-allowed-directories'."
  (interactive (list (harness-ui-access--read-dir (if current-prefix-arg "Allow for every session: "
                                                    "Allow for this session: "))
                     current-prefix-arg))
  (harness-ui-call "_harness/permission/allow-dir"
                   (append (list :session-id (harness-ui-access--session) :dir dir) (and always (list :scope "always")))
                   (harness-ui-access--after (format "Allowed %s%s" (harness-abbreviate-file-name dir)
                                                     (if always " for every session" "")))))

(defun harness-ui-access-allow-read-dir (dir)
  "Let this buffer's session read DIR, not write it."
  (interactive (list (harness-ui-access--read-dir "Allow reading: ")))
  (harness-ui-call "_harness/access/add-read-dir" (list :session-id (harness-ui-access--session) :dir dir)
                   (harness-ui-access--after nil)))

(defun harness-ui-access-move (directory &optional keep-old)
  "Move this buffer's session to the working directory DIRECTORY.
With a prefix argument KEEP-OLD its old working directory stays allowed
to it.  See `harness-move-session'."
  (interactive (list (harness-ui-read-move-directory (harness-ui-session harness-ui-session-id))
                     current-prefix-arg))
  (harness-move-session directory (harness-ui-access--session) keep-old))

(defun harness-ui-access-take-away ()
  "Take the directory at point away from the session, as its first button does.
A grant is revoked, a read-only directory forgotten, the working
directory, the worktree, the temporary directory or a configured one
given up for this session alone, after you confirm."
  (interactive)
  (let* ((e (harness-ui-access--dir-at-point))
         (dir (plist-get e :dir))
         (shown (harness-abbreviate-file-name dir)))
    (pcase (harness-ui-access--str (plist-get e :source))
      ((or "session" "turn") (harness-ui-access-revoke dir))
      ("read" (harness-ui-access-remove-read-dir dir))
      ("dropped" (user-error "%s is given up already: R restores it" shown))
      ("outputs" (user-error "The tool output directory is the harness's, and stays"))
      (_ (when (y-or-n-p (format "Give up %s for this session? " shown))
           (harness-ui-access-drop-dir dir))))))

(defun harness-ui-access-restore-at-point ()
  "Give the session back the directory at point, which it gave up."
  (interactive)
  (let ((e (harness-ui-access--dir-at-point)))
    (unless (or (harness-ui-access--true-p (plist-get e :dropped))
                (harness-ui-access--true-p (plist-get e :given-up)))
      (user-error "%s was not given up" (harness-abbreviate-file-name (plist-get e :dir))))
    (harness-ui-access-restore-dir (plist-get e :dir))))

(defun harness-ui-access-set-mode ()
  "Choose the permission mode of this buffer's session."
  (interactive)
  (harness-set-permission-mode (harness-ui-access--session)))

(defun harness-ui-access-toggle-interaction ()
  "Turn non-interactive mode on or off for this buffer's session."
  (interactive)
  (harness-toggle-non-interactive (harness-ui-access--session)))

(defun harness-ui-access-visit ()
  "Push the button at point, or open the directory at point in Dired."
  (interactive)
  (cond ((get-text-property (point) 'harness-ui-action) (harness-ui-action-push))
        ((get-text-property (point) 'harness-chat-action) (harness-chat-push))
        ((get-text-property (point) 'harness-ui-access-dir)
         (let ((dir (plist-get (get-text-property (point) 'harness-ui-access-dir) :dir)))
           (if (file-directory-p dir) (dired-other-window dir) (message "%s is not a directory here" dir))))
        (t (user-error "Nothing to do here"))))

(defun harness-ui-access-toggle ()
  "Fold or unfold the call at point, or move to the next button."
  (interactive)
  (if (get-text-property (point) 'harness-chat-node)
      (harness-chat-toggle-block)
    (forward-button 1 t)))

(defun harness-ui-access--starts (kind)
  "Return where each text anchored as KIND starts (a section, a call...), in order."
  (let ((pos (point-min)) starts)
    (while (< pos (point-max))
      (let ((a (get-text-property pos 'harness-ui-access-anchor)))
        (when (and (consp a) (eq (car a) kind)
                   (or (= pos (point-min))
                       (not (equal a (get-text-property (1- pos) 'harness-ui-access-anchor)))))
          (push pos starts)))
      (setq pos (or (next-single-property-change pos 'harness-ui-access-anchor) (point-max))))
    (nreverse starts)))

(defun harness-ui-access--move-to (kind n)
  "Move point to the start of the Nth next text anchored as KIND, back when N < 0."
  (let* ((starts (harness-ui-access--starts kind))
         (target (if (> n 0)
                     (nth (1- n) (cl-remove-if-not (lambda (p) (> p (point))) starts))
                   (nth (1- (- n)) (nreverse (cl-remove-if-not (lambda (p) (< p (point))) starts))))))
    (if target
        (goto-char target)
      (message "No more"))))

(defun harness-ui-access-next-call (n)
  "Move to the Nth next judged call."
  (interactive "p")
  (harness-ui-access--move-to 'call n))

(defun harness-ui-access-previous-call (n)
  "Move to the Nth previous judged call."
  (interactive "p")
  (harness-ui-access--move-to 'call (- n)))

(defun harness-ui-access-next-section (n)
  "Move to the Nth next section."
  (interactive "p")
  (harness-ui-access--move-to 'section n))

(defun harness-ui-access-previous-section (n)
  "Move to the Nth previous section."
  (interactive "p")
  (harness-ui-access--move-to 'section (- n)))

;;;;; The judgements' filter

(defun harness-ui-access--set-filter (key value)
  "Set KEY of the judgements' filter to VALUE, nil for any, and fetch again."
  (setq harness-ui-access--filter
        (let ((f (harness-plist-remove harness-ui-access--filter key)))
          (if (and (stringp value) (not (string-empty-p value))) (append f (list key value)) f)))
  (harness-ui-access-refresh))

(defun harness-ui-access-filter-behavior (behavior)
  "Show the judgements that decided BEHAVIOR: allow, deny, ask, asked; nil for all."
  (interactive
   (let* ((table '(("all" . nil) ("denied" . "deny") ("asked you" . "asked") ("allowed" . "allow")
                   ("waiting for you" . "ask")))
          (choice (completing-read "Show: " table nil t)))
     (list (cdr (assoc choice table)))))
  (harness-ui-access--set-filter :behavior behavior))

(defun harness-ui-access-filter-by (by)
  "Show the judgements BY decided, a name such as user or rule; nil for all."
  (interactive
   (let* ((known (mapcar #'harness-ui-access--str (plist-get harness-ui-access--judgements :by)))
          (table (cons '("anyone" . nil)
                       (mapcar (lambda (b) (cons (format "%s (%s)" (harness-ui-access--by-label b) b) b))
                               (delete-dups (append known (mapcar #'car harness-ui-access--by-labels))))))
          (choice (completing-read "Decided by: " table nil t)))
     (list (cdr (assoc choice table)))))
  (harness-ui-access--set-filter :by by))

(defun harness-ui-access-filter-tool (tool)
  "Show the judgements of calls of TOOL; empty for all."
  (interactive
   (list (completing-read "Tool (empty for any): "
                          (mapcar #'harness-ui-access--str (plist-get harness-ui-access--judgements :tools)))))
  (harness-ui-access--set-filter :tool tool))

(defun harness-ui-access-filter-text (text)
  "Show the judgements whose tool, reason, handle or call title has TEXT."
  (interactive (list (read-string "Text (empty for any): " (plist-get harness-ui-access--filter :query))))
  (harness-ui-access--set-filter :query text))

(defun harness-ui-access-filter-clear ()
  "Show every judgement."
  (interactive)
  (setq harness-ui-access--filter nil)
  (harness-ui-access-refresh))

;;;; The mode

(defvar harness-ui-access-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-access-refresh)
    (define-key map (kbd "TAB") #'harness-ui-access-toggle)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "RET") #'harness-ui-access-visit)
    (define-key map (kbd "n") #'harness-ui-access-next-call)
    (define-key map (kbd "p") #'harness-ui-access-previous-call)
    (define-key map (kbd "M-n") #'harness-ui-access-next-section)
    (define-key map (kbd "M-p") #'harness-ui-access-previous-section)
    (define-key map (kbd "f") #'harness-ui-access-filter-behavior)
    (define-key map (kbd "b") #'harness-ui-access-filter-by)
    (define-key map (kbd "t") #'harness-ui-access-filter-tool)
    (define-key map (kbd "s") #'harness-ui-access-filter-text)
    (define-key map (kbd "c") #'harness-ui-access-filter-clear)
    (define-key map (kbd "a") #'harness-ui-access-allow-dir)
    (define-key map (kbd "r") #'harness-ui-access-allow-read-dir)
    (define-key map (kbd "k") #'harness-ui-access-take-away)
    (define-key map (kbd "R") #'harness-ui-access-restore-at-point)
    (define-key map (kbd "m") #'harness-ui-access-move)
    (define-key map (kbd "M") #'harness-ui-access-set-mode)
    (define-key map (kbd "i") #'harness-ui-access-toggle-interaction)
    (define-key map (kbd "N") #'harness-ui-access-toggle-network)
    (define-key map (kbd "w") #'harness-ui-access-toggle-writing)
    (define-key map (kbd "T") #'harness-ui-access-toggle-tool)
    (define-key map (kbd "C") #'harness-ui-access-toggle-capability)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-access-mode'.")

(define-derived-mode harness-ui-access-mode special-mode "Access"
  "Major mode of a session's access view (`harness-access').
It lists the session's sandbox, permission mode, network, writing, the
Linux capabilities of its commands, directories, tools, rules, the
requests it waits on and the judgements of its calls, and changes them.

\\{harness-ui-access-mode-map}"
  (setq truncate-lines t)
  (setq header-line-format '(:eval (harness-ui-access--header)))
  (add-hook 'window-buffer-change-functions #'harness-ui-access--shown nil t))

;; The view's keys in the harness menu, behind `.'.
(put 'harness-ui-access-mode 'harness-menu-group
     '("Access"
       ["Jail"
        (". M" "Permission mode" harness-ui-access-set-mode)
        (". i" "Interactive or not" harness-ui-access-toggle-interaction)
        (". N" "Network on or off" harness-ui-access-toggle-network)
        (". w" "Writing on or off" harness-ui-access-toggle-writing)
        (". T" "A tool on or off" harness-ui-access-toggle-tool)
        (". C" "Capability give or take away" harness-ui-access-toggle-capability)]
       ["Directories"
        (". a" "Allow a directory" harness-ui-access-allow-dir)
        (". r" "Allow reading a directory" harness-ui-access-allow-read-dir)
        (". k" "Take away at point" harness-ui-access-take-away)
        (". R" "Restore at point" harness-ui-access-restore-at-point)
        (". m" "Move the session" harness-ui-access-move)]
       ["Judgements"
        (". f" "Show allowed, denied…" harness-ui-access-filter-behavior)
        (". b" "Decided by" harness-ui-access-filter-by)
        (". t" "Tool" harness-ui-access-filter-tool)
        (". s" "Text" harness-ui-access-filter-text)
        (". c" "Clear the filter" harness-ui-access-filter-clear)
        (". g" "Reload" harness-ui-access-refresh)]))

;;;; Following the session

(defconst harness-ui-access--session-events
  '("access/changed" "access/judged" "session/moved" "session/pending-changed" "session/ext-changed")
  "Events about one session, its id first, that change what its view shows.")

(defconst harness-ui-access--global-events
  '("permission/dir-allowed" "permission/dir-revoked" "config/changed" "decision/changed")
  "Events that may change what every view shows: a grant may be for every session.")

(defun harness-ui-access--on-event (event args)
  "Fetch the views EVENT, with ARGS, changes.
A view whose session was deleted says so, and fetches nothing more."
  (cond
   ((equal event "session/deleted")
    (dolist (buffer (harness-ui-access--buffers (car args)))
      (with-current-buffer buffer
        (setq harness-ui-access--deleted t)
        (harness-ui-access--render))))
   ((member event harness-ui-access--session-events)
    (mapc #'harness-ui-access--schedule (harness-ui-access--buffers (car args))))
   ((member event harness-ui-access--global-events)
    (mapc #'harness-ui-access--schedule (harness-ui-access--buffers)))))

(defun harness-ui-access--on-update (session-id update)
  "Fetch the view of SESSION-ID again when UPDATE changes what it shows.
A node changed (a denied call approved), a call finished, the mode or
the session changed."
  (when (member (plist-get update :sessionUpdate)
                '("_harness/node" "tool_call_update" "current_mode_update" "_harness/session"))
    (mapc #'harness-ui-access--schedule (harness-ui-access--buffers session-id))))

(defun harness-ui-access--on-pending (session-id)
  "Draw the view of SESSION-ID again: the requests it waits on changed."
  (mapc #'harness-ui-access--schedule (harness-ui-access--buffers session-id)))

(defun harness-ui-access--init ()
  "Wire the access views into the UI, and bind j and d in `harness-ui-map'."
  (add-hook 'harness-ui-event-functions #'harness-ui-access--on-event)
  (add-hook 'harness-ui-update-functions #'harness-ui-access--on-update)
  (add-hook 'harness-ui-pending-changed-hook #'harness-ui-access--on-pending)
  (define-key harness-ui-map (kbd "j") #'harness-access)
  (define-key harness-ui-map (kbd "d") #'harness-directories))

(defun harness-ui-access--shutdown ()
  "Unwire the access views."
  (remove-hook 'harness-ui-event-functions #'harness-ui-access--on-event)
  (remove-hook 'harness-ui-update-functions #'harness-ui-access--on-update)
  (remove-hook 'harness-ui-pending-changed-hook #'harness-ui-access--on-pending))

(harness-define-module 'ui-access
  :doc "The access view of a session: its sandbox, mode, directories, tools and rules, the requests it waits on and the judgements of its calls, each drawn as the chat draws it."
  :requires '(ui ui-chat ui-pending)
  :init #'harness-ui-access--init
  :shutdown #'harness-ui-access--shutdown)

(provide 'harness-ui-access)
;;; harness-ui-access.el ends here
