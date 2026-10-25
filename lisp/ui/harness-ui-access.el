;;; harness-ui-access.el --- The jail and permissions view: what a session may reach, and how its calls were judged  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-access' (C-c h j) says what a session may reach, in one
;; place, and changes it.  Clicking the permission mode in a chat's
;; header line (Ask, Accept Edits, Auto, YOLO) opens it too.  It is
;; four pages, a buffer each, that share a strip under the title --
;; Overview, Tools, Rules, Judgements, also the keys 1 to 4 -- so the
;; first page holds what most visits are for and the long lists are a
;; click away rather than all on one screen:
;;
;; - Overview.  Settings lead it, in one group, each a choice with the
;;   one in effect marked, a click on another changing it: the
;;   permission mode, whether the session is interactive, the network
;;   and writing; then the Linux capabilities of its commands
;;   (the sandbox drops every one, and you give it some (`C'), by name,
;;   or take them away; why none can be given when none can is said
;;   there) and the sandbox its commands run in -- the backend, the ones
;;   this machine has, the policy, whether commands in its directory are
;;   confined.  Directories are those it may write, those it may only
;;   read and those it gave up, each with where it comes from and what
;;   can be done with it: give it up or keep it for reading only, revoke
;;   a grant, restore one given up; new ones are allowed, for writing or
;;   for reading only, and the session moves to another working
;;   directory (`harness-directories', C-c h d, opens the page here).
;;   Details end it: a line each for the tools, the rules and the
;;   judgements, with what they hold, each a link to its page.
;; - Tools: those the session is offered, those it is not and why,
;;   and those that belong to other kinds of session.  A tool is turned
;;   off for the session, and on again, here.
;; - Rules: the permission rules that apply to it, and the tools exempt
;;   from prompts; a lasting answer is taken back here.
;; - Judgements: every call of it the permission chain judged, newest
;;   first: what was decided, who decided it (you, a rule, the mode, the
;;   auto-mode judge, the jail, its access settings, a module's gate),
;;   why, and the call's handle, the id `rerun_approved' runs a denied
;;   call by once you approve it.  Each call is drawn by the chat itself
;;   (`harness-chat-insert-tool-call'), [Approve] and all, so it reads as
;;   it does in the conversation.  The list is filtered by what was
;;   decided, by who decided, by tool and by text.  A call that waits
;;   for an answer is listed as waiting; the answer is the session's
;;   chat's, where the request is, not this view's.
;;
;; What you change here takes effect at once, and the session's
;; transcript says so.  The agent cannot change any of it this way: it
;; asks you for more with request_escalation, and gives some up with
;; drop_access (harness-access.el).  Every page follows the session:
;; grants, judgements and changes to its access redraw it, a page no
;; window shows when it is shown again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-chat)
;; The radio icons a choice is drawn with (`harness-icon-radio-on').
(require 'harness-ui-pending)

(declare-function harness-decision-undo "harness-ui-decisions")

(defgroup harness-ui-access nil
  "The jail and permissions view of a session."
  :group 'harness-ui)

(defface harness-ui-access-heading-face
  '((t :inherit harness-label-face :height 1.1))
  "Headings of the access view's sections."
  :group 'harness-ui-access)

(defface harness-ui-access-page-face '((t :inherit (bold highlight)))
  "The page of the access view that is shown, in the strip that names the pages."
  :group 'harness-ui-access)

(defface harness-ui-access-choice-face '((t :inherit button :underline nil))
  "A choice of a setting that is not the one in effect: a click takes it.
Not underlined, which would hide the words next to the ring."
  :group 'harness-ui-access)

(defface harness-ui-access-allowed-face '((t :inherit harness-success-face))
  "What the access view says of what is allowed."
  :group 'harness-ui-access)

(defface harness-ui-access-denied-face '((t :inherit harness-failure-face))
  "What the access view says of what is denied, off or given up."
  :group 'harness-ui-access)

(defface harness-ui-access-waiting-face '((t :inherit harness-caution-face))
  "What the access view says of a call waiting for an answer."
  :group 'harness-ui-access)

(defface harness-ui-access-tool-face '((t :inherit button :underline nil))
  "The names of the tools a session is offered, each a button turning it off.
Not underlined, which would hide the underscores of the names."
  :group 'harness-ui-access)

(defcustom harness-ui-access-judgements-limit 100
  "How many judgements the access view's Judgements page lists, the newest first."
  :type 'integer :group 'harness-ui-access)

(defconst harness-ui-access--pages
  '((overview "Overview" "Settings and directories of the session")
    (tools "Tools" "Tools offered to the session, and those withheld")
    (rules "Rules" "Permission rules of the session")
    (judgements "Judgements" "Judged calls of the session"))
  "The pages of the access view, as (PAGE TITLE DESCRIPTION).
They are in the order the strip names them.  A page is a buffer of its
own (`harness-ui-access--buffer'); the keys 1 to 4 show them in this
order.")

(defconst harness-ui-access--refresh-delay 0.3
  "Seconds the view waits after a change before it fetches again.
Changes come in bursts -- a turn's calls, a grant and its event -- which
one fetch covers.")

;;;; Buffer state

(defvar-local harness-ui-access--page 'overview
  "The page this buffer shows: one of `harness-ui-access--pages'.")

(defvar-local harness-ui-access--describe nil
  "What `access/describe' said last of this buffer's session.")

(defvar-local harness-ui-access--judgements nil
  "What `access/judgements' said last, for the buffer's filter.
The Overview page asks for the counts only, the newest judgement beside them.")

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
  "The section to put point at once the buffer is drawn, a symbol, or nil.
A section of the Overview page: `settings', `directories' or `details'.")

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

(defun harness-ui-access--page-title (page)
  "Return the title of PAGE, one of `harness-ui-access--pages'."
  (or (nth 1 (assq page harness-ui-access--pages)) (capitalize (format "%s" page))))

(defun harness-ui-access--buffer-name (sid &optional page)
  "Return the name of the view of session SID's PAGE, the Overview by default.
The Overview is `*harness access: NAME*', the others `*harness access
tools: NAME*' and the like."
  (format "*harness access%s: %s*"
          (if (memq page '(nil overview)) "" (concat " " (downcase (harness-ui-access--page-title page))))
          (if-let* ((session (harness-ui-session sid)))
              (or (let ((name (plist-get session :name))) (and (stringp name) (not (string-empty-p name)) name))
                  (substring sid 0 (min 8 (length sid))))
            (substring sid 0 (min 8 (length sid))))))

(defun harness-ui-access--buffers (&optional sid page)
  "Return the live access views, of session SID only when it is given.
Every page of it, unless PAGE names one."
  (cl-remove-if-not (lambda (buffer)
                      (with-current-buffer buffer
                        (and (derived-mode-p 'harness-ui-access-mode)
                             (or (null sid) (equal harness-ui-session-id sid))
                             (or (null page) (eq page harness-ui-access--page)))))
                    (buffer-list)))

(defun harness-ui-access--buffer (sid &optional page)
  "Return the view of session SID's PAGE, made when there is none.
PAGE is one of `harness-ui-access--pages', the Overview by default."
  (let ((page (or page 'overview)))
    (or (car (harness-ui-access--buffers sid page))
        (let ((buffer (generate-new-buffer (harness-ui-access--buffer-name sid page))))
          (with-current-buffer buffer
            (harness-ui-access-mode)
            (setq harness-ui-access--page page)
            (harness-chat-tool-view-setup sid))
          buffer))))

;;;###autoload
(defun harness-access (&optional session-id section)
  "Show what SESSION-ID may reach, and how its calls were judged.
Interactively the current buffer's session, or one you choose.  The
view's first page, the Overview, holds the session's settings -- its
permission mode, whether it asks you, the network, writing, the Linux
capabilities of its commands and its sandbox -- and its directories, and
a line each for its tools, rules and judgements, which have pages of
their own.  SECTION, a symbol, names what to show: `tools', `rules' or
`judgements' open that page; `settings' (also `jail') and `directories'
put point at that section of the Overview.  Return the buffer."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (page (if (memq section '(tools rules judgements)) section 'overview))
         (buffer (harness-ui-access--buffer sid page)))
    (with-current-buffer buffer
      (setq harness-ui-access--goto (and (eq page 'overview) (if (eq section 'jail) 'settings section)))
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
      (harness-ui-view-drawn)
      (if harness-ui-access--deleted
          (harness-ui-access--render)
        (harness-ui-access--fetch buffer)))))

(defun harness-ui-access--fetch (buffer)
  "Fetch what BUFFER's page draws of its session's access, and draw it.
Every page asks for the description (`access/describe').  The Overview
and the Judgements pages also ask for the judgements -- the Overview
for their counts only, the newest one beside them.  The Tools and Rules
pages draw none, and ask for none."
  (with-current-buffer buffer
    (let* ((sid harness-ui-session-id)
           (page harness-ui-access--page)
           (judged (and (memq page '(overview judgements)) t))
           (limit (if (eq page 'judgements) harness-ui-access-judgements-limit 1))
           (generation (cl-incf harness-ui-access--generation))
           (describe nil) (judgements nil) (left (if judged 2 1)) (failure nil)
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
                               harness-ui-access--judgements judgements))
                       (harness-ui-access--render)))))
           (failed (lambda (e)
                     (unless (harness-ui-connection-replaced-p e)
                       (setq failure (harness-error-message e)))
                     (funcall done)
                     nil)))
      (harness-ui-call "_harness/access/describe" (list :session-id sid)
                       (lambda (d) (setq describe d) (funcall done))
                       failed)
      (when judged
        (harness-ui-call "_harness/access/judgements"
                         (append (list :session-id sid :limit limit)
                                 (and (eq page 'judgements) (harness-ui-access--filter-params)))
                         (lambda (j) (setq judgements j) (funcall done))
                         failed)))))

(defun harness-ui-access--schedule (buffer)
  "Fetch BUFFER again soon, or once a window shows it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (not (harness-ui-view-follow-p buffer))
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
    ;; The catch-up is on its way: the mark of a suspended view is not due.
    (harness-ui-view-drawn)
    (harness-ui-access--schedule (current-buffer))))

;;;; Drawing: helpers

(defun harness-ui-access--heading (title section &optional note)
  "Insert the heading TITLE of SECTION, a symbol, with NOTE after it.
A NOTE too long for the line goes under the heading, wrapped."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (propertize title 'face 'harness-ui-access-heading-face))
    (cond ((null note) (insert "\n"))
          ((<= (+ (string-width title) 2 (string-width note)) (harness-ui-access--width))
           (insert "  " (propertize note 'face 'harness-dim-face) "\n"))
          (t (insert "\n")
             (harness-ui-access--insert-note note "  ")))
    (put-text-property start (point) 'harness-ui-access-anchor (cons 'section section))))

(defun harness-ui-access--run (action)
  "Run ACTION, a button's, as the button's click does.
ACTION is a function of no arguments, or a command, a symbol: a command
runs as its key runs it (`call-interactively'), reading what it needs
-- the directory to allow, the filter's text -- from its `interactive'
form.  A click gives a button's action no arguments
\(`harness-ui-action-push'), so a command called as a plain function
signalled `wrong-number-of-arguments'."
  (if (and (symbolp action) (commandp action))
      (call-interactively action)
    (funcall action)))

(defun harness-ui-access--button (label action help &optional face)
  "Return a button LABEL running ACTION with HELP.
ACTION is a function of no arguments, or a command (a symbol), which
runs as its key does and asks for what it needs (`harness-ui-access--run').
FACE is the button's face, `button' when nil."
  (harness-ui-action-button label (lambda () (harness-ui-access--run action))
                            :help help :face face))

(defun harness-ui-access--pad (text width)
  "Return TEXT padded with spaces to WIDTH columns, or cut to it."
  (let ((text (or text "")))
    (if (> (string-width text) width)
        (concat (truncate-string-to-width text (max 1 (1- width))) "…")
      (concat text (make-string (- width (string-width text)) ?\s)))))

(defconst harness-ui-access--label-width 18
  "Columns the labels of the settings and the details take, left of what they hold.")

(defun harness-ui-access--indent ()
  "Return the white space that lines a note up under what a row holds."
  (make-string (+ 2 harness-ui-access--label-width) ?\s))

(defun harness-ui-access--choice (label selected action help)
  "Return the choice LABEL of a setting, drawn as a radio button.
SELECTED marks the one in effect: a ring with a dot in it, its label
bold.  The others are rings, their labels a button's colour, and a click
on one runs ACTION, a function of no arguments, with HELP as its
tooltip.  Without an ACTION -- the policy or another module decides the
setting -- the choice is dim and nothing happens on a click."
  (let ((text (concat (harness-ui-icon (if selected 'harness-icon-radio-on 'harness-icon-radio-off)) " " label)))
    (cond (selected (propertize text 'face 'bold 'help-echo help))
          (action (harness-ui-access--button text action help 'harness-ui-access-choice-face))
          (t (propertize text 'face 'harness-dim-face 'help-echo help)))))

(defun harness-ui-access--setting (name label control &optional note separator)
  "Insert the row of setting NAME, a symbol.
It reads LABEL, then CONTROL, and NOTE under it.  CONTROL is a list of
strings, the setting's choices or its value and buttons, SEPARATOR
apart (three spaces by default) and wrapped under each other when the
window is too narrow for them; a string is a list of one.  NOTE, when
given, is what to know of what is in effect, dim, wrapped to the view's
width.  The row carries NAME as its anchor, so point stays on it when
the view is drawn again after a click."
  (let ((start (point)))
    (insert "  " (propertize (harness-ui-access--pad label harness-ui-access--label-width) 'face 'harness-dim-face))
    (harness-ui-access--wrap (if (listp control) control (list control))
                             (harness-ui-access--width) (harness-ui-access--indent) (or separator "   "))
    (when note (harness-ui-access--insert-note note))
    (put-text-property start (point) 'harness-ui-access-anchor (cons 'setting name))))

(defun harness-ui-access--choices (&rest choices)
  "Return CHOICES, strings made by `harness-ui-access--choice', as a list."
  (delq nil choices))

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
Each line after the first starts with INDENT.  No line ends in a
separator, and the text ends in a newline.  An item that ends in a comma
is followed by a space, whatever SEPARATOR is."
  (let* ((indent (or indent ""))
         (separator (or separator "  "))
         (column (current-column))
         (previous nil))
    (dolist (item items)
      (let ((w (string-width item))
            (sep (if (and previous (string-suffix-p "," previous)) " " separator)))
        (cond ((<= column (string-width indent)))
              ((> (+ column (string-width sep) w) width)
               (insert "\n" indent)
               (setq column (string-width indent)))
              (t (insert sep)
                 (setq column (+ column (string-width sep)))))
        (insert item)
        (setq column (+ column w)
              previous item)))
    (insert "\n")))

(defun harness-ui-access--width ()
  "Return the width the view lays its rows out for.
That is the window's, less the margin, in columns, at least 40: a
narrower window cuts what it cannot show, as it does for any view."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 40 (- (if window (window-body-width window) 100) 2))))

;;;; Drawing: the session and its jail

(defun harness-ui-access--insert-title (d)
  "Insert the title of the page of the session `access/describe' described as D.
It names the session, a link to its chat, where it works and what
kind it is, and ends with the strip of the pages."
  (let* ((s (plist-get d :session))
         (sid (plist-get s :id))
         (cached (harness-ui-session sid))
         (name (or (plist-get s :name) (plist-get cached :name)))
         (named (and (stringp name) (not (string-empty-p name)))))
    (insert (propertize "Jail & permissions of " 'face 'bold)
            (harness-ui-session-link sid (if named
                                             (format "«%s»" name)
                                           (format "session %s" (substring sid 0 (min 8 (length sid))))))
            "\n"
            (let ((about (format " · %s%s"
                                 (or (harness-ui-access--str (plist-get s :kind)) "main")
                                 (if (plist-get s :host) (format " · on %s" (plist-get s :host)) ""))))
              (propertize (concat (harness-ui-access--elide-path
                                   (harness-abbreviate-file-name (or (plist-get s :cwd) ""))
                                   (- (harness-ui-access--width) (string-width about)))
                                  about "\n")
                          'face 'harness-dim-face)))
    (when (eq harness-ui-access--page 'overview)
      (harness-ui-access--wrap
       (mapcar (lambda (word) (propertize word 'face 'harness-dim-face))
               '("Immediate effect ·" "agent tools:" "request_escalation (ask for more),"
                 "drop_access (give up)"))
       (harness-ui-access--width) "" " "))
    (insert "\n")
    (harness-ui-access--insert-strip)))

(defun harness-ui-access--insert-strip ()
  "Insert the strip that names the pages: the one shown marked, the others buttons.
Each says what its page holds, and the key that shows it, in its tooltip."
  (let ((i 0) (items nil))
    (dolist (entry harness-ui-access--pages)
      (cl-incf i)
      (let ((page (car entry))
            (help (format "%s (%d)" (nth 2 entry) i)))
        (push (if (eq page harness-ui-access--page)
                  (propertize (nth 1 entry) 'face 'harness-ui-access-page-face 'help-echo help)
                (harness-ui-access--button (nth 1 entry) (lambda () (harness-ui-access-show-page page)) help))
              items)))
    (harness-ui-access--wrap (nreverse items) (harness-ui-access--width) ""
                             (propertize "  ·  " 'face 'harness-dim-face))))

;;;; Drawing: the settings

(defun harness-ui-access--sandbox-state (sandbox)
  "Return what SANDBOX says of the commands, as text.
SANDBOX is the `:sandbox' of `access/describe'."
  (cond ((harness-ui-access--true-p (plist-get sandbox :remote))
         "Remote session · commands on its host, outside the sandbox")
        ((not (harness-ui-access--true-p (plist-get sandbox :module)))
         "No sandbox module · commands unconfined")
        ((harness-ui-access--true-p (plist-get sandbox :confined)) "Commands confined")
        (t "Commands unconfined")))

(defun harness-ui-access--insert-sandbox (d)
  "Insert the sandbox row of the settings of the session described as D.
It names the backend, and says whether commands in the session's
directory run confined, which backends this machine has and the policy."
  (let* ((sandbox (plist-get d :sandbox))
         (backend (or (harness-ui-access--str (plist-get sandbox :backend)) "none"))
         (available (mapcar #'harness-ui-access--str (plist-get sandbox :available)))
         (policy (harness-ui-access--str (plist-get sandbox :policy))))
    (harness-ui-access--setting
     'sandbox "Sandbox"
     (propertize backend 'face (if (equal backend "none") 'harness-ui-access-denied-face 'bold))
     (string-join (delq nil (list (harness-ui-access--sandbox-state sandbox)
                                  (and available (format "Available: %s" (string-join available ", ")))
                                  (and policy (format "Policy: %s" policy))))
                  " · "))))

(defun harness-ui-access--insert-mode (d)
  "Insert the permission mode row of the settings of the session described as D.
Every mode is a choice, the one in effect marked, and what it means is
said under them; a policy that sets the mode leaves no choice to make."
  (let* ((mode (or (harness-ui-access--str (plist-get d :mode)) "ask"))
         (entry (assoc mode harness-ui-permission-modes))
         (pinned (harness-ui-access--true-p (plist-get d :mode-pinned))))
    (harness-ui-access--setting
     'mode "Permission mode"
     (apply #'harness-ui-access--choices
            ;; A mode this view does not know is still the one in effect.
            (append (and (null entry) (list (harness-ui-access--choice mode t nil mode)))
                    (mapcar (lambda (m)
                              (harness-ui-access--choice
                               (nth 1 m) (equal (car m) mode)
                               (unless pinned (lambda () (harness-ui-access-choose-mode (car m))))
                               (format "%s: %s (%s)" (nth 1 m) (nth 2 m)
                                       (cond (pinned "set by the policy")
                                             ((equal (car m) mode) "in effect")
                                             (t "click to choose it")))))
                            harness-ui-permission-modes)))
     (concat (or (nth 2 entry) "")
             (if pinned (concat (and entry " · ") "set by the policy") "")))))

(defun harness-ui-access--insert-interaction (d)
  "Insert the interaction row of the settings of the session described as D.
Interactive, you are asked what the mode leaves open; non-interactive,
nobody is asked and the auto-mode judge decides."
  (let ((away (harness-ui-access--true-p (plist-get d :non-interactive)))
        (pinned (harness-ui-access--true-p (plist-get d :non-interactive-pinned))))
    (harness-ui-access--setting
     'interaction "Interaction"
     (harness-ui-access--choices
      (harness-ui-access--choice "Interactive" (not away)
                                 (unless pinned (lambda () (harness-ui-access-set-interaction nil)))
                                 "Ask you about undecided calls (i)")
      (harness-ui-access--choice "Non-interactive" away
                                 (unless pinned (lambda () (harness-ui-access-set-interaction t)))
                                 "Stop prompting, use the auto-mode judge (i)"))
     (concat (if away "No prompts · decisions by the auto-mode judge" "Prompts for undecided calls")
             (if pinned " · set by the policy" "")))))

(defun harness-ui-access--insert-network (d)
  "Insert the network row of the settings of the session described as D."
  (let ((network (harness-ui-access--true-p (plist-get d :network))))
    (harness-ui-access--setting
     'network "Network"
     (harness-ui-access--choices
      (harness-ui-access--choice "On" network (lambda () (harness-ui-access-set-network t))
                                 "Allow the network (N)")
      (harness-ui-access--choice "Off" (not network) (lambda () (harness-ui-access-set-network nil))
                                 "Block the network (N)"))
     (unless network "No web tools or ssh · bash and elisp offline"))))

(defun harness-ui-access--insert-writing (d)
  "Insert the writing row of the settings of the session described as D.
A session read-only by another module's policy has no choice to make."
  (let* ((read-only (harness-ui-access--true-p (plist-get d :read-only)))
         (own (harness-ui-access--true-p (plist-get d :read-only-profile)))
         (other (harness-ui-access--str (plist-get d :read-only-by)))
         (fixed (and read-only (not own))))
    (harness-ui-access--setting
     'writing "Writing"
     (harness-ui-access--choices
      (harness-ui-access--choice "On" (not read-only)
                                 (unless fixed (lambda () (harness-ui-access-set-read-only nil)))
                                 "Allow writing, where the directories allow (w)")
      (harness-ui-access--choice "Read-only" read-only
                                 (unless fixed (lambda () (harness-ui-access-set-read-only t)))
                                 "Block writing (w)"))
     (cond (fixed (format "Read-only by %s" (or other "a module")))
           (own "Reading tools only · bash read-only and offline")))))

(defun harness-ui-access--insert-settings (d)
  "Insert the settings of the session described as D, in one group.
The options that are changed most come first -- the permission mode,
whether you are asked, the network, writing -- then the Linux
capabilities of the commands and the sandbox they run in."
  (harness-ui-access--heading "Settings" 'settings)
  (harness-ui-access--insert-mode d)
  (harness-ui-access--insert-interaction d)
  (harness-ui-access--insert-network d)
  (harness-ui-access--insert-writing d)
  (harness-ui-access--insert-capabilities d)
  (harness-ui-access--insert-sandbox d)
  (when (harness-ui-access--true-p (plist-get d :corporate))
    (harness-ui-access--setting 'corporate "Corporate mode"
                                (propertize "on: no tools of kind net but web search, no ssh"
                                            'face 'harness-dim-face))))

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
      (user-error "No capability data from this harness")))

(defun harness-ui-access--capabilities-held (capabilities)
  "Return the names of the capabilities CAPABILITIES says the commands hold."
  (harness-ui-access--capability-names (plist-get capabilities :held)))

(defun harness-ui-access--capabilities-offer (capabilities)
  "Return the capabilities CAPABILITIES lets an agent ask for and does not hold."
  (let ((held (harness-ui-access--capabilities-held capabilities)))
    (seq-remove (lambda (name) (member name held))
                (harness-ui-access--capability-names (plist-get capabilities :grantable)))))

(defun harness-ui-access--insert-note (text &optional indent)
  "Insert TEXT, dim, under what a row holds, wrapped to the view's width.
INDENT is the white space to start each line with, `harness-ui-access--indent'
by default: the column a row's value starts at."
  (let ((indent (or indent (harness-ui-access--indent)))
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
      "Held, not passed · read-only session")
     ((and held (not enforced))
      (format "Held, not passed: %s" (or why "no enforcement by the sandbox")))
     ((and held unlisted)
      (format "%s held, not passed: no longer offered to agents" (string-join unlisted ", ")))
     (held
      "Passed to bash and elisp commands · inside the sandbox only")
     (why (format "Unavailable: %s" why)))))

(defun harness-ui-access--insert-capabilities (d)
  "Insert the capabilities row of the settings of the session described as D.
The sandbox drops every Linux capability of the commands it runs; this
row says which the user gave the session's commands, and has buttons to
give one and take them away.  Nothing is drawn when D has no
`:capabilities': a harness that does not say cannot be asked."
  (when-let* ((c (plist-get d :capabilities))
              ((consp c)))
    (let* ((held (harness-ui-access--capabilities-held c))
           (offer (harness-ui-access--capabilities-offer c))
           (why (harness-ui-access--str (plist-get c :why)))
           (buttons (delq nil
                          (list
                           (and offer (not why)
                                (harness-ui-access--button
                                 "[Give…]" #'harness-ui-access-grant-capability
                                 "Give the session's commands a Linux capability, inside the sandbox only (C)"))
                           (and held
                                (harness-ui-access--button
                                 "[Take away…]" #'harness-ui-access-revoke-capability
                                 "Take one capability away from the session's commands (C)"))
                           (and held
                                (harness-ui-access--button
                                 "[Take all away]" (lambda () (harness-ui-access-set-capability "all" nil))
                                 "Take every capability away from the session's commands (C, all)")))))
           (note (string-join (delq nil (list (and (null held) "All capabilities dropped")
                                              (harness-ui-access--capabilities-note d held)))
                              " · ")))
      (harness-ui-access--setting
       'capabilities "Capabilities"
       (append (if held
                   (cl-loop for (name . more) on held
                            collect (propertize (if more (concat name ",") name) 'face 'bold))
                 (list (propertize "none" 'face 'bold)))
               buttons)
       (and (not (string-empty-p note)) note)
       "  "))))

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

(defun harness-ui-access--elide-path (path width)
  "Return PATH cut to WIDTH columns, in the middle, with more of its end kept.
The end of a path says most -- the directory's own name -- and its start
only where it lies: a third of what is kept is the start."
  (if (<= (string-width path) width)
      path
    (let* ((keep (max 2 (1- width)))
           (head (max 1 (/ keep 3)))
           (tail (- keep head)))
      (concat (substring path 0 head) "…" (substring path (max head (- (length path) tail)))))))

(defun harness-ui-access--insert-dirs (d)
  "Insert the directories section of the session described as D.
A row is the directory with the sign of what may be done in it, where
it comes from and the buttons that change it.  The path is cut, in the
middle of its column, so that the row and its buttons fit the window;
where even that leaves too little of the path, the source and the
buttons go on a line of their own under it."
  (let* ((sid (plist-get (plist-get d :session) :id))
         (dirs (plist-get d :dirs))
         (avail (harness-ui-access--width))
         (rows (mapcar (lambda (e) (cons e (harness-ui-access--dir-buttons sid e))) dirs))
         (buttons-width (apply #'max 0 (mapcar (lambda (row)
                                                 (if (cdr row) (+ 2 (string-width (string-join (cdr row) " "))) 0))
                                               rows)))
         (longest (apply #'max 0 (mapcar (lambda (e) (string-width (harness-abbreviate-file-name (plist-get e :dir))))
                                         dirs)))
         (source-width (apply #'max 0 (mapcar (lambda (e) (string-width (harness-ui-access--source-label e))) dirs)))
         ;; What is left for the path once the tag and its margins, the
         ;; source and the buttons have their columns.
         (room (- avail 8 source-width buttons-width))
         (stacked (< room 24))
         (width (if stacked
                    (max 20 (min 60 longest (- avail 6)))
                  (max 20 (min 60 longest room)))))
    (harness-ui-access--heading "Directories" 'directories
                                "rw writable · ro read-only · -- given up")
    (dolist (row rows)
      (let* ((e (car row))
             (buttons (cdr row))
             (start (point))
             (dropped (harness-ui-access--true-p (plist-get e :dropped)))
             (ro (harness-ui-access--true-p (plist-get e :read-only)))
             (outputs (equal (harness-ui-access--str (plist-get e :source)) "outputs"))
             (tag (cond (dropped (propertize "--" 'face 'harness-ui-access-denied-face))
                        ((or ro outputs) (propertize "ro" 'face 'harness-ui-access-waiting-face))
                        (t (propertize "rw" 'face 'harness-ui-access-allowed-face))))
             (path (propertize (harness-ui-access--elide-path (harness-abbreviate-file-name (plist-get e :dir)) width)
                               'face (if dropped 'harness-dim-face 'default)))
             (source (propertize (harness-ui-access--source-label e) 'face 'harness-dim-face)))
        (if stacked
            (progn (insert "  " tag "  " path "\n      ")
                   (harness-ui-access--wrap (if buttons
                                                (cons (concat source "  " (car buttons)) (cdr buttons))
                                              (list source))
                                            avail "      " " "))
          (insert "  " tag "  " (harness-ui-access--pad path width) "  "
                  ;; No padding where no button follows it.
                  (if buttons (harness-ui-access--pad source source-width) source)
                  (if buttons (concat "  " (string-join buttons " ")) "")
                  "\n"))
        (add-text-properties start (point) (list 'harness-ui-access-anchor (cons 'dir (plist-get e :dir))
                                                 'harness-ui-access-dir e))))
    (insert "\n  ")
    (harness-ui-access--wrap
     (list (harness-ui-access--button "[Allow a directory…]" #'harness-ui-access-allow-dir
                                      "Grant a directory to write; prefix: every session (a)")
           (harness-ui-access--button "[Allow reading a directory…]" #'harness-ui-access-allow-read-dir
                                      "Let the session read a directory, not write it (r)")
           (harness-ui-access--button "[Move the session…]" #'harness-ui-access-move
                                      "Move the session to another working directory (m)"))
     avail "  " " ")
    (let ((inspect (plist-get d :inspect))
          (skills (plist-get d :skills)))
      (when (or inspect skills)
        ;; Each directory with what it is for stays on one line, its path
        ;; cut in the middle where the window is too narrow for it.
        (let* ((entries (append (mapcar (lambda (dir) (cons dir "the harness")) inspect)
                                (mapcar (lambda (dir) (cons dir "skills")) skills)))
               (items (cl-loop for ((dir . what) . more) on entries
                               collect (propertize
                                        (format "%s (%s)%s"
                                                (harness-ui-access--elide-path
                                                 (harness-abbreviate-file-name dir)
                                                 (max 20 (- avail 4 (string-width what) 4)))
                                                what (if more "," ""))
                                        'face 'harness-dim-face))))
          (insert "  ")
          (harness-ui-access--wrap (cons (propertize "Also readable:" 'face 'harness-dim-face) items)
                                   avail "  " " "))))))

;;;; Drawing: tools and rules

(defun harness-ui-access--tools-split (d)
  "Return the tools of the session described as D, as (ON OFF ELSEWHERE BUILTIN).
ON are the names it is offered, OFF the entries of the tools somebody or
something turned off for it, ELSEWHERE the entries of those that belong
to other kinds of session (a task's hand_in, a supervisor's plan
tools): nobody turned them off, so they are only named.  BUILTIN are the
names its provider runs itself."
  (let* ((tools (plist-get d :tools))
         (all-off (plist-get tools :off))
         (elsewhere (seq-filter (lambda (e) (harness-ui-access--true-p (plist-get e :elsewhere))) all-off)))
    (list (plist-get tools :on)
          (seq-remove (lambda (e) (memq e elsewhere)) all-off)
          elsewhere
          (plist-get tools :builtin))))

(defun harness-ui-access--tool-groups (off)
  "Return the tools OFF, entries of `access/describe', grouped by why.
A list of (WHY . ENTRIES), in the order each reason is first met."
  (let (groups)
    (dolist (e off)
      (let* ((why (or (plist-get e :why) "off"))
             (cell (assoc why groups)))
        (if cell
            (setcdr cell (append (cdr cell) (list e)))
          (setq groups (append groups (list (list why e)))))))
    groups))

(defun harness-ui-access--tools-summary (d &optional reasons)
  "Return how many tools the session described as D is offered, and not.
With REASONS, the tools that are off are counted by why."
  (pcase-let ((`(,on ,off ,elsewhere) (harness-ui-access--tools-split d)))
    (concat (format "%d offered" (length on))
            (format " · %d off" (length off))
            (if (and reasons off)
                (let ((groups (harness-ui-access--tool-groups off)))
                  ;; One reason says it all; with several, how many for each.
                  (format ": %s" (mapconcat (lambda (g) (if (cdr groups)
                                                            (format "%d %s" (length (cdr g)) (car g))
                                                          (car g)))
                                            groups ", ")))
              "")
            (if elsewhere (format " · %d for other kinds of session" (length elsewhere)) ""))))

(defun harness-ui-access--tool-button (name builtin on)
  "Return the button of tool NAME: a click turns it off when ON, else on.
BUILTIN are the names the session's provider runs itself, marked with a *."
  (harness-ui-access--button
   (if (member name builtin) (concat name "*") name)
   (if on
       (lambda () (when (y-or-n-p (format "Turn %s off for this session? " name))
                    (harness-ui-access-set-tool name nil)))
     (lambda () (harness-ui-access-set-tool name t)))
   (if on
       (format "%s%s: click to turn it off for this session"
               (harness-ui-tool-label name)
               (if (member name builtin) " (run by the session's provider)" ""))
     (format "%s: click to offer it to the session again" (harness-ui-tool-label name)))
   'harness-ui-access-tool-face))

(defun harness-ui-access--insert-tools (d)
  "Insert the Tools page of the session described as D.
The tools it is offered, each a button that turns it off; those it is
not, by why, those turned off for it buttons that turn them on, and
those that belong to other kinds of session."
  (pcase-let* ((`(,on ,off ,elsewhere ,builtin) (harness-ui-access--tools-split d))
               (groups (harness-ui-access--tool-groups off))
               (width (min 32 (max 12 (apply #'max 0 (mapcar (lambda (g) (string-width (car g))) groups))))))
    (harness-ui-access--heading "Tools" 'tools (harness-ui-access--tools-summary d))
    (harness-ui-access--insert-note "Click a tool to turn it off or on for this session" "  ")
    (harness-ui-access--heading "Offered" 'offered (format "%d" (length on)))
    (let ((start (point)))
      (insert "  ")
      (harness-ui-access--wrap (mapcar (lambda (name) (harness-ui-access--tool-button name builtin t)) on)
                               (harness-ui-access--width) "  ")
      (put-text-property start (point) 'harness-ui-access-anchor (cons 'tools-on t)))
    (when builtin
      (insert (propertize "  * run by the session's provider, under the harness's permission\n" 'face 'harness-dim-face)))
    (when off
      (harness-ui-access--heading "Off" 'off (format "%d" (length off)))
      (dolist (group groups)
        (let* ((why (car group))
               (start (point))
               (indent (make-string (+ 4 width) ?\s)))
          (insert "  " (propertize (harness-ui-access--pad why width) 'face 'harness-dim-face) "  ")
          (harness-ui-access--wrap
           (append (mapcar (lambda (e)
                             (let ((name (plist-get e :name)))
                               (if (harness-ui-access--true-p (plist-get e :profile))
                                   (harness-ui-access--tool-button name builtin nil)
                                 (propertize name 'face 'harness-dim-face))))
                           (cdr group))
                   (and (equal why "no network")
                        (list (harness-ui-access--button "[Turn the network on]"
                                                         (lambda () (harness-ui-access-set-network t))
                                                         "Let the session reach the network again (N)"))))
           (harness-ui-access--width) indent)
          (put-text-property start (point) 'harness-ui-access-anchor (cons 'tool why)))))
    (when elsewhere
      (harness-ui-access--heading "For other kinds of session" 'elsewhere (format "%d" (length elsewhere)))
      (insert "  ")
      (harness-ui-access--wrap (mapcar (lambda (e) (propertize (plist-get e :name) 'face 'harness-dim-face)) elsewhere)
                               (harness-ui-access--width) "  "))))

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

(defun harness-ui-access--rules-summary (d)
  "Return how many permission rules apply to the session described as D."
  (let* ((rules (plist-get d :rules))
         (own (length (plist-get rules :session)))
         (always (length (plist-get rules :always)))
         (never (length (plist-get d :never-ask)))
         (parts (delq nil (list (and (> own 0) (format "%d for this session" own))
                                (and (> always 0) (format "%d for every session" always))
                                (and (> never 0) (format "%d %s exempt from prompts" never (if (= never 1) "tool" "tools")))))))
    ;; With no rule of either kind the only part there can be is the tools
    ;; that never ask.
    (string-join (if (and (zerop own) (zerop always))
                     (cons "none (permission mode only)" parts)
                   parts)
                 " · ")))

(defun harness-ui-access--insert-rules (d)
  "Insert the Rules page of the session described as D.
The rules of this session and the lasting ones, in the order the
permission chain tries them, the tools that never ask, and the button
that takes a lasting answer back."
  (let* ((rules (plist-get d :rules))
         (session (plist-get rules :session))
         (always (plist-get rules :always))
         (never-ask (plist-get d :never-ask)))
    (harness-ui-access--heading "Rules" 'rules
                                "first match, after the jail")
    (if (not (or session always))
        (insert (propertize "  No rules · permission mode only\n" 'face 'harness-dim-face))
      (dolist (entry (append (mapcar (lambda (r) (cons "this session" r)) session)
                             (mapcar (lambda (r) (cons "every session" r)) always)))
        ;; A rule too long for the window wraps under itself.
        (insert "  " (propertize (harness-ui-access--pad (car entry) 14) 'face 'harness-dim-face))
        (harness-ui-access--wrap (split-string (harness-ui-access--rule-text (cdr entry)) " " t)
                                 (harness-ui-access--width) (make-string 16 ?\s) " ")))
    (when never-ask
      (harness-ui-access--heading "Exempt from prompts" 'never-ask (format "%d" (length never-ask)))
      (insert "  ")
      (harness-ui-access--wrap (mapcar (lambda (n) (format "%s" n)) never-ask)
                               (harness-ui-access--width) "  " " "))
    (when (fboundp 'harness-decision-undo)
      (insert "\n  " (harness-ui-access--button "[Undo a decision…]" #'harness-decision-undo
                                                "Take back a lasting answer")
              "\n"))))

;;;; Drawing: the details that have pages of their own

(defun harness-ui-access--link (text action help)
  "Return TEXT, drawn already, as a link running ACTION, with HELP.
All of TEXT is the click target.  Unlike a button it keeps the faces TEXT
has, so a row can name its page in one face and say what is on it in another."
  (let ((link (copy-sequence text)))
    (add-text-properties 0 (length link)
                         (list 'mouse-face 'highlight 'follow-link t 'pointer 'hand
                               'help-echo help
                               'harness-ui-action (lambda () (harness-ui-access--run action))
                               'keymap (harness-ui-action-map #'harness-ui-action-push))
                         link)
    link))

(defun harness-ui-access--judgements-summary (j)
  "Return how many calls were judged, and what was decided, from the judgements J.
J is what `access/judgements' said, or nil before it did."
  (let ((total (or (plist-get j :total) 0))
        (counts (plist-get j :counts)))
    (cond ((null j) "loading…")
          ((zerop total) "none yet")
          (t (format "%d %s judged · allowed %d · denied %d · waiting %d" total
                     (if (= total 1) "call" "calls")
                     (or (plist-get counts :allow) 0) (or (plist-get counts :deny) 0)
                     (or (plist-get counts :ask) 0))))))

(defun harness-ui-access--wrap-lines (text width)
  "Return TEXT, words apart, as a list of lines at most WIDTH columns wide.
A word wider than WIDTH has a line of its own."
  (let (lines line)
    (dolist (word (split-string text " " t))
      (if (and line (> (+ (string-width line) 1 (string-width word)) width))
          (progn (push line lines) (setq line word))
        (setq line (if line (concat line " " word) word))))
    (when line (push line lines))
    (nreverse lines)))

(defun harness-ui-access--insert-detail (page summary)
  "Insert the row of PAGE in the details.
The row is a link to the page, named by its title, and says in SUMMARY
what is on it, wrapped under itself in a narrow window."
  (let* ((entry (assq page harness-ui-access--pages))
         (title (nth 1 entry))
         (indent (harness-ui-access--indent))
         (lines (harness-ui-access--wrap-lines summary (- (harness-ui-access--width) (string-width indent))))
         (start (point)))
    (insert "  "
            (harness-ui-access--link
             (concat (propertize title 'face 'button)
                     (make-string (max 0 (- harness-ui-access--label-width (string-width title))) ?\s)
                     (mapconcat (lambda (line) (propertize line 'face 'harness-dim-face))
                                lines (concat "\n" indent)))
             (lambda () (harness-ui-access-show-page page))
             (format "%s (%d)" (nth 2 entry) (1+ (cl-position page (mapcar #'car harness-ui-access--pages)))))
            "\n")
    (put-text-property start (point) 'harness-ui-access-anchor (cons 'detail page))))

(defun harness-ui-access--insert-details (d j)
  "Insert the details of the session described as D.
They are its tools, rules and judgements, each a line that says what is
on its page, and opens it.  J is what `access/judgements' said."
  (harness-ui-access--heading "Details" 'details)
  (harness-ui-access--insert-detail 'tools (harness-ui-access--tools-summary d t))
  (harness-ui-access--insert-detail 'rules (harness-ui-access--rules-summary d))
  (harness-ui-access--insert-detail 'judgements (harness-ui-access--judgements-summary j)))

;;;; Drawing: the judgements

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
  "Return the line above the call of judgement ITEM: what, who, the handle.
A call that waits for an answer says no more than that: its reason
would repeat it."
  (let* ((behavior (harness-ui-access--str (plist-get item :behavior)))
         (by (plist-get item :by))
         (head (pcase behavior
                 ("allow" (propertize "✓ allowed" 'face 'harness-ui-access-allowed-face))
                 ("deny" (propertize "✗ denied" 'face 'harness-ui-access-denied-face))
                 ("ask" (propertize "? waiting" 'face 'harness-ui-access-waiting-face))
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
            (if (and (stringp reason) (not (string-blank-p reason)) (not (equal behavior "ask")))
                (propertize (format "    %s\n" (harness-ui-one-line reason)) 'face 'harness-dim-face)
              ""))))

(defun harness-ui-access--filter-items (j)
  "Return the buttons of the judgements' filter, a list of strings.
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
    (list (funcall choice "All" nil nil)
          (funcall choice "Denied" "deny" (plist-get counts :deny))
          (funcall choice "Asked" "asked" nil)
          (funcall choice "Allowed" "allow" (plist-get counts :allow))
          (funcall choice "Waiting" "ask" (plist-get counts :ask))
          (harness-ui-access--button (format "[decided by: %s]" (if-let* ((by (plist-get harness-ui-access--filter :by)))
                                                                   (harness-ui-access--by-label by) "anyone"))
                                     #'harness-ui-access-filter-by "Show the calls one decider judged (b)")
          (harness-ui-access--button (format "[tool: %s]" (or (plist-get harness-ui-access--filter :tool) "any"))
                                     #'harness-ui-access-filter-tool "Show the calls of one tool (t)")
          (harness-ui-access--button (format "[text: %s]" (or (plist-get harness-ui-access--filter :query) "—"))
                                     #'harness-ui-access-filter-text
                                     "Show the calls with some text in tool, reason, handle or title (s)")
          (and harness-ui-access--filter
               (harness-ui-access--button "[Clear]" #'harness-ui-access-filter-clear "Show every judgement (c)")))))

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
    (insert "  ")
    (harness-ui-access--wrap (delq nil (harness-ui-access--filter-items j)) (harness-ui-access--width) "  " " ")
    (if (null items)
        (insert (propertize (if harness-ui-access--filter "  No matching calls\n" "  No calls judged yet\n")
                            'face 'harness-dim-face))
      (dolist (item items)
        (let ((start (point))
              (call (plist-get item :call)))
          ;; A blank line apart; a call's block ends with one of its own.
          (unless (looking-back "\n\n" (max (point-min) (- (point) 2)))
            (insert "\n"))
          (insert (harness-ui-access--judgement-line item))
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
      (insert (propertize (format "Session %s deleted\n"
                                  (if-let* ((name (plist-get (plist-get d :session) :name)))
                                      (format "«%s»" name)
                                    (substring harness-ui-session-id 0 (min 8 (length harness-ui-session-id)))))
                          'face 'harness-dim-face)))
     (harness-ui-access--error
      (insert (propertize (format "Access unreadable: %s\n" harness-ui-access--error)
                          'face 'harness-failure-face)
              (propertize "Check the access module: M-x harness-describe-modules\n"
                          'face 'harness-hint-face)))
     ((null d) (insert (propertize "Loading…\n" 'face 'harness-dim-face)))
     (t
      (harness-ui-access--insert-title d)
      (pcase harness-ui-access--page
        ('tools (harness-ui-access--insert-tools d))
        ('rules (harness-ui-access--insert-rules d))
        ('judgements
         (harness-ui-access--insert-judgements harness-ui-access--judgements expanded))
        (_
         (harness-ui-access--insert-settings d)
         (harness-ui-access--insert-dirs d)
         (harness-ui-access--insert-details d harness-ui-access--judgements)))))
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
  "Return the header line of the page.
It holds the page's name, the session, and its access in brief, fitted
to the window (`harness-ui-fit-header'): in a narrow one the brief goes
first, then the session, and the name stays."
  (let* ((d harness-ui-access--describe)
         (s (harness-ui-session harness-ui-session-id))
         (page harness-ui-access--page))
    (harness-ui-mode-line-escape
     (harness-ui-fit-header
      (list (concat " " (propertize "Jail & permissions" 'face 'bold)
                    (if (eq page 'overview) ""
                      (propertize (concat ": " (harness-ui-access--page-title page)) 'face 'bold)))
            (and s (list (concat "  " (harness-ui-session-label s)) 50))
            (and d (list (propertize
                          (format "  ·  sandbox %s · %s · network %s%s"
                                  (or (harness-ui-access--str (plist-get (plist-get d :sandbox) :backend)) "none")
                                  (harness-ui-permission-mode-label (harness-ui-access--str (plist-get d :mode)))
                                  (if (harness-ui-access--true-p (plist-get d :network)) "on" "off")
                                  (if (harness-ui-access--true-p (plist-get d :read-only)) " · read-only" ""))
                          'face 'harness-dim-face)
                         20)))))))

;;;; Commands

;;;;; The pages

(defun harness-ui-access--read-page ()
  "Read the page to show, by its title, with completion."
  (let* ((table (mapcar (lambda (entry) (cons (nth 1 entry) (car entry))) harness-ui-access--pages))
         (choice (completing-read "Page: " table nil t)))
    (cdr (assoc choice table))))

(defun harness-ui-access-show-page (page &optional filter)
  "Show PAGE of this view's session in place of this one.
PAGE is one of `harness-ui-access--pages': `overview', `tools', `rules'
or `judgements'.  FILTER, a plist as `harness-ui-access--filter' holds,
is the filter the Judgements page starts with.  The page is drawn from
what the harness says now; it takes the position this one had
\(`harness-ui-display-view')."
  (interactive (list (harness-ui-access--read-page)))
  (when harness-ui-access--deleted
    (user-error "Session deleted"))
  (let* ((sid (harness-ui-access--session))
         (position harness-ui-position)
         (buffer (harness-ui-access--buffer sid page)))
    (with-current-buffer buffer
      (when (and filter (eq page 'judgements))
        (setq harness-ui-access--filter filter))
      (harness-ui-access-refresh))
    (harness-ui-display-view buffer position)
    buffer))

(defun harness-ui-access-show-overview ()
  "Show the Overview page of this view's session: its settings and directories."
  (interactive)
  (harness-ui-access-show-page 'overview))

(defun harness-ui-access-show-tools ()
  "Show the Tools page of this view's session: what it is offered, and not."
  (interactive)
  (harness-ui-access-show-page 'tools))

(defun harness-ui-access-show-rules ()
  "Show the Rules page of this view's session: its permission rules."
  (interactive)
  (harness-ui-access-show-page 'rules))

(defun harness-ui-access-show-judgements ()
  "Show the Judgements page of this view's session: every call the chain judged."
  (interactive)
  (harness-ui-access-show-page 'judgements))

(defun harness-ui-access-quit ()
  "Go back from this page to the Overview, or put the view away from the Overview.
A page the Overview opened, such as the judgements, has the Overview
behind it, which is where q leads; the Overview itself is put out of
sight as any harness view is (`harness-ui-quit-view')."
  (interactive)
  (if (eq harness-ui-access--page 'overview)
      (harness-ui-quit-view)
    (harness-ui-access-show-page 'overview)))

;;;;; The settings

(defun harness-ui-access-choose-mode (mode)
  "Give this buffer's session the permission MODE, an id such as `auto'.
The radio buttons of the Overview run it; `harness-ui-access-set-mode'
asks which mode instead."
  (harness-ui--setting-set (harness-ui-access--session) :permission-mode mode
                           (format "Permission mode → %s" (harness-ui-permission-mode-label mode))))

(defun harness-ui-access-set-interaction (away)
  "Make this buffer's session non-interactive when AWAY, else interactive.
A non-interactive session never waits for you: the auto-mode judge
decides what would ask you for permission."
  (harness-ui--setting-set (harness-ui-access--session) :non-interactive away
                           (format "Non-interactive %s" (if away "on" "off"))))

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
                   (harness-ui-access--after (if on "Writing off" "Writing on"))))

(defun harness-ui-access-toggle-writing ()
  "Make this buffer's session read-only, or let it write again."
  (interactive)
  (let ((d harness-ui-access--describe))
    (when (and (harness-ui-access--true-p (plist-get d :read-only))
               (not (harness-ui-access--true-p (plist-get d :read-only-profile))))
      (user-error "Read-only by %s: not changeable here"
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
          (t (user-error "%s off: %s (not changeable here)" tool (plist-get off :why))))))

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
     (when why (user-error "No capability available: %s" why))
     (unless offer (user-error "All grantable capabilities given"))
     (list (harness-ui-access--read-capability "Give the session's commands: " offer))))
  (harness-ui-access-set-capability name t))

(defun harness-ui-access-revoke-capability (name)
  "Take the capability NAME away from this buffer's session's commands.
NAME is `all' to take every one away.  Interactively choose one of those
the commands hold."
  (interactive
   (let ((held (harness-ui-access--capabilities-held (harness-ui-access--capabilities))))
     (unless held (user-error "No capability held"))
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
     (when (and why (null held)) (user-error "No capability available: %s" why))
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
                   (harness-ui-access--after (format "Read access removed: %s" (harness-abbreviate-file-name dir)))))

(defun harness-ui-access-make-writable (dir)
  "Grant DIR, which this buffer's session may only read, for writing too."
  (let ((sid (harness-ui-access--session)))
    (harness-ui-call "_harness/permission/allow-dir" (list :session-id sid :dir dir)
                     (lambda (_)
                       (harness-ui-call "_harness/access/remove-read-dir" (list :session-id sid :dir dir)
                                        (harness-ui-access--after (format "Writable: %s" (harness-abbreviate-file-name dir))))))))

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
      ("dropped" (user-error "Given up already: %s (R restores)" shown))
      ("outputs" (user-error "Tool output directory: fixed"))
      (_ (when (y-or-n-p (format "Give up %s for this session? " shown))
           (harness-ui-access-drop-dir dir))))))

(defun harness-ui-access-restore-at-point ()
  "Give the session back the directory at point, which it gave up."
  (interactive)
  (let ((e (harness-ui-access--dir-at-point)))
    (unless (or (harness-ui-access--true-p (plist-get e :dropped))
                (harness-ui-access--true-p (plist-get e :given-up)))
      (user-error "Not given up: %s" (harness-abbreviate-file-name (plist-get e :dir))))
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
           (if (file-directory-p dir) (dired-other-window dir) (message "Not a directory here: %s" dir))))
        (t (user-error "Nothing to do here"))))

(defun harness-ui-access--action-at (pos)
  "Return the action of the button at POS, or nil.
A button is one of the view's, or one of a call's."
  (or (get-text-property pos 'harness-ui-action)
      (get-text-property pos 'harness-chat-action)))

(defun harness-ui-access--button-starts ()
  "Return where each button of the buffer starts, in order.
A button is text that runs something when clicked -- the view's own
buttons and links, and the buttons of the calls it draws."
  (let ((pos (point-min)) previous starts)
    (while (< pos (point-max))
      (let ((action (harness-ui-access--action-at pos)))
        (when (and action (not (eq action previous)))
          (push pos starts))
        (setq previous action))
      (setq pos (min (or (next-single-property-change pos 'harness-ui-action nil (point-max)) (point-max))
                     (or (next-single-property-change pos 'harness-chat-action nil (point-max)) (point-max)))))
    (nreverse starts)))

(defun harness-ui-access-next-button (n)
  "Move to the start of the Nth next button, back when N is negative.
Past the last button the first is next, as TAB goes round a form."
  (interactive "p")
  (let ((starts (harness-ui-access--button-starts)))
    (if (null starts)
        (message "No buttons here")
      (dotimes (_ (abs n))
        (let ((here (point)))
          (goto-char
           (if (> n 0)
               (or (cl-find-if (lambda (p) (> p here)) starts) (car starts))
             (or (cl-find-if (lambda (p) (< p here)) (reverse starts)) (car (last starts))))))))))

(defun harness-ui-access-previous-button (n)
  "Move to the start of the Nth previous button."
  (interactive "p")
  (harness-ui-access-next-button (- n)))

(defun harness-ui-access-toggle ()
  "Fold or unfold the call at point, or move to the next button."
  (interactive)
  (if (and (get-text-property (point) 'harness-chat-node)
           (not (harness-ui-access--action-at (point))))
      (harness-chat-toggle-block)
    (harness-ui-access-next-button 1)))

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
   (let* ((table '(("all" . nil) ("denied" . "deny") ("asked" . "asked") ("allowed" . "allow")
                   ("waiting" . "ask")))
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
    (define-key map (kbd "q") #'harness-ui-access-quit)
    (define-key map (kbd "1") #'harness-ui-access-show-overview)
    (define-key map (kbd "2") #'harness-ui-access-show-tools)
    (define-key map (kbd "3") #'harness-ui-access-show-rules)
    (define-key map (kbd "4") #'harness-ui-access-show-judgements)
    (define-key map (kbd "TAB") #'harness-ui-access-toggle)
    (define-key map (kbd "<backtab>") #'harness-ui-access-previous-button)
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
  "Major mode of a page of a session's access view (`harness-access').
The Overview lists the session's settings -- permission mode, whether
it asks you, network, writing, the Linux capabilities of its commands
and its sandbox -- and its directories, and changes them; the Tools,
Rules and Judgements pages list what its name says.  The keys 1 to 4
show the pages, q goes back to the Overview.

\\{harness-ui-access-mode-map}"
  (setq truncate-lines t)
  (setq header-line-format '(:eval (harness-ui-access--header)))
  (add-hook 'window-buffer-change-functions #'harness-ui-access--shown nil t)
  ;; Says [Suspended: resume] if a window shows it before it caught up.
  (harness-ui-view-adopt #'harness-ui-access-refresh))

;; The view's keys in the harness menu, behind `.'.
(put 'harness-ui-access-mode 'harness-menu-group
     '("Jail & permissions"
       ["Pages"
        (". 1" "Overview" harness-ui-access-show-overview)
        (". 2" "Tools" harness-ui-access-show-tools)
        (". 3" "Rules" harness-ui-access-show-rules)
        (". 4" "Judgements" harness-ui-access-show-judgements)
        (". q" "Back to the Overview" harness-ui-access-quit)]
       ["Settings"
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

(defun harness-ui-access--init ()
  "Wire the access views into the UI, and bind j and d in `harness-ui-map'."
  (add-hook 'harness-ui-event-functions #'harness-ui-access--on-event)
  (add-hook 'harness-ui-update-functions #'harness-ui-access--on-update)
  (define-key harness-ui-map (kbd "j") #'harness-access)
  (define-key harness-ui-map (kbd "d") #'harness-directories))

(defun harness-ui-access--shutdown ()
  "Unwire the access views."
  (remove-hook 'harness-ui-event-functions #'harness-ui-access--on-event)
  (remove-hook 'harness-ui-update-functions #'harness-ui-access--on-update))

(harness-define-module 'ui-access
  :doc "The jail and permissions view of a session, in four pages: its settings and directories, its tools, its rules and the judgements of its calls, each drawn as the chat draws it."
  :requires '(ui ui-chat ui-pending)
  :init #'harness-ui-access--init
  :shutdown #'harness-ui-access--shutdown)

(provide 'harness-ui-access)
;;; harness-ui-access.el ends here
