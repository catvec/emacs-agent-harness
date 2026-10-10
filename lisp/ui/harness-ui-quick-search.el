;;; harness-ui-quick-search.el --- Find a session, a command or a task from anywhere  -*- lexical-binding: t; -*-

;;; Commentary:

;; C-c h / -- or / in the harness menu -- opens the quick search from
;; any buffer: a popout at the bottom of the frame whose box takes a
;; line in words, the way a command palette does ("how do I attach a
;; file?", "where did I debug the merge queue?", "the task about the
;; docs").  RET in the box sends the line, with where it was typed, to
;; a quick, cheap model (`search/ask', see harness-tasks-search.el),
;; which answers with the commands, sessions and tasks the line is
;; about, never with prose.  The line stays in the box, to be refined;
;; M-p and M-n bring back earlier searches.
;;
;; Where the search opens sets what it favours, its bias: tasks on a
;; task board, sessions in the session list or a conversation tree,
;; commands anywhere else (`harness-quick-search-bias').  Favoured, not
;; alone: the model reads the rest too, and looks wider when what it
;; favours has no answer.  [Search sessions] and [Search commands] ask
;; the same line again, favouring those.
;;
;; The commands are the UI's to know, so the search sends their
;; catalogue along (`harness-quick-search-commands'): the harness menu,
;; the keys under C-c h, the commands the harness's modes list for the
;; menu and every other harness command, each with its keys, where it
;; applies and whether it runs where the search was opened.
;;
;; What the model found shows in the popout, each line with its
;; buttons: [Run] runs a command in the buffer the search was opened
;; from, [Describe] shows its documentation, [Open] opens a session and
;; [Board] shows a task on its board.  An order to manage tasks ("stop
;; the docs task") is only proposed here: [Do it] does it.
;;
;; On a task board, C-c h / is the board's own search
;; (`harness-tasks-search'), which filters the board.  The lines of
;; what a search found (`harness-quick-search-session-line' and the
;; others) serve the board too, with buttons of its own.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-popout)

(declare-function transient-get-suffix "transient")
(declare-function transient-append-suffix "transient")
(declare-function transient-remove-suffix "transient")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-tasks-search "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-show-plan "harness-ui-tasks-search")
(declare-function harness-chat--project "harness-ui-chat")

(defvar harness-ui-tasks--dir)
(defvar harness-ui-tasks--project)
(defvar harness-ui-tree--session-id)

(defgroup harness-quick-search nil
  "The quick search: a session, a command or a task, found from anywhere."
  :group 'harness-ui)

(harness-ui-define-icon harness-icon-search "search" "⌕" "find" "A search.")

(defface harness-quick-search-query-face '((t :inherit harness-label-face))
  "The line a quick search asked, above what it found."
  :group 'harness-quick-search)

(defface harness-quick-search-heading-face '((t :inherit (bold harness-dim-face)))
  "The headings of what a quick search found: Commands, Sessions, Tasks."
  :group 'harness-quick-search)

(defface harness-quick-search-proposal-face '((t :inherit harness-caution-face))
  "What a quick search proposes to do to tasks, waiting for your OK."
  :group 'harness-quick-search)

(defvar harness-quick-search-history nil
  "The lines searched with the quick search, newest first.")

(defconst harness-quick-search--key '(quick-search)
  "The KEY of the quick search's popout.")

;;;; Where a search comes from

(defvar-local harness-quick-search--origin nil
  "The buffer the quick search in this popout was opened from.")

(defvar-local harness-quick-search--origin-window nil
  "The window the quick search in this popout was opened from.")

(defvar-local harness-quick-search--context nil
  "Where the quick search in this popout was opened.
That is what `harness-quick-search-context' says of the buffer it was
opened from.")

(defvar-local harness-quick-search--catalogue nil
  "The commands the quick search in this popout sends along.")

(defvar-local harness-quick-search--state nil
  "The search this popout shows, a plist:
`:query'    the line asked;
`:seq'      its number, which an answer must carry to count;
`:status'   `idle', `searching', `done' or `failed';
`:bias'     what it favours;
`:plan'     the answer, once done;
`:error'    why it failed;
`:model'    the model that answers, once known;
`:proposed' the actions of the answer waiting for your OK;
`:running'  those being done;
`:results'  how they went.")

(defvar-local harness-quick-search--seq 0
  "The number of this popout's latest search.
Answers to earlier ones are dropped.")

(defvar-local harness-quick-search--model nil
  "The model that answers this popout's searches, as `search/warm' said.")

(defun harness-quick-search--session-name (id)
  "Return the name of session ID as the UI's cache has it, or nil."
  (let ((name (and (stringp id) (plist-get (harness-ui-session id) :name))))
    (and (stringp name) (not (string-blank-p name)) name)))

(defun harness-quick-search--project-name (dir)
  "Return the name of the project at DIR: its directory's name."
  (and (stringp dir) (not (string-empty-p dir))
       (file-name-nondirectory (directory-file-name dir))))

(defun harness-quick-search--quick-search-popout-p ()
  "Non-nil when this buffer is the quick search's popout, opened from somewhere."
  (and (derived-mode-p 'harness-ui-popout-mode) harness-quick-search--context t))

(defun harness-quick-search-context (&optional buffer)
  "Return where a search typed in BUFFER, by default the current one, comes from.
That is (:view VIEW :title TITLE :mode MODE :session ID :project DIR),
what `search/ask' takes as its `:context':
  VIEW     \"board\" on a task board, \"chat\" in a session's chat,
           \"sessions\" in the session list, \"tree\" in a
           conversation tree, \"settings\" in the settings, and
           \"buffer\" anywhere else;
  TITLE    what the buffer shows: the board's project, the chat's
           session, the tree's session, else the buffer's name;
  MODE     the buffer's major mode, by name;
  ID       the session of a chat, which a search leaves out of what it
           finds, or nil;
  DIR      the project directory to search from: the board's, the
           chat's session's, else the buffer's directory, or the
           home directory for a remote one.
In the quick search's own popout it is the context of the buffer the
search was opened from."
  (with-current-buffer (or buffer (current-buffer))
    (if (harness-quick-search--quick-search-popout-p)
        harness-quick-search--context
      (let ((title (buffer-name))
            (session nil)
            (project default-directory)
            (view "buffer"))
        (cond
         ((derived-mode-p 'harness-ui-tasks-mode)
          (let ((dir (or (bound-and-true-p harness-ui-tasks--dir) default-directory)))
            (setq view "board"
                  project dir
                  title (or (harness-quick-search--project-name
                             (or (bound-and-true-p harness-ui-tasks--project) dir))
                            title))))
         ((derived-mode-p 'harness-chat-mode)
          (setq view "chat"
                session harness-ui-session-id
                title (or (harness-quick-search--session-name session) title)
                project (or (and (fboundp 'harness-chat--project)
                                 (let ((dir (ignore-errors (harness-chat--project))))
                                   (and (stringp dir) (not (string-empty-p dir)) dir)))
                            project)))
         ((derived-mode-p 'harness-ui-sessions-mode) (setq view "sessions"))
         ((derived-mode-p 'harness-ui-tree-mode)
          (setq view "tree"
                title (or (harness-quick-search--session-name (bound-and-true-p harness-ui-tree--session-id))
                          title)))
         ((derived-mode-p 'harness-ui-config-mode) (setq view "settings")))
        (list :view view
              :title (substring-no-properties title)
              :mode (symbol-name major-mode)
              :session session
              ;; A remote directory is no project of the harness, whose
              ;; looking there would wait on the network.
              :project (if (or (not (stringp project)) (file-remote-p project))
                           (expand-file-name "~/")
                         (expand-file-name project)))))))

(defun harness-quick-search-bias (context)
  "Return what a search from CONTEXT favours: \"tasks\", \"sessions\" or \"commands\".
Tasks on a task board, sessions in the session list or a conversation
tree, commands anywhere else.  CONTEXT is what
`harness-quick-search-context' returns."
  (pcase (plist-get context :view)
    ("board" "tasks")
    ((or "sessions" "tree") "sessions")
    (_ "commands")))

;;;; The commands a search may name

(defconst harness-quick-search--catalogue-ttl 60
  "Seconds a catalogue of commands serves the buffers of the same modes.")

(defvar harness-quick-search--catalogues (make-hash-table :test 'equal)
  "Catalogues built lately: (MAJOR-MODE . MINOR-MODES) -> (TIME . CATALOGUE).
MINOR-MODES are the minor modes on that list commands for the menu.")

(defun harness-quick-search--text (value)
  "Return VALUE when it is a string with something in it, without properties."
  (and (stringp value) (not (string-blank-p value)) (substring-no-properties value)))

(defun harness-quick-search--label (description)
  "Return DESCRIPTION, a menu suffix's, as text, or nil.
A function is called, its errors ignored, for the text it returns."
  (harness-quick-search--text
   (cond ((stringp description) description)
         ((functionp description) (ignore-errors (funcall description))))))

(defun harness-quick-search--prefix-keys ()
  "Return the keys of `harness-ui-prefix-key', or nil."
  (let ((prefix harness-ui-prefix-key))
    (cond ((stringp prefix) (ignore-errors (kbd prefix)))
          ((vectorp prefix) prefix))))

(defun harness-quick-search--suffix-plist (node)
  "Return the properties of NODE when it is a suffix of a transient layout.
A suffix is (CLASS . PLIST), or (LEVEL CLASS PLIST) as older transients
have it, PLIST holding its `:command'."
  (cond
   ((and (consp node) (symbolp (car node)) (car node) (not (keywordp (car node)))
         (plistp (cdr node)) (plist-get (cdr node) :command))
    (cdr node))
   ((and (consp node) (integerp (car node)) (consp (cdr node)) (symbolp (cadr node))
         (consp (cddr node)) (plistp (nth 2 node)) (plist-get (nth 2 node) :command))
    (nth 2 node))))

(defun harness-quick-search--menu-suffixes ()
  "Return the property lists of the suffixes of `harness-menu''s own groups.
The layout is walked defensively, through vectors and lists, so a
transient that lays it out otherwise gives fewer suffixes, not an error."
  (let (out)
    (cl-labels ((walk (node depth)
                  (when (< depth 16)
                    (if-let* ((plist (harness-quick-search--suffix-plist node)))
                        (push plist out)
                      (cond ((vectorp node) (mapc (lambda (child) (walk child (1+ depth))) node))
                            ((proper-list-p node) (dolist (child node) (walk child (1+ depth)))))))))
      (walk (get 'harness-menu 'transient--layout) 0))
    (nreverse out)))

(defun harness-quick-search--binding (binding)
  "Return what BINDING, a key's binding in a keymap, runs, else nil.
That is a command symbol, or a keymap to walk into."
  (let ((def (pcase binding
               (`(menu-item ,_ ,def . ,_) def)
               (`(,(pred stringp) ,(pred stringp) . ,def) def)
               (`(,(pred stringp) . ,def) def)
               (_ binding))))
    (and (or (keymapp def) (and (symbolp def) (commandp def))) def)))

(defun harness-quick-search--map-walk (map prefix fn &optional depth)
  "Call FN with the keys and the command of each binding of MAP under PREFIX.
Prefix keymaps are walked into, a few levels deep."
  (let ((depth (or depth 0)))
    (map-keymap
     (lambda (event binding)
       (unless (memq event '(remap menu-bar tool-bar tab-bar))
         (let ((def (harness-quick-search--binding binding))
               (keys (vconcat prefix (vector event))))
           (cond ((and (symbolp def) (commandp def)) (funcall fn keys def))
                 ((and (keymapp def) (< depth 4))
                  (harness-quick-search--map-walk def keys fn (1+ depth)))))))
     map)))

(defun harness-quick-search--group-items (column)
  "Return the suffixes of COLUMN, a `harness-menu-group' column.
COLUMN is a vector [HEADING (KEY DESCRIPTION COMMAND . PROPS)...], a
level and keywords with their values allowed in it as transient has
them."
  (let ((items (cond ((vectorp column) (append column nil))
                     ((proper-list-p column) column)))
        out)
    (while items
      (let ((item (pop items)))
        (cond ((keywordp item) (pop items))
              ((vectorp item) (setq out (append (reverse (harness-quick-search--group-items item)) out)))
              ((and (consp item) (stringp (car item)) (proper-list-p item) (>= (length item) 3))
               (push item out)))))
    (nreverse out)))

(defun harness-quick-search--group-key (key)
  "Return KEY of a `harness-menu-group' suffix as the buffer takes it.
\". x\" is the plain key x."
  (when (stringp key)
    (let ((key (if (string-prefix-p ". " key) (substring key 2) key)))
      (or (ignore-errors (key-description (kbd key))) key))))

(defun harness-quick-search--major-mode-command-p (symbol)
  "Non-nil when SYMBOL, a command, turns on a major mode: no command to suggest."
  (and (string-suffix-p "-mode" (symbol-name symbol))
       (not (memq symbol minor-mode-list))))

(defun harness-quick-search--scan ()
  "Return (MODES . COMMANDS) from every symbol, each sorted by name.
MODES have a `harness-menu-group'; COMMANDS are the interactive
commands named harness-*, but those with \"--\", the obsolete ones and
those that turn on a major mode."
  (let (modes commands)
    (mapatoms
     (lambda (symbol)
       (when (get symbol 'harness-menu-group) (push symbol modes))
       (let ((name (symbol-name symbol)))
         (when (and (string-prefix-p "harness-" name)
                    (not (string-search "--" name))
                    (commandp symbol)
                    (not (get symbol 'byte-obsolete-info))
                    (not (harness-quick-search--major-mode-command-p symbol)))
           (push symbol commands)))))
    (cons (sort modes #'string<) (sort commands #'string<))))

(defun harness-quick-search--mode-lineage ()
  "Return the major mode and the modes it derives from, nearest first."
  (let ((mode major-mode) lineage)
    (while (and mode (symbolp mode) (not (memq mode lineage)))
      (push mode lineage)
      (setq mode (get mode 'derived-mode-parent)))
    (nreverse lineage)))

(defun harness-quick-search--minor-modes-on ()
  "Return the minor modes on in this buffer that list commands for the menu."
  (cl-remove-if-not (lambda (mode)
                      (and (get mode 'harness-menu-group) (boundp mode) (symbol-value mode)))
                    minor-mode-list))

(defun harness-quick-search--doc (command)
  "Return the first line of COMMAND's documentation, or nil."
  (when-let* ((doc (ignore-errors (documentation command t)))
              (line (car (split-string doc "\n" t "[ \t]+"))))
    (harness-quick-search--text
     (if (string-search "\\" line)
         (or (ignore-errors (substitute-command-keys line)) line)
       line))))

(defun harness-quick-search--build-catalogue ()
  "Return the catalogue of commands as this buffer sees it.
See `harness-quick-search-commands'."
  (let* ((table (make-hash-table :test 'eq))
         (order nil)
         (prefix (harness-quick-search--prefix-keys))
         (scan (harness-quick-search--scan))
         (here-modes (append (harness-quick-search--minor-modes-on)
                             (cl-remove-if-not (lambda (mode) (get mode 'harness-menu-group))
                                               (harness-quick-search--mode-lineage))))
         (modes (append here-modes (cl-remove-if (lambda (mode) (memq mode here-modes)) (car scan)))))
    (cl-flet ((add (command where keys label here)
                (when (and command (symbolp command) (commandp command))
                  (let ((entry (gethash command table)))
                    (unless entry (push command order))
                    (puthash command
                             (list :where (or (plist-get entry :where) (harness-quick-search--text where))
                                   :keys (or (plist-get entry :keys) (harness-quick-search--text keys))
                                   :label (or (plist-get entry :label) (harness-quick-search--text label))
                                   :here (or (plist-get entry :here) here))
                             table)))))
      ;; The menu's own groups.
      (let ((menu (and prefix (where-is-internal 'harness-menu (list harness-ui-map) t))))
        (dolist (suffix (harness-quick-search--menu-suffixes))
          (let ((key (plist-get suffix :key)))
            (add (plist-get suffix :command) "menu"
                 (and menu (stringp key) (ignore-errors (key-description (vconcat prefix menu (kbd key)))))
                 (harness-quick-search--label (plist-get suffix :description))
                 t))))
      ;; The keys under the prefix, from anywhere.
      (harness-quick-search--map-walk
       harness-ui-map (or prefix [])
       (lambda (keys command) (add command "global" (and prefix (key-description keys)) nil t)))
      ;; What the modes list for the menu: those on here first, so that
      ;; a command several list goes by the one that applies.
      (dolist (mode modes)
        (let ((group (get mode 'harness-menu-group)))
          (when (consp group)
            (dolist (column (cdr group))
              (dolist (item (harness-quick-search--group-items column))
                (add (nth 2 item) (car group) (harness-quick-search--group-key (car item))
                     (harness-quick-search--label (nth 1 item)) (and (memq mode here-modes) t)))))))
      ;; Every other harness command.
      (dolist (command (cdr scan))
        (add command nil nil nil nil)))
    ;; A key bound here wins, and the command runs here.
    (mapcar (lambda (command)
              (let ((entry (gethash command table))
                    (bound (where-is-internal command nil t)))
                (list :command (symbol-name command)
                      :keys (if bound (key-description bound) (plist-get entry :keys))
                      :where (plist-get entry :where)
                      :label (plist-get entry :label)
                      :doc (harness-quick-search--doc command)
                      :here (if (or bound (plist-get entry :here)) t :false))))
            (nreverse order))))

(defun harness-quick-search-commands (&optional buffer)
  "Return the catalogue of the harness's commands, as seen from BUFFER.
BUFFER is the current buffer by default.  The catalogue is a list of
\(:command NAME :keys KEYS :where WHERE :label LABEL :doc DOC :here
HERE), what `search/ask' takes as its `:commands', one entry a command:
  NAME   the command's name;
  KEYS   its keys: those BUFFER binds it to, else those under
         `harness-ui-prefix-key', in the harness menu or in the mode
         that lists it, or nil;
  WHERE  \"menu\" for the harness menu's own commands, \"global\" for
         the keys under the prefix, the title of the mode's commands
         in the menu (\"Chat\") for a mode's, else nil;
  LABEL  what the menu calls it, or nil;
  DOC    the first line of its documentation, or nil;
  HERE   t when it runs in BUFFER -- BUFFER binds it, it is under the
         prefix or in the menu's own groups, or a mode on in BUFFER
         lists it -- else :false.
The commands come from the harness menu, `harness-ui-map', the
`harness-menu-group' of every mode, and every other interactive
harness command; a command found several ways takes each field from
the first that has it.  The catalogue is kept a minute for buffers of
the same modes: do not change it.  In the quick search's popout it is
the one of the buffer the search was opened from."
  (with-current-buffer (or buffer (current-buffer))
    (if (and (harness-quick-search--quick-search-popout-p) harness-quick-search--catalogue)
        harness-quick-search--catalogue
      (let* ((key (cons major-mode (harness-quick-search--minor-modes-on)))
             (cached (gethash key harness-quick-search--catalogues)))
        (if (and cached (< (- (float-time) (car cached)) harness-quick-search--catalogue-ttl))
            (cdr cached)
          (let ((catalogue (harness-quick-search--build-catalogue)))
            (puthash key (cons (float-time) catalogue) harness-quick-search--catalogues)
            catalogue))))))

;;;; The box

(defvar-local harness-quick-search-box-function nil
  "Function the search box sends its line to, with the box's text trimmed.
`harness-quick-search-box-submit' calls it.")

(defvar-local harness-quick-search--history-index nil
  "Which entry of `harness-quick-search-history' the box shows, or nil.")

(defvar-local harness-quick-search--typed nil
  "What the box held before an earlier search replaced it.")

(defun harness-quick-search--box-binding (command)
  "Return COMMAND while point is in the compose box, else nil.
Outside the box the key does what the buffer binds it to."
  (and (harness-compose-in-p) command))

(defvar harness-quick-search-box-mode-map (make-sparse-keymap)
  "Keys of `harness-quick-search-box-mode', which act in the box only.")

;; Filled at top level, not in the `defvar', so a reload updates it.
(let ((map harness-quick-search-box-mode-map))
  (define-key map (kbd "RET")
              '(menu-item "" harness-quick-search-box-submit :filter harness-quick-search--box-binding))
  (define-key map (kbd "M-p")
              '(menu-item "" harness-quick-search-box-previous :filter harness-quick-search--box-binding))
  (define-key map (kbd "M-n")
              '(menu-item "" harness-quick-search-box-next :filter harness-quick-search--box-binding)))

(define-minor-mode harness-quick-search-box-mode
  "Make this buffer's compose box take a search.
In the box, \\`RET' sends its line to `harness-quick-search-box-function',
and \\`M-p' and \\`M-n' put the earlier searches in it, from
`harness-quick-search-history'.  Elsewhere in the buffer the keys are
the buffer's own."
  :lighter nil
  :keymap harness-quick-search-box-mode-map
  (setq harness-quick-search--history-index nil
        harness-quick-search--typed nil))

(defun harness-quick-search--put (text)
  "Put TEXT in the box, point at its end."
  (harness-compose-set text)
  (when (harness-compose-live-p)
    (goto-char harness-compose-end)))

(defun harness-quick-search-box-submit ()
  "Send the box's line to `harness-quick-search-box-function'."
  (interactive)
  (unless (harness-compose-live-p) (user-error "No box here"))
  (unless harness-quick-search-box-function (user-error "This box takes no search"))
  (setq harness-quick-search--history-index nil
        harness-quick-search--typed nil)
  (funcall harness-quick-search-box-function (string-trim (harness-compose-text))))

(defun harness-quick-search--history-step (n)
  "Put the search N entries further back in the history in the box.
A negative N goes forward, and past the newest entry to what the box
held before.  An entry the box holds already is skipped."
  (unless (harness-compose-live-p) (user-error "No box here"))
  (let* ((history harness-quick-search-history)
         (current (string-trim (harness-compose-text)))
         (start (or harness-quick-search--history-index -1))
         (step (if (> n 0) 1 -1))
         (i start))
    (dotimes (_ (abs n))
      (setq i (+ i step))
      (while (and (>= i 0) (< i (length history)) (equal (nth i history) current))
        (setq i (+ i step))))
    (cond
     ((>= i (length history)) (user-error "No earlier search"))
     ((< i 0)
      (when (< start 0) (user-error "No later search"))
      (setq harness-quick-search--history-index nil)
      (harness-quick-search--put (or harness-quick-search--typed "")))
     (t
      (when (< start 0) (setq harness-quick-search--typed (harness-compose-text)))
      (setq harness-quick-search--history-index i)
      (harness-quick-search--put (nth i history))))))

(defun harness-quick-search-box-previous (&optional n)
  "Put the previous search in the box, from `harness-quick-search-history'.
With N, go back N searches."
  (interactive "p")
  (harness-quick-search--history-step (or n 1)))

(defun harness-quick-search-box-next (&optional n)
  "Put the next search in the box, or what it held before the earlier ones.
With N, go forward N searches."
  (interactive "p")
  (harness-quick-search--history-step (- (or n 1))))

;;;; The lines of what a search found

(defun harness-quick-search--button (label action help)
  "Return LABEL as a button that calls ACTION, a function of no arguments.
HELP is its tooltip."
  (buttonize label (lambda (_) (funcall action)) nil help))

(defun harness-quick-search--quote (text)
  "Return TEXT in quotes, on one line and not too long."
  (format "“%s”" (harness-truncate-end (harness-ui-one-line (format "%s" (or text ""))) 80)))

(defun harness-quick-search--kind (session)
  "Return what SESSION, a plan's entry, is, in a word or two."
  (let ((task (plist-get session :task)))
    (if (and (stringp task) (not (string-empty-p task)))
        (concat "task " task)
      (pcase (plist-get session :kind)
        ((or 'nil "" "main" 'main) "chat")
        ((or "subagent" 'subagent) "sub-agent")
        ((or "btw" 'btw) "BTW")
        (kind (format "%s" kind))))))

(defun harness-quick-search--line (text)
  "Return TEXT, one line or more, indented, its wrapped lines too."
  (propertize (concat "  " text "\n") 'wrap-prefix "      "))

(defun harness-quick-search-session-line (session &optional button)
  "Return the line that shows SESSION as a search found it.
SESSION is an entry of a plan's `:sessions': (:id :name :kind :status
:project :cwd :updated :snippet :task).  The line has its status, its
name, what it is, its project and when it was last active, then
\[Open]; a passage the search found in it follows, dim, on a second
line.  BUTTON makes the button: a function of LABEL, ACTION (a function
of no arguments) and HELP returning its text,
`harness-quick-search--button' by default."
  (let* ((button (or button #'harness-quick-search--button))
         (id (plist-get session :id))
         (name (harness-ui-session-name id (harness-quick-search--text (plist-get session :name))))
         (updated (plist-get session :updated))
         (details (delq nil (list (harness-quick-search--kind session)
                                  (harness-quick-search--text (plist-get session :project))
                                  (and (numberp updated) (> updated 0)
                                       (concat "updated " (harness-relative-time updated))))))
         (snippet (harness-quick-search--text (plist-get session :snippet))))
    (concat
     (harness-quick-search--line
      (concat (harness-ui-status-icon (plist-get session :status)) " "
              (propertize name 'face 'bold) "  "
              (propertize (string-join details " · ") 'face 'harness-dim-face) "  "
              (funcall button "[Open]" (lambda () (harness-quick-search-open-session id))
                       (format "Open the session %s" (harness-quick-search--quote name)))))
     (if snippet
         (harness-quick-search--line
          (propertize (concat "  " (harness-truncate-end (harness-ui-one-line snippet) 160))
                      'face 'harness-dim-face))
       ""))))

(defun harness-quick-search-command-line (command &optional button)
  "Return the line that shows COMMAND as a search found it.
COMMAND is an entry of the catalogue (`harness-quick-search-commands'),
as a plan's `:commands' holds them.  The line has its keys, what it
does (its label, else the first line of its documentation), its name
and where it applies, then [Run] when it runs where the search was
opened, and [Describe].  BUTTON makes the buttons, as in
`harness-quick-search-session-line'."
  (let* ((button (or button #'harness-quick-search--button))
         (name (format "%s" (plist-get command :command)))
         (symbol (intern-soft name))
         (keys (harness-quick-search--text (plist-get command :keys)))
         (where (harness-quick-search--text (plist-get command :where)))
         (what (or (harness-quick-search--text (plist-get command :label))
                   (harness-quick-search--text (plist-get command :doc))
                   name)))
    (harness-quick-search--line
     (concat (propertize (or keys "M-x") 'face 'help-key-binding) " "
             what "  "
             (propertize (format "(%s%s)" name (if where (concat ", " where) "")) 'face 'harness-dim-face)
             (if (harness-json-true-p (plist-get command :here))
                 (concat "  " (funcall button "[Run]" (lambda () (harness-quick-search-run-command name))
                                       (format "Run %s where the search was opened" name)))
               "")
             (if (and symbol (fboundp symbol))
                 (concat (if (harness-json-true-p (plist-get command :here)) " " "  ")
                         (funcall button "[Describe]" (lambda () (describe-function symbol))
                                  (format "Show the documentation of %s" name)))
               "")))))

(defun harness-quick-search--task-target (id)
  "Return (IDS QUERY DIR): how [Board] on task ID shows it.
In the quick search's popout that is every task its search found, ID
first, its query and its project; elsewhere ID alone, here."
  (let* ((state (and (harness-quick-search--quick-search-popout-p) harness-quick-search--state))
         (plan (plist-get state :plan))
         (found (mapcar (lambda (task) (plist-get task :id)) (plist-get plan :tasks))))
    (list (delete-dups (cons id (append (plist-get plan :ids) found nil)))
          (or (plist-get plan :query) (plist-get state :query))
          (or (plist-get (harness-quick-search-context) :project) default-directory))))

(defun harness-quick-search-task-line (task &optional button)
  "Return the line that shows TASK as a search found it.
TASK is an entry of a plan's `:tasks': (:id :title :status :session).
The line has its id, its title and, dim, where it stands, then [Board],
which shows it on its board.  BUTTON makes the button, as in
`harness-quick-search-session-line'."
  (let* ((button (or button #'harness-quick-search--button))
         (id (plist-get task :id))
         (target (harness-quick-search--task-target id)))
    (harness-quick-search--line
     (concat (propertize (format "%s" (or id "?")) 'face 'harness-dim-face) " "
             (propertize (or (harness-quick-search--text (plist-get task :title)) "(untitled)") 'face 'bold)
             (if-let* ((status (harness-quick-search--text (plist-get task :status))))
                 (concat "  " (propertize status 'face 'harness-dim-face))
               "")
             "  "
             (funcall button "[Board]" (lambda () (apply #'harness-quick-search-show-tasks target))
                      "Show this task on its board")))))

;;;; What the buttons do

(defun harness-quick-search--leave (&optional switch)
  "Close the quick search's popout and select the window it was opened from.
With SWITCH that window shows the buffer the search was opened from
again, when it shows another now.  Return that buffer when it is live."
  (let* ((popout (harness-ui-popout-buffer harness-quick-search--key))
         (origin (and popout (buffer-local-value 'harness-quick-search--origin popout)))
         (window (and popout (buffer-local-value 'harness-quick-search--origin-window popout))))
    (when popout (harness-ui-popout-close harness-quick-search--key t))
    (when (and (window-live-p window) (not (window-minibuffer-p window)))
      (select-window window))
    (when (and switch (buffer-live-p origin) (not (eq (window-buffer (selected-window)) origin)))
      (if (window-live-p window)
          (pop-to-buffer-same-window origin)
        (pop-to-buffer origin)))
    (and (buffer-live-p origin) origin)))

(defun harness-quick-search-open-session (id)
  "Open session ID, as a search found it.
The quick search closes, and the session opens from the window it was
opened from, as it would from there (`harness-ui-visit-session')."
  (harness-quick-search--leave)
  (harness-ui-visit-session id))

(defun harness-quick-search-run-command (name)
  "Run the harness command NAME where the quick search was opened.
NAME is the command's name as a search found it; only an interned
harness command runs.  The quick search closes, and the command runs in
the buffer the search was opened from, in its window, as if typed
there.  An error it signals is shown in the echo area."
  (let ((command (and (stringp name) (intern-soft name))))
    (unless (and command (string-prefix-p "harness-" name) (commandp command))
      (user-error "Not a harness command: %s" name))
    (harness-quick-search--leave t)
    (condition-case err
        (progn
          (setq this-command command)
          (call-interactively command t))
      (error (message "%s: %s" name (error-message-string err))))))

(defun harness-quick-search-show-tasks (ids query dir)
  "Show the tasks IDS on the board of DIR's project, found by searching QUERY.
The quick search closes and the board opens (`harness-tasks').  It
shows those tasks the way its own search would, where it can
\(`harness-ui-tasks-search-show-plan'); else it just opens."
  (unless (fboundp 'harness-tasks) (user-error "Task mode is off"))
  (harness-quick-search--leave)
  (let ((board (harness-tasks dir)))
    (when (and (fboundp 'harness-ui-tasks-search-show-plan) (bufferp board) (buffer-live-p board))
      (with-current-buffer board
        (harness-ui-tasks-search-show-plan (list :ids ids :query query))))
    board))

;;;; The popout

(defconst harness-quick-search--examples
  '(("commands" . "how do I attach a file?")
    ("sessions" . "where did I debug the merge queue?")
    ("tasks" . "the task about the docs"))
  "A line to search for each kind of thing found, for the empty popout.")

(defun harness-quick-search--order (bias)
  "Return the kinds of things found, as BIAS favours them, first first."
  (pcase bias
    ("tasks" '("tasks" "sessions" "commands"))
    ("sessions" '("sessions" "commands" "tasks"))
    (_ '("commands" "sessions" "tasks"))))

(defun harness-quick-search--found (plan kind)
  "Return the things of KIND, a string, PLAN found."
  (pcase kind
    ("commands" (plist-get plan :commands))
    ("sessions" (plist-get plan :sessions))
    ("tasks" (plist-get plan :tasks))))

(defun harness-quick-search--where (context)
  "Say where CONTEXT is, after \"From\"."
  (let ((title (harness-quick-search--text (plist-get context :title))))
    (pcase (plist-get context :view)
      ("board" (if title (format "the task board of %s" title) "a task board"))
      ("chat" (if title (format "the chat %s" (harness-quick-search--quote title)) "a chat"))
      ("sessions" "the session list")
      ("tree" (if title (format "the conversation tree of %s" (harness-quick-search--quote title))
                "a conversation tree"))
      ("settings" "the settings")
      (_ (let ((mode (harness-quick-search--text (plist-get context :mode))))
           (cond ((and title mode) (format "%s (%s)" (harness-quick-search--quote title) mode))
                 (title (harness-quick-search--quote title))
                 (t "a buffer")))))))

(defun harness-quick-search--favours (bias)
  "Say what BIAS favours, after \"favours\"."
  (pcase bias
    ("tasks" "tasks")
    ("sessions" "sessions, then commands")
    (_ "commands, then sessions")))

(defun harness-quick-search--count (n kind)
  "Return N things of KIND, a plural, in words: \"1 command\", \"2 sessions\"."
  (format "%d %s" n (if (= n 1) (substring kind 0 -1) kind)))

(defconst harness-quick-search--verbs
  '(("archive" "Archived" "archive")
    ("restore" "Restored" "restore")
    ("stop" "Stopped" "stop")
    ("retry" "Retried" "retry")
    ("start" "Started" "start")
    ("verify" "Verified" "verify")
    ("complete" "Marked done" "mark done")
    ("message" "Sent a message to" "message")
    ("reject" "Sent back" "send back")
    ("priority" "Changed the priority of" "change the priority of"))
  "How the quick search says what an action did: (ACTION DONE FAILED).")

(defun harness-quick-search--action-title (action)
  "The title of the task ACTION is about, quoted."
  (harness-quick-search--quote (or (harness-quick-search--text (plist-get action :title))
                                   (plist-get action :task) "?")))

(defun harness-quick-search--ask-text (actions)
  "Ask whether to do ACTIONS, the actions a search proposes."
  (concat
   (string-join
    (mapcar (lambda (action)
              (let ((title (harness-quick-search--action-title action))
                    (text (harness-quick-search--text (plist-get action :text))))
                (pcase (plist-get action :action)
                  ("complete" (format "mark %s done" title))
                  ("message" (format "send %s to %s" (harness-quick-search--quote text) title))
                  ("reject" (if text (format "send %s back: %s" title (harness-quick-search--quote text))
                              (format "send %s back" title)))
                  ("priority" (if text (format "make %s %s priority" title text)
                                (format "change the priority of %s" title)))
                  (name (format "%s %s" name title)))))
            actions)
    ", ")
   "?"))

(defun harness-quick-search--done-text (results)
  "Say how RESULTS, the actions done, went: \"Archived “A”; could not stop “B”: …\"."
  (let ((text (string-join
               (mapcar (lambda (result)
                         (let ((verbs (assoc (plist-get result :action) harness-quick-search--verbs))
                               (title (harness-quick-search--action-title result)))
                           (if (harness-json-true-p (plist-get result :ok))
                               (format "%s %s" (or (nth 1 verbs) (capitalize (format "%s" (plist-get result :action))))
                                       title)
                             (format "could not %s %s: %s" (or (nth 2 verbs) (plist-get result :action)) title
                                     (or (harness-quick-search--text (plist-get result :error)) "it failed")))))
                       results)
               "; ")))
    (if (string-empty-p text) text (concat (upcase (substring text 0 1)) (substring text 1)))))

(defun harness-quick-search--insert-head (state)
  "Insert the line saying what STATE, a search, asked and where it stands."
  (let ((dot (propertize " · " 'face 'harness-dim-face))
        (query (propertize (harness-quick-search--quote (plist-get state :query))
                           'face 'harness-quick-search-query-face)))
    (pcase (plist-get state :status)
      ('searching
       (insert (harness-quick-search--line
                (concat query dot
                        (propertize (format "asking %s…"
                                            (if-let* ((model (or (plist-get state :model) harness-quick-search--model)))
                                                (harness-ui-model-label model)
                                              "the model"))
                                    'face 'harness-dim-face)))))
      ('failed
       (insert (harness-quick-search--line
                (concat query dot (harness-ui-level-icon 'failure) " "
                        (propertize (concat "the search failed: " (harness-ui-one-line (plist-get state :error)))
                                    'face 'harness-failure-face)
                        "  "
                        (harness-quick-search--button
                         "[Retry]" (let ((query (plist-get state :query)) (bias (plist-get state :bias)))
                                     (lambda () (harness-quick-search--search query bias)))
                         "Ask again")))))
      ('done
       (let* ((plan (plist-get state :plan))
              (counts (delq nil (mapcar (lambda (kind)
                                          (let ((n (length (harness-quick-search--found plan kind))))
                                            (and (> n 0) (harness-quick-search--count n kind))))
                                        (harness-quick-search--order (plist-get state :bias)))))
              (looked (harness-quick-search--text (plist-get plan :looked))))
         (insert (harness-quick-search--line
                  (concat query
                          (if counts (concat dot (propertize (string-join counts ", ") 'face 'harness-dim-face)) "")
                          (if looked (concat dot (propertize looked 'face 'harness-dim-face)) "")))))))))

(defun harness-quick-search--empty-p (plan)
  "Non-nil when PLAN found and proposes nothing."
  (not (or (plist-get plan :commands) (plist-get plan :sessions) (plist-get plan :tasks)
           (plist-get plan :ids) (plist-get plan :actions))))

(defun harness-quick-search--insert-found (state)
  "Insert what STATE, a search that is done, found: its note, then each kind."
  (let ((plan (plist-get state :plan)))
    (if (harness-quick-search--empty-p plan)
        (insert (harness-quick-search--line
                 (propertize (format "Nothing found for %s: no task, session or command, even searching wider."
                                     (harness-quick-search--quote (plist-get state :query)))
                             'face 'harness-dim-face)))
      (when-let* ((note (harness-quick-search--text (plist-get plan :note))))
        (insert (harness-quick-search--line
                 (concat (if (eq t (plist-get plan :widened))
                             (concat (harness-ui-level-icon 'caution) " ")
                           "")
                         (propertize note 'face 'harness-dim-face)))))
      (dolist (kind (harness-quick-search--order (plist-get state :bias)))
        (when-let* ((found (harness-quick-search--found plan kind)))
          (insert "\n" (propertize (capitalize kind) 'face 'harness-quick-search-heading-face) "\n")
          (dolist (thing found)
            (insert (pcase kind
                      ("commands" (harness-quick-search-command-line thing))
                      ("sessions" (harness-quick-search-session-line thing))
                      (_ (harness-quick-search-task-line thing))))))))
    (harness-quick-search--insert-actions state)))

(defun harness-quick-search--insert-actions (state)
  "Insert what STATE, a search, proposes to do, or how doing it went."
  (let ((popout (current-buffer))
        (seq (plist-get state :seq)))
    (cond
     ((plist-get state :running)
      (insert "\n" (harness-quick-search--line
                    (concat (harness-ui-level-icon 'caution) " "
                            (propertize "Doing it…" 'face 'harness-dim-face)))))
     ((plist-get state :results)
      (let ((results (plist-get state :results)))
        (insert "\n" (harness-quick-search--line
                      (concat (harness-ui-level-icon
                               (if (cl-every (lambda (r) (harness-json-true-p (plist-get r :ok))) results)
                                   'success 'failure))
                              " " (harness-quick-search--done-text results))))))
     ((plist-get state :proposed)
      (let ((actions (plist-get state :proposed)))
        (insert "\n" (harness-quick-search--line
                      (concat (harness-ui-status-icon "blocked") " "
                              (propertize (let ((text (harness-quick-search--ask-text actions)))
                                            (concat (upcase (substring text 0 1)) (substring text 1)))
                                          'face 'harness-quick-search-proposal-face)
                              "  "
                              (harness-quick-search--button
                               "[Do it]" (lambda () (harness-quick-search--do popout seq actions))
                               "Do what the search proposes")
                              " "
                              (harness-quick-search--button
                               "[Skip]" (lambda () (harness-quick-search--update popout seq :proposed nil))
                               "Leave it undone")))))))))

(defun harness-quick-search--insert-hint (bias)
  "Insert what the empty quick search says: examples first, as BIAS favours."
  (insert (harness-quick-search--line (propertize "Say what you want, in words, for instance:" 'face 'harness-dim-face)))
  (dolist (kind (harness-quick-search--order bias))
    (insert (harness-quick-search--line
             (propertize (concat "  " (cdr (assoc kind harness-quick-search--examples))) 'face 'harness-hint-face))))
  (insert (harness-quick-search--line
           (propertize "RET searches · M-p and M-n bring back earlier searches · C-g closes"
                       'face 'harness-dim-face))))

(defun harness-quick-search--insert-footer (state)
  "Insert the buttons that ask STATE's line again, favouring something else."
  (let ((query (plist-get state :query)))
    (insert "\n"
            (harness-quick-search--line
             (concat (harness-quick-search--button
                      "[Search sessions]" (lambda () (harness-quick-search--search query "sessions"))
                      "Ask again, favouring sessions")
                     " "
                     (harness-quick-search--button
                      "[Search commands]" (lambda () (harness-quick-search--search query "commands"))
                      "Ask again, favouring commands"))))))

(defvar harness-quick-search-content-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keys on the quick search's content, over the popout's own.")

(defun harness-quick-search--add-keymap (start end map)
  "Give START..END the keymap MAP, under the keymaps the text has already."
  (let ((pos start))
    (while (< pos end)
      (let ((next (min end (or (next-single-property-change pos 'keymap nil end) end)))
            (existing (get-text-property pos 'keymap)))
        (put-text-property pos next 'keymap (if existing (make-composed-keymap (list existing map)) map))
        (setq pos next)))))

(defun harness-quick-search--render ()
  "Draw the quick search's content: where it was opened, then its search."
  (let* ((start (point))
         (state harness-quick-search--state)
         (context harness-quick-search--context)
         (bias (or (plist-get state :bias) (harness-quick-search-bias context))))
    (when context
      (insert (harness-quick-search--line
               (concat (propertize (harness-ui-icon 'harness-icon-search) 'face 'harness-dim-face) " "
                       (propertize (format "From %s · favours %s" (harness-quick-search--where context)
                                           (harness-quick-search--favours bias))
                                   'face 'harness-dim-face)))))
    (pcase (plist-get state :status)
      ((or 'searching 'failed) (harness-quick-search--insert-head state))
      ('done
       (harness-quick-search--insert-head state)
       (harness-quick-search--insert-found state))
      (_ (harness-quick-search--insert-hint bias)))
    (when (plist-get state :query)
      (harness-quick-search--insert-footer state))
    (harness-quick-search--add-keymap start (point) harness-quick-search-content-map)))

(defun harness-quick-search--redraw (&optional popout)
  "Draw the quick search's POPOUT again, by default this buffer."
  (with-current-buffer (or popout (current-buffer))
    (when (eq (current-buffer) (harness-ui-popout-buffer harness-quick-search--key))
      (harness-ui-popout-refresh harness-quick-search--key))))

(defun harness-quick-search--update (popout seq &rest changes)
  "Merge CHANGES into the search SEQ of POPOUT, and draw it; nil when it is gone.
A search the popout dropped, or one asked before its latest, is left
alone."
  (when (buffer-live-p popout)
    (with-current-buffer popout
      (when (and harness-quick-search--state (eql seq harness-quick-search--seq))
        (let ((state (copy-sequence harness-quick-search--state)))
          (cl-loop for (k v) on changes by #'cddr do (setq state (plist-put state k v)))
          (setq harness-quick-search--state state))
        (harness-quick-search--redraw)
        t))))

(defun harness-quick-search--warm ()
  "Have the harness start the model of this popout's next search now.
It also says which model answers, which the popout names while it asks."
  (let ((popout (current-buffer))
        (project (or (plist-get harness-quick-search--context :project) default-directory)))
    (harness-ui-call "_harness/search/warm" (list :cwd project)
                     (lambda (reply)
                       (when (and (buffer-live-p popout) (stringp (plist-get reply :model)))
                         (with-current-buffer popout
                           (setq harness-quick-search--model (plist-get reply :model))
                           (when (eq 'searching (plist-get harness-quick-search--state :status))
                             (harness-quick-search--redraw)))))
                     #'ignore)))

(defun harness-quick-search--search (query &optional bias)
  "Ask the search model about QUERY, from this popout, favouring BIAS.
BIAS is \"tasks\", \"sessions\" or \"commands\"; by default what the
place the search was opened from suggests (`harness-quick-search-bias')."
  (let ((query (string-trim (or query ""))))
    (if (string-empty-p query)
        (message "Say what to find: a session, a command or a task")
      (add-to-history 'harness-quick-search-history query)
      (let* ((popout (current-buffer))
             (seq (cl-incf harness-quick-search--seq))
             (context (or harness-quick-search--context (harness-quick-search-context)))
             (bias (or bias (harness-quick-search-bias context)))
             (catalogue (or harness-quick-search--catalogue (harness-quick-search-commands))))
        (setq harness-quick-search--state
              (list :query query :seq seq :status 'searching :bias bias :model harness-quick-search--model))
        (harness-quick-search--redraw)
        (harness-ui-call "_harness/search/ask"
                         (list :cwd (or (plist-get context :project) default-directory)
                               :query query
                               :opts (list :bias bias :context context :commands catalogue))
                         (lambda (plan) (harness-quick-search--arrived popout seq plan))
                         (lambda (err)
                           (harness-quick-search--update popout seq :status 'failed
                                                         :error (harness-error-message err))))))))

(defun harness-quick-search--arrived (popout seq plan)
  "Show PLAN, the answer to the search SEQ of POPOUT."
  (harness-quick-search--update popout seq :status 'done :plan plan
                                :model (or (plist-get plan :model)
                                           (plist-get (buffer-local-value 'harness-quick-search--state popout) :model))
                                :proposed (plist-get plan :actions) :running nil :results nil))

(defun harness-quick-search--do (popout seq actions)
  "Do ACTIONS, which the search SEQ of POPOUT proposes; then say how they went."
  (when (harness-quick-search--update popout seq :proposed nil :running actions)
    (harness-ui-call "_harness/task/search-apply" (list :actions actions)
                     (lambda (results)
                       (harness-quick-search--update popout seq :running nil :results results)
                       (message "%s" (harness-quick-search--done-text results)))
                     (lambda (err)
                       (harness-quick-search--update
                        popout seq :running nil
                        :results (mapcar (lambda (a) (append a (list :ok :false :error (harness-error-message err))))
                                         actions))))))

(defun harness-quick-search--submit (text _attachments)
  "Search TEXT, which the popout's box sent; it stays in the box."
  (harness-quick-search--put text)
  (harness-quick-search--search text))

(defun harness-quick-search--open (query)
  "Open the quick search's popout from this buffer; with QUERY, search it."
  (let* ((existing (harness-ui-popout-buffer harness-quick-search--key))
         (inside (and existing (eq existing (current-buffer))))
         (origin (if inside harness-quick-search--origin (current-buffer)))
         (window (if inside harness-quick-search--origin-window (selected-window)))
         (context (harness-quick-search-context))
         (catalogue (harness-quick-search-commands))
         (moved (and existing (not (eq origin (buffer-local-value 'harness-quick-search--origin existing)))))
         (popout (harness-ui-popout-show harness-quick-search--key "Quick search" #'harness-quick-search--render
                                         :compose (lambda () #'harness-quick-search--submit)
                                         :placeholder "Find a session, a command or a task…"
                                         :dir (plist-get context :project))))
    (with-current-buffer popout
      (setq harness-quick-search--origin origin
            harness-quick-search--origin-window window
            harness-quick-search--context context
            harness-quick-search--catalogue catalogue)
      (unless harness-quick-search-box-mode (harness-quick-search-box-mode 1))
      (setq harness-quick-search-box-function #'harness-quick-search--search)
      (when (or (not existing) moved)
        ;; A search of another place is not this one's: an answer still
        ;; on its way is dropped.
        (cl-incf harness-quick-search--seq)
        (setq harness-quick-search--state (list :status 'idle :seq harness-quick-search--seq))
        ;; The box kept from last time holds a line searched already,
        ;; which M-p brings back: it starts empty.
        (when (and (not existing)
                   (equal (string-trim (harness-compose-text)) (car harness-quick-search-history)))
          (harness-compose-set "")))
      (harness-quick-search--redraw)
      (harness-quick-search--warm)
      (when query (harness-quick-search--put query))
      (when (harness-compose-live-p) (goto-char harness-compose-end))
      (when-let* ((w (get-buffer-window popout)))
        (set-window-point w (point)))
      (when query (harness-quick-search--search query)))
    popout))

;;;###autoload
(defun harness-quick-search (&optional query)
  "Find a session, a command or a task, from anywhere, by saying what you want.
A popout opens at the bottom of the frame, with a box to type a line in
words: \"how do I attach a file?\", \"where did I debug the merge
queue?\", \"the task about the docs\".  \\`RET' there sends it, with where it
was typed and the harness's commands, to a quick, cheap model
\(`harness-tasks-search-model'), and the popout lists the commands,
sessions and tasks it found, with buttons: [Run] runs a command in the
buffer the search was opened from, [Open] opens a session, [Board]
shows a task on its board.  The line stays in the box, to be refined;
\\`M-p' and \\`M-n' bring back earlier searches.

What the search favours depends on where it was opened: commands, then
sessions, in most buffers; sessions in the session list and a
conversation tree.  [Search sessions] and [Search commands] ask again
favouring those.  On a task board this is the board's own search
\(`harness-tasks-search'), which filters the board.  With QUERY, from
Lisp, the search starts at once."
  (interactive)
  (if (and (derived-mode-p 'harness-ui-tasks-mode) (fboundp 'harness-tasks-search))
      (if query
          (harness-tasks-search query)
        (call-interactively #'harness-tasks-search))
    (harness-quick-search--open query)))

;;;; Module

(defun harness-quick-search--menu-command ()
  "Return the command of the / suffix of `harness-menu', or nil."
  (when-let* ((suffix (ignore-errors (transient-get-suffix 'harness-menu "/"))))
    (plist-get (harness-quick-search--suffix-plist suffix) :command)))

(defun harness-quick-search--init ()
  "Bind the quick search to / under the prefix and in the harness menu."
  (clrhash harness-quick-search--catalogues)
  (define-key harness-ui-map (kbd "/") #'harness-quick-search)
  (ignore-errors
    (when (ignore-errors (transient-get-suffix 'harness-menu "/"))
      (ignore-errors (transient-remove-suffix 'harness-menu "/")))
    (transient-append-suffix 'harness-menu "a" '("/" "Quick search" harness-quick-search))))

(defun harness-quick-search--shutdown ()
  "Take the quick search off / under the prefix and out of the harness menu."
  (when (eq (lookup-key harness-ui-map (kbd "/")) #'harness-quick-search)
    (define-key harness-ui-map (kbd "/") nil t))
  (ignore-errors
    (when (eq (harness-quick-search--menu-command) 'harness-quick-search)
      (transient-remove-suffix 'harness-menu "/")))
  (clrhash harness-quick-search--catalogues))

(harness-define-module 'ui-quick-search
  :doc "The quick search: find a session, a command or a task from anywhere, answered by a cheap model."
  :requires '(ui ui-popout)
  :init #'harness-quick-search--init
  :shutdown #'harness-quick-search--shutdown)

(provide 'harness-ui-quick-search)
;;; harness-ui-quick-search.el ends here
