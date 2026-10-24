;;; harness-ui-version.el --- The version page: is the running harness the latest?  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-version' (C-c h v) answers "are we running the latest
;; changes?".  It shows one row per place a version lives:
;;
;; - Running: the commit the harness process runs, and the commit this
;;   Emacs loaded the UI from when they differ;
;; - Checkout: the checkout the harness was loaded from as it is now,
;;   with [Reload] beside it -- the action that loads what the checkout
;;   holds;
;; - Remote: the repository the checkout pulls from (sourcehut, GitHub,
;;   whichever the package manager's recipe named), with [Update] beside
;;   it -- the action that pulls its commits and reloads.
;;
;; A development checkout of the harness, such as a session's main
;; checkout with commits not pushed yet, has a row of its own under
;; Development.  It is compared with, but the running harness cannot be
;; updated from it, so it does not make the harness behind: [Update]
;; would change nothing there.
;;
;; The commits a row is missing are shown as changelog entries under
;; Recent commits: their subject and message body, never a diff or file
;; statistics.  The plugins the running harness has -- the libraries
;; under lisp/vendor and the project plugins loaded from a project's
;; directory-local variables -- get a row each under Plugins, with their
;; `Version:' header, their status and the same [Update] action.  A
;; plugin in the harness's checkout is updated with the harness; one in
;; a project's own checkout is fast-forwarded there, and a restart loads
;; it.
;;
;; The page's copy is nouns and imperatives: a status ("current", "12
;; commits to pull"), an action ([Reload], [Update], [Check now]).  What
;; an update brought is under Last update, a plugin's own under Last
;; plugin update, and a reload that was refused or failed -- or a plugin
;; that now needs loading -- offers [Restart].
;;
;; The checks run in the background, in the harness process.  The page
;; shows the last report at once and asks for a fresh one only when it
;; is more than a minute old, so opening it never waits on git or the
;; network; `g' checks again.  Reports the harness makes on its own,
;; after it starts or reloads and every half hour, redraw the page as
;; they come, and the harness menu's Version entry says when the last
;; one found the harness behind.
;;
;; So does a small icon, an arrow up in a circle, in the places
;; `harness-ui-version-nag-places' names: the mode line notifier, after
;; its "harness", and the header lines of chats and the task board.  It
;; nags while the last report found the harness behind, and goes as
;; soon as the harness reloads, to come back only if the check the
;; harness makes a few seconds later finds it behind still.  Hovering
;; names the origins with commits the harness lacks, and a click opens
;; the page, which says what to do.  A UI connecting to a harness asks
;; it for its last report (`version/report', which checks nothing), so
;; the icon shows at once rather than at the next check.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-revision)
(require 'harness-ui)

(defvar harness-version)
(defvar harness-directory)
(defvar harness-notify-mode)
(defvar harness--last-update)
(defvar harness--last-plugin-update)
(defvar harness--updating)
(defvar harness-update-hook)
(declare-function harness-reload "harness")
(declare-function harness-update "harness")
(declare-function harness-update-plugin "harness" (dir name))
(declare-function harness--straight-package "harness")
(declare-function harness-ui-notify-refresh "harness-ui-notify")

(defface harness-version-heading-face '((t :inherit bold :height 1.05))
  "Headings of the version page." :group 'harness-ui)

(harness-ui-define-icon harness-icon-update "update" "↑" "update"
                        "Not the latest: the harness has a newer version to run.")

(defcustom harness-ui-version-nag-places '(mode-line chat-header board-header)
  "Where a small icon nags while the harness is not the latest.
The icon, an arrow up in a circle, shows once a check of the running
harness against its origins (see `harness-version') finds one with
commits the harness lacks.  The harness checks by itself shortly after
it starts or reloads and every half hour.  The icon goes as soon as the
harness reloads, and comes back only if the check after the reload
finds the harness behind still.  Hovering over it names the origins
with commits the harness lacks, and a click shows the version page,
which says what to do.  A list of:

- `mode-line': in the mode line notifier, after its \"harness\",
  visible from any buffer (`harness-notify-mode'); the notifier then
  shows even when no session is active;
- `chat-header': in each chat's header line, before [menu];
- `board-header': in the task board's header line.

nil shows it nowhere; the harness menu's Version entry still says
\"not the latest\"."
  :type '(set (const :tag "The mode line notifier" mode-line)
              (const :tag "Chat header lines" chat-header)
              (const :tag "The task board's header line" board-header))
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'harness-ui-version--nag-changed) (harness-ui-version--nag-changed t)))
  :group 'harness-ui)

(defconst harness-ui-version--buffer-name "*harness version*"
  "Name of the version page's buffer.")

(defconst harness-ui-version--max-age 60
  "Seconds a report stays fresh enough for an opened page not to check again.
Opening the page twice in a row asks git and the network once.")

(defconst harness-ui-version--patience 120
  "Seconds the page waits for a check it asked for before it may ask again.
The harness gives up on git well before; this covers a request lost
with its connection.")

(defconst harness-ui-version--indent 22
  "Column where an entry's details start, under its commit.")

(defconst harness-ui-version--body-lines 12
  "How many lines of a commit's message body the page shows.")

(defvar harness-ui-version--report nil
  "The last report from the harness, for the page and the menu.")

(defvar harness-ui-version--checking nil
  "When the page asked for the check it waits for (float seconds), or nil.")

(defvar harness-ui-version--error nil
  "Why the last check the page asked for failed, or nil.")

(defvar harness-ui-version--waiting-for nil
  "The revision promise of this Emacs the page waits on, or nil.")

(defvar harness-ui-version--reloaded nil
  "Non-nil when the harness reloaded since the last report.
The report is about the commit that ran before; the harness checks again
a few seconds after a reload.")

(defvar harness-ui-version--nag-shown nil
  "Whether the nag icon showed when its places were last redrawn for it.")

(defconst harness-ui-version--nag-priority 65
  "How long the nag icon stays in a narrow header line.
As `harness-ui-fit-header' takes it: the icon makes room after a chat's
model and todos and the board's counts, and before a chat's name and
the board's spend.")

;;;; Helpers

(defun harness-ui-version--buffers ()
  "Return the live version pages."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-version-mode)))
                    (buffer-list)))

(defun harness-ui-version--true (plist key)
  "Non-nil when KEY of PLIST is true."
  (harness-json-true-p (plist-get plist key)))

(defun harness-ui-version--short (commit)
  "Return COMMIT shortened to seven characters."
  (if (and (stringp commit) (> (length commit) 7)) (substring commit 0 7) (or commit "")))

(defun harness-ui-version--commits (n)
  "Return \"N commit\" or \"N commits\"."
  (format "%d commit%s" n (if (eql n 1) "" "s")))

(defun harness-ui-version--status-in (origins &rest statuses)
  "Return the ORIGINS whose status is one of STATUSES."
  (cl-remove-if-not (lambda (o) (member (plist-get o :status) statuses)) origins))

(defun harness-ui-version--of-kind (origins kind)
  "Return the ORIGINS of KIND."
  (cl-remove-if-not (lambda (o) (equal (plist-get o :kind) kind)) origins))

(defun harness-ui-version--width ()
  "Return the width the page is drawn for: its window's, never less than 40."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 40 (1- (if window (window-width window) 100)))))

(defun harness-ui-version--ago (time)
  "Return TIME (float seconds) relative to now, or \"\"."
  (if (numberp time) (harness-relative-time time) ""))

(defun harness-ui-version--separate-p ()
  "Non-nil when the harness runs in another Emacs than this UI."
  (and harness-ui-connection-address t))

(defun harness-ui-version--reloadable-p ()
  "Non-nil when `harness-reload' reloads the harness the page shows."
  (memq harness-ui-connection-address '(nil process)))

(defun harness-ui-version--ui-revision ()
  "Return the revision this Emacs loaded the UI from, when known.
Otherwise wait for it in the background and redraw the pages then."
  (let ((promise (harness-revision-loaded)))
    (cond ((harness-promise-settled-p promise) (harness-promise-value promise))
          ((eq promise harness-ui-version--waiting-for) nil)
          (t (setq harness-ui-version--waiting-for promise)
             (harness-then promise (lambda (_)
                                     (setq harness-ui-version--waiting-for nil)
                                     (harness-ui-version--redraw-all)
                                     nil))
             nil))))

(defun harness-ui-version--straight-package ()
  "Return the straight.el package name of this harness, or nil.
See `harness--straight-package', which the update command uses too."
  (harness--straight-package))

(defun harness-ui-version--checking-p ()
  "Non-nil while the page waits for a check it asked for."
  (and harness-ui-version--checking
       (< (- (float-time) harness-ui-version--checking) harness-ui-version--patience)))

;;;; Updating

(defun harness-ui-version--updating-p ()
  "Non-nil while `harness-update' runs in this Emacs."
  (and (boundp 'harness--updating) harness--updating))

(defun harness-ui-version--last-update ()
  "The last update's outcome, when this Emacs made one, else nil."
  (and (boundp 'harness--last-update) harness--last-update))

(defun harness-ui-version-update ()
  "Update the harness from its checkout, as `harness-update' does.
The checkout is updated the way it was installed -- straight.el's own
pull for a straight.el install -- checked, and reloaded.  The page asks
for a fresh report when it settles."
  (interactive)
  (unless (harness-ui-version--reloadable-p)
    (user-error "The harness runs elsewhere; update it where it runs"))
  (when (harness-ui-version--updating-p)
    (user-error "The harness is updating already"))
  (harness-update)
  (harness-ui-version--redraw-all))

(defun harness-ui-version-update-plugin (plugin)
  "Update PLUGIN's own checkout, then redraw the page.
PLUGIN is one the report made: its directory is the plugin's, and the
checkout that owns it is fast-forwarded.  The plugin's code loads once
per process, so a restart runs the new version."
  (interactive)
  (harness-update-plugin (plist-get plugin :directory) (plist-get plugin :name))
  (harness-ui-version--redraw-all))

;;;; Rendering

(defconst harness-ui-version--label-column 16
  "Width of the name column of a row.")

(defconst harness-ui-version--commit-column 9
  "Width of the commit or version column of a row.")

(defconst harness-ui-version--status-column 28
  "Width of the status column of a row without an action.
A row with one takes 24, enough for its status and its button, and
leaves the rest to where the origin is.")

(defconst harness-ui-version--action-column 10
  "Width the action of a row takes, when it has one.")

(defconst harness-ui-version--stat-line-regexp
  (rx line-start (or (seq (+ digit) " file" (optional "s") " changed")
                     (seq (+ digit) " insertion" (optional "s") "(")
                     (seq (+ digit) " deletion" (optional "s") "(")
                     (seq (+ digit) " insertion" (optional "s") ", ")
                     (seq (+ digit) " deletion" (optional "s") ", ")))
  "A line of a commit message that is file statistics, not changelog.
An update or a commit message written by an agent often ends with
\"8 files changed, 196 insertions(+), 44 deletions(-)\"; the page shows
the change-log message, never the statistics.")

(defun harness-ui-version--headline ()
  "Return (LEVEL . TEXT) for the last report: a noun, never a sentence."
  (let ((report harness-ui-version--report))
    (cond
     ((null report) (cons 'caution "Checking"))
     (t (pcase (plist-get report :verdict)
          ("latest" (cons 'success "Latest"))
          ("behind" (cons 'caution "Not latest"))
          (_ (cons 'caution "Unknown")))))))

(defun harness-ui-version--header ()
  "Return the header line: the harness's version and the verdict."
  (let ((report harness-ui-version--report)
        (headline (harness-ui-version--header-headline)))
    (list (propertize " Harness " 'face 'harness-version-heading-face)
          (propertize (format "%s " (or (plist-get report :version)
                                        (and (boundp 'harness-version) harness-version)
                                        ""))
                      'face 'harness-dim-face)
          (propertize (cdr headline)
                      'face (if (eq (car headline) 'success)
                                'harness-success-face
                              (if (eq (car headline) 'failure)
                                  'harness-failure-face 'harness-caution-face))))))

(defun harness-ui-version--header-headline ()
  "Return (LEVEL . TEXT) for the header line.
A check in flight or a failed one is what the header says, so a stale
verdict is not mistaken for the state now."
  (cond ((harness-ui-version--checking-p) (cons 'caution "Checking"))
        (harness-ui-version--error (cons 'failure "Check failed"))
        (t (harness-ui-version--headline))))

(defun harness-ui-version--status-text (origin role)
  "Return what ORIGIN's status says, for a row of ROLE.
ROLE is `checkout' or `remote'; each has the words its action changes."
  (let ((missing (or (plist-get origin :missing) 0))
        (extra (or (plist-get origin :extra) 0)))
    (pcase (plist-get origin :status)
      ((or "same" (pred null)) "current")
      ("newer" (format "%s to %s" (harness-ui-version--commits missing)
                       (if (eq role 'checkout) "load" "pull")))
      ("older" (format "%s ahead" (harness-ui-version--commits extra)))
      ("diverged" (format "%s to pull, %d to push" (harness-ui-version--commits missing) extra))
      ("ahead" "not fetched")
      ("untracked" "no remote")
      ("unknown" "unknown")
      ("error" (or (plist-get origin :error) "unreadable"))
      (_ ""))))

(defun harness-ui-version--status-level (origin)
  "Return how ORIGIN's status looks: `success', `caution' or `failure'."
  (pcase (plist-get origin :status)
    ((or "same" "older" (pred null)) 'success)
    ("error" 'failure)
    (_ 'caution)))

(defun harness-ui-version--origin-location (origin)
  "Return where ORIGIN is and its branch, for its row."
  (let ((location (or (plist-get origin :location) ""))
        (branch (plist-get origin :branch)))
    (concat (if (equal (plist-get origin :kind) "remote")
                location
              (abbreviate-file-name (directory-file-name location)))
            (if branch (format " (%s" branch) "")
            (if (harness-ui-version--true origin :dirty)
                (if branch ", uncommitted)" " (uncommitted)")
              (if branch ")" "")))))

(defun harness-ui-version--fit-location (location room)
  "Return LOCATION fitted to ROOM columns, keeping its end.
The branch in parentheses goes first when something must: it says less
than the repository's name.  A longer location loses its middle, so
the checkout or repository it names is still readable."
  (let ((location (if (<= (length location) room)
                      location
                    (replace-regexp-in-string " ([^()]*)\\'" "" location))))
    (if (<= (length location) room)
        location
      (harness-truncate-middle location room))))

(defun harness-ui-version--insert-row (label level value status action location)
  "Insert one row: LABEL, LEVEL's icon, VALUE, STATUS, ACTION, LOCATION.
ACTION inserts a button, or is nil.  STATUS and LOCATION are cut to
what the window has left, so a narrow page keeps its buttons whole."
  (let* ((width (harness-ui-version--width))
         (action-width (if action harness-ui-version--action-column 0))
         (status-max (if action 24 harness-ui-version--status-column))
         (status-width (min status-max
                            (max 10 (- width 1 (1- harness-ui-version--label-column)
                                       3 harness-ui-version--commit-column action-width 2))))
         (prefix (concat " "
                         (string-pad (harness-truncate-end label (1- harness-ui-version--label-column))
                                     (1- harness-ui-version--label-column))
                         " " (if level (harness-ui-level-icon level) " ") " "
                         (string-pad (harness-truncate-end (or value "") harness-ui-version--commit-column)
                                     harness-ui-version--commit-column)
                         (propertize
                          (string-pad (harness-truncate-end status status-width)
                                      status-width)
                          'face (if (eq level 'success) 'default (harness-ui-level-face level)))))
         (room (- width (length prefix) action-width 2)))
    (insert prefix)
    (when action
      (funcall action))
    (when (>= room 8)
      (insert (propertize (harness-ui-version--fit-location location room)
                          'face 'harness-dim-face)))
    (insert "\n")))

(defun harness-ui-version--commit-line (commit subject date width prefix)
  "Return COMMIT's line: short hash, SUBJECT and DATE, fitted to WIDTH.
PREFIX is how many columns the caller used before it."
  (let* ((ago (harness-ui-version--ago date))
         (room (max 10 (min 64 (- width prefix 7 2 1 (length ago))))))
    (concat (propertize (harness-ui-version--short commit) 'face 'harness-label-face) "  "
            (string-pad (harness-truncate-end (or subject "") room) room)
            (propertize (format " %s" ago) 'face 'harness-dim-face))))

(defun harness-ui-version--insert-paragraph (text indent width)
  "Insert TEXT as one filled paragraph at INDENT, then a newline."
  (let ((start (point))
        (prefix (make-string indent ?\s)))
    (insert prefix text "\n")
    (let ((fill-column width) (fill-prefix prefix))
      (fill-region start (point)))))

(defun harness-ui-version--insert-body (body width)
  "Insert BODY, a commit message's body, as changelog lines.
File statistics are left out; at most `harness-ui-version--body-lines'
lines are shown."
  (let* ((lines (cl-remove-if
                 (lambda (line)
                   (or (string-empty-p line)
                       (string-match-p harness-ui-version--stat-line-regexp line)))
                 (mapcar #'string-trim (split-string (or body "") "\n"))))
         (shown (cl-subseq lines 0 (min (length lines) harness-ui-version--body-lines))))
    (dolist (line shown)
      (harness-ui-version--insert-paragraph (propertize line 'face 'harness-dim-face) 8 width))
    (when (> (length lines) harness-ui-version--body-lines)
      (harness-ui-version--insert-paragraph (propertize "…" 'face 'harness-dim-face) 8 width))))

(defun harness-ui-version--insert-commits (commits more width)
  "Insert COMMITS, then a line for MORE commits not listed; fit WIDTH.
A commit is its changelog message: its subject, and its body under it.
No diff or file statistics are shown."
  (dolist (commit commits)
    (insert "    "
            (harness-ui-version--commit-line (plist-get commit :commit)
                                             (plist-get commit :subject)
                                             (plist-get commit :date) width 4)
            "\n")
    (harness-ui-version--insert-body (plist-get commit :body) width))
  (when (> more 0)
    (harness-ui-version--insert-paragraph
     (propertize (format "and %d more" more) 'face 'harness-dim-face) 8 width)))

(defun harness-ui-version--reload-action ()
  "Return the action reloading the harness, or nil when this Emacs cannot."
  (and (harness-ui-version--reloadable-p)
       (not (harness-ui-version--updating-p))
       (plist-get (plist-get harness-ui-version--report :running) :commit)
       (lambda () (harness-reload))))

(defun harness-ui-version--update-action ()
  "Return the action updating the harness, or nil while one runs.
A harness loaded from no git checkout has nothing to update."
  (and (harness-ui-version--reloadable-p)
       (plist-get (plist-get harness-ui-version--report :running) :commit)
       (not (harness-ui-version--updating-p))
       #'harness-ui-version-update))

(defun harness-ui-version--insert-actions (action label &optional help)
  "Insert ACTION's button labelled LABEL, or a blank of the same width.
HELP is its tooltip."
  (if action
      (progn
        (harness-ui-button (concat "[" label "]") action
                           :help (or help (format "%s the harness" label)))
        (insert (make-string (- harness-ui-version--action-column 2 (length label)) ?\s)))
    (insert (make-string harness-ui-version--action-column ?\s))))

(defun harness-ui-version--insert-running (report)
  "Insert what REPORT says runs: the harness process's commit, and this Emacs's."
  (let* ((running (plist-get report :running))
         (commit (plist-get running :commit))
         (width (harness-ui-version--width)))
    (insert " " (string-pad "Running" (1- harness-ui-version--label-column)) "   ")
    (insert (if commit
                (harness-ui-version--commit-line commit (plist-get running :subject)
                                                 (plist-get running :date) width
                                                 (+ 1 (1- harness-ui-version--label-column) 3))
              (format "version %s, no git checkout" (plist-get report :version)))
            "\n")
    (when (harness-ui-version--separate-p)
      (let ((ui (harness-ui-version--ui-revision))
            (same (plist-get running :commit)))
        (cond
         ((and ui (plist-get ui :commit))
          (let ((equal-p (equal (plist-get ui :commit) same)))
            (insert " " (make-string (1- harness-ui-version--label-column) ?\s) "   "
                    (propertize (format "this Emacs %s, %s"
                                        (harness-ui-version--short (plist-get ui :commit))
                                        (harness-ui-version--ago (plist-get ui :loaded)))
                                'face (if equal-p 'harness-dim-face 'harness-caution-face))
                    "\n"))))))))

(defun harness-ui-version--insert-checkout (report)
  "Insert the row of the checkout REPORT was loaded from, and its action."
  (let* ((origins (plist-get report :origins))
         (loaded (cl-find-if (lambda (o) (equal (plist-get o :kind) "loaded")) origins))
         (running (plist-get report :running))
         (status (if loaded (harness-ui-version--status-text loaded 'checkout)
                   (if (plist-get running :error) "no git checkout" "unknown")))
         (level (if loaded (harness-ui-version--status-level loaded) 'caution)))
    (harness-ui-version--insert-row
     "Checkout" level
     (harness-ui-version--short (or (plist-get loaded :commit) (plist-get running :commit)))
     status
     (lambda () (harness-ui-version--insert-actions (harness-ui-version--reload-action) "Reload" "Reload the checkout"))
     (if loaded (harness-ui-version--origin-location loaded)
       (or (plist-get running :error) "")))))

(defun harness-ui-version--insert-remote (report)
  "Insert the row of the repository the checkout pulls from, and its action."
  (let* ((origins (plist-get report :origins))
         (remote (cl-find-if (lambda (o) (eq (plist-get o :upstream) t)) origins))
         (others (cl-remove-if-not (lambda (o)
                                     (and (equal (plist-get o :kind) "remote")
                                          (not (eq (plist-get o :upstream) t))))
                                   origins)))
    (if remote
        (if (harness-ui-version--updating-p)
            (harness-ui-version--insert-row
             "Remote" 'caution (harness-ui-version--short (plist-get remote :commit)) "Updating…" nil
             (harness-ui-version--origin-location remote))
          (harness-ui-version--insert-row
           "Remote" (harness-ui-version--status-level remote)
           (harness-ui-version--short (plist-get remote :commit))
           (harness-ui-version--status-text remote 'remote)
           (lambda () (harness-ui-version--insert-actions (harness-ui-version--update-action) "Update" "Pull and reload the harness"))
           (harness-ui-version--origin-location remote)))
      (harness-ui-version--insert-row
       "Remote" 'caution "" "no remote" nil
       (or (plist-get (plist-get report :running) :error) "")))
    (harness-ui-version--insert-origins others "Remote")))

(defun harness-ui-version--insert-origins (origins label)
  "Insert the other ORIGINS under LABEL, with their status and location.
These are checkouts the running harness cannot be updated from; LABEL
is nil to name each row after its origin."
  (dolist (origin origins)
    (harness-ui-version--insert-row
     (or label
         (let ((name (plist-get origin :name)))
           (if (member name '(nil "local"))
               (file-name-nondirectory (directory-file-name (or (plist-get origin :location) "")))
             name))
         "Checkout")
     (harness-ui-version--status-level origin)
     (harness-ui-version--short (plist-get origin :commit))
     (let ((status (plist-get origin :status)))
       (pcase status
         ((or "same" (pred null)) "current")
         ("newer" (let ((unpushed (plist-get origin :unpushed)))
                    (if (and (numberp unpushed) (zerop unpushed))
                        "pushed"
                      (format "%s to push" (harness-ui-version--commits
                                            (or unpushed (plist-get origin :missing) 0))))))
         ("older" (format "%s ahead" (harness-ui-version--commits
                                      (or (plist-get origin :extra) 0))))
         ("diverged" (format "%s to pull, %d to push"
                             (harness-ui-version--commits (or (plist-get origin :missing) 0))
                             (or (plist-get origin :extra) 0)))
         ("ahead" "not fetched")
         ("unknown" "unknown")
         ("error" (or (plist-get origin :error) "unreadable"))
         (_ "")))
     nil
     (harness-ui-version--origin-location origin))))

(defun harness-ui-version--insert-development (report)
  "Insert the development checkouts of REPORT, under their own heading."
  (let ((dev (cl-remove-if
              (lambda (o)
                (or (equal (plist-get o :kind) "loaded")
                    (eq (plist-get o :upstream) t)
                    (equal (plist-get o :kind) "remote")))
              (plist-get report :origins))))
    (when dev
      (insert "\n " (propertize "Development" 'face 'harness-version-heading-face) "\n")
      (harness-ui-version--insert-origins dev nil))))

(defun harness-ui-version--plugin-status (plugin)
  "Return (LEVEL . TEXT) for PLUGIN's status."
  (let ((status (plist-get plugin :status))
        (missing (plist-get plugin :missing))
        (extra (plist-get plugin :extra)))
    (pcase status
      ((or "same" (pred null)) (cons 'success "current"))
      ("newer" (cons 'caution (format "%s to pull" (harness-ui-version--commits (or missing 0)))))
      ("older" (cons 'success (format "%s ahead" (harness-ui-version--commits (or extra 0)))))
      ("diverged" (cons 'caution "diverged"))
      ("ahead" (cons 'caution "not fetched"))
      ("untracked" (cons 'caution "no remote"))
      ("error" (cons 'failure (or (plist-get plugin :error) "unreadable")))
      (_ (cons 'caution "unknown")))))

(defun harness-ui-version--plugin-action (plugin)
  "Return the action that updates PLUGIN, or nil.
A plugin in the harness's checkout is updated with the harness; one in
a project's own checkout is fast-forwarded there, and a restart loads it."
  (let ((checkout (plist-get plugin :checkout))
        (running (plist-get (plist-get harness-ui-version--report :running) :directory)))
    (cond
     ((null checkout) nil)
     ((and (stringp checkout)
           (harness-revision--same-directory-p checkout (or running harness-directory)))
      (harness-ui-version--update-action))
     ((harness-ui-version--reloadable-p)
      (lambda () (harness-ui-version-update-plugin plugin))))))

(defun harness-ui-version--insert-plugins (report)
  "Insert REPORT's plugins: version, status and action, one row each."
  (when-let* ((plugins (plist-get report :plugins)))
    (insert "\n " (propertize "Plugins" 'face 'harness-version-heading-face) "\n")
    (dolist (plugin plugins)
      (let* ((status (harness-ui-version--plugin-status plugin))
             (commit (plist-get plugin :commit))
             (version (or (plist-get plugin :version)
                          (and commit (harness-ui-version--short commit))
                          "—")))
        (harness-ui-version--insert-row
         (or (plist-get plugin :name) "plugin")
         (car status)
         version
         (cdr status)
         (lambda () (harness-ui-version--insert-actions
                     (harness-ui-version--plugin-action plugin) "Update"
                     (format "Update %s" (plist-get plugin :name))))
         (file-relative-name (or (plist-get plugin :directory) "")
                             (or (plist-get (plist-get report :running) :directory)
                                 harness-directory)))))))

(defun harness-ui-version--update-text (result)
  "Return a noun phrase for RESULT, the last update's outcome."
  (pcase (plist-get result :state)
    ("updated" (let ((from (plist-get result :from))
                     (to (plist-get result :to))
                     (count (or (plist-get result :count) 0)))
                 (if (zerop count)
                     (format "Reloaded %s" to)
                   (format "Updated %s → %s (%d commit%s)" from to count
                           (if (= count 1) "" "s")))))
    ("up-to-date" (format "Current (%s)" (or (plist-get result :to) "")))
    ("failed" (format "Failed: %s" (or (plist-get result :error)
                                       (plist-get result :message) "")))
    (_ (or (plist-get result :message) ""))))

(defun harness-ui-version--restart-action ()
  "Return the action restarting the harness process, when it needs one.
A harness reload that was refused or failed needs one, and so does a
plugin update: plugins load once per process."
  (when (and (eq harness-ui-connection-address 'process)
             (or (let ((result (harness-ui-version--last-update)))
                   (and result
                        (pcase (plist-get result :state)
                          ("updated" (let ((reload (plist-get result :reload)))
                                       (and reload (or (plist-get reload :refused)
                                                       (plist-get reload :errors)))))
                          (_ nil))))
                 (let ((result (and (boundp 'harness--last-plugin-update)
                                    harness--last-plugin-update)))
                   (and result (equal (plist-get result :state) "updated")))))
    (lambda () (harness-restart))))

(defun harness-ui-version--insert-update (width)
  "Insert the last update's outcome and its changelog, fitted to WIDTH.
The actions are on the rows they change; this is the outcome, and the
restart prompt a failed reload needs."
  (when-let* ((result (harness-ui-version--last-update)))
    (let ((text (harness-ui-version--update-text result))
          (age (harness-ui-version--ago (plist-get result :at)))
          (start (point)))
      (insert "\n " (propertize "Last update" 'face 'harness-version-heading-face)
              "  " (propertize text 'face (pcase (plist-get result :state)
                                             ("updated" 'harness-success-face)
                                             ("failed" 'harness-failure-face)
                                             (_ 'harness-dim-face)))
              (if (string-empty-p age) ""
                (propertize (format " · %s" age) 'face 'harness-dim-face)))
      (when-let* ((restart (harness-ui-version--restart-action)))
        (insert "  ")
        (harness-ui-button "[Restart]" restart :help "Restart the harness process"))
      (insert "\n")
      (let ((fill-column width) (fill-prefix " "))
        (fill-region start (point)))
      (when (equal (plist-get result :state) "updated")
        (let* ((commits (plist-get result :commits))
               (count (or (plist-get result :count) (length commits))))
          (harness-ui-version--insert-commits commits (- count (length commits)) width))))))

(defun harness-ui-version--insert-plugin-update ()
  "Insert the last plugin update's outcome, and its restart prompt."
  (when-let* ((result (and (boundp 'harness--last-plugin-update)
                           harness--last-plugin-update)))
    (let* ((name (or (plist-get result :name) "plugin"))
           (state (plist-get result :state))
           (from (plist-get result :from))
           (to (plist-get result :to))
           (age (harness-ui-version--ago (plist-get result :at)))
           (text (pcase state
                   ("updated" (format "%s %s → %s" name from to))
                   ("up-to-date" (format "%s current (%s)" name to))
                   ("failed" (format "%s failed: %s" name
                                     (or (plist-get result :error)
                                         (plist-get result :message) "")))
                   (_ (or (plist-get result :message) "")))))
      (insert "\n " (propertize "Last plugin update" 'face 'harness-version-heading-face)
              "  " (propertize text 'face (pcase state
                                             ("updated" 'harness-success-face)
                                             ("failed" 'harness-failure-face)
                                             (_ 'harness-dim-face)))
              (if (string-empty-p age) ""
                (propertize (format " · %s" age) 'face 'harness-dim-face)))
      (when-let* ((restart (harness-ui-version--restart-action)))
        (insert "  ")
        (harness-ui-button "[Restart]" restart :help "Restart the harness process"))
      (insert "\n"))))

(defun harness-ui-version--insert-recent (report width)
  "Insert the newest commits the harness lacks, as changelog entries."
  (let* ((version-origins (cl-remove-if-not #'harness-ui-version--version-origin-p
                                            (plist-get report :origins)))
         (newer (cl-remove-if-not (lambda (o)
                                    (member (plist-get o :status) '("newer" "diverged")))
                                  version-origins))
         (commits nil) (more 0))
    (dolist (origin newer)
      (let ((list (plist-get origin :missing-commits)))
        (dolist (commit list)
          (unless (cl-find (plist-get commit :commit) commits
                           :key (lambda (c) (plist-get c :commit)) :test #'equal)
            (push commit commits)))
        (setq more (+ more (max 0 (- (or (plist-get origin :missing) 0)
                                     (length list)))))))
    (when commits
      (insert "\n " (propertize "Recent commits" 'face 'harness-version-heading-face) "\n")
      (harness-ui-version--insert-commits (nreverse commits) more width))))

(defun harness-ui-version--redraw-all ()
  "Redraw every version page from the last report."
  (dolist (buf (harness-ui-version--buffers))
    (with-current-buffer buf (harness-ui-version--render))))

(defun harness-ui-version--render ()
  "Redraw the page from the last report, keeping the line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (report harness-ui-version--report)
        (width (harness-ui-version--width)))
    (erase-buffer)
    (setq header-line-format (harness-ui-version--header))
    (insert "\n")
    (if (null report)
        (progn
          (insert " "
                  (propertize (if (and harness-ui-version--error
                                       (not (harness-ui-version--checking-p)))
                                  (format "Check failed: %s" harness-ui-version--error)
                                "Checking…")
                              'face (if (and harness-ui-version--error
                                             (not (harness-ui-version--checking-p)))
                                        'harness-failure-face 'harness-dim-face))
                  "\n")
          (insert "\n")
          (harness-ui-version--insert-row
           "Checkout" 'caution "" "unknown" nil (abbreviate-file-name harness-directory))
          (harness-ui-version--insert-row "Remote" 'caution "" "unknown" nil ""))
      (let ((headline (harness-ui-version--headline)))
        (insert " " (harness-ui-level-icon (car headline)) " "
                (propertize (cdr headline)
                            'face (harness-ui-level-face (car headline)))
                "\n\n"))
      (harness-ui-version--insert-running report)
      (harness-ui-version--insert-checkout report)
      (harness-ui-version--insert-remote report)
      (harness-ui-version--insert-recent report width)
      (harness-ui-version--insert-development report)
      (harness-ui-version--insert-plugins report)
      (harness-ui-version--insert-update width)
      (harness-ui-version--insert-plugin-update))
    (insert "\n ")
    (when report
      (insert (propertize (format "Checked %s"
                                  (harness-ui-version--ago (plist-get report :checked)))
                          'face 'harness-dim-face)
              "  "))
    (if (harness-ui-version--checking-p)
        (insert (propertize "Checking…" 'face 'harness-dim-face))
      (harness-ui-button "[Check now]" #'harness-ui-version-refresh
                         :help "Check the origins again (g)"))
    (insert "\n")
    (when harness-ui-version--error
      (insert " " (propertize (format "Check failed: %s" harness-ui-version--error)
                              'face 'harness-failure-face)
              "\n"))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun harness-ui-version--version-origin-p (origin)
  "Non-nil when ORIGIN can give the running harness a new version.
The checkout it was loaded from and the repository that checkout pulls
from can; a development checkout elsewhere cannot."
  (or (equal (plist-get origin :kind) "loaded")
      (eq (plist-get origin :upstream) t)))

;;;; Talking to the harness

(defun harness-ui-version--take (report)
  "Keep REPORT, the harness's newest, and show it wherever it shows."
  (setq harness-ui-version--report report
        harness-ui-version--error nil
        harness-ui-version--reloaded nil)
  (harness-ui-version--redraw-all)
  (harness-ui-version--nag-changed))

(defun harness-ui-version--check (max-age)
  "Ask the harness for a report at most MAX-AGE seconds old; redraw on the answer.
The harness answers from its last report when that is fresh enough,
and otherwise checks in the background: the page shows the last report
meanwhile."
  (unless (harness-ui-version--checking-p)
    (let ((asked (float-time)))
      (setq harness-ui-version--checking asked)
      (harness-ui-version--redraw-all)
      (harness-then (harness-ui-request "_harness/version/check" (list :max-age max-age))
                    (lambda (report)
                      (when (eql harness-ui-version--checking asked)
                        (setq harness-ui-version--checking nil))
                      (harness-ui-version--take report)
                      nil)
                    (lambda (err)
                      (when (eql harness-ui-version--checking asked)
                        (setq harness-ui-version--checking nil))
                      (unless (harness-ui-connection-replaced-p err)
                        (setq harness-ui-version--error (harness-revision-error-message err)))
                      (harness-ui-version--redraw-all)
                      nil)))))

(defun harness-ui-version--fetch ()
  "Ask the harness for the last report it made, without a check.
So the nag icon shows as soon as the UI connects to a harness that
found itself behind, rather than at its next check, while a harness
just starting checks when it means to.  With no report yet, or from a
harness without `version/report', the icon waits for the next report
the harness announces."
  (harness-then (harness-ui-request "_harness/version/report" nil)
                (lambda (report)
                  ;; One announced meanwhile is newer.
                  (when (and (consp report) (null harness-ui-version--report))
                    (harness-ui-version--take report))
                  nil)
                #'ignore))

(defun harness-ui-version-behind-p ()
  "Non-nil when the harness is not the latest, as far as the UI knows.
That is, the last report found an origin with commits the harness
lacks, and the harness has not reloaded since: it may run them now."
  (and (not harness-ui-version--reloaded)
       (listp harness-ui-version--report)
       (equal (plist-get harness-ui-version--report :verdict) "behind")))

(defun harness-ui-version-menu-label ()
  "Return the harness menu's label for the version page.
It says so when the last report found the harness behind."
  (if (harness-ui-version-behind-p)
      (concat "Version " (propertize "(not the latest)" 'face 'harness-caution-face))
    "Version"))

;;;; The nag icon

(defun harness-ui-version--nag-help (&rest _)
  "The tooltip of the nag icon: which origins have commits the harness lacks.
A `help-echo' function, so it is worked out on hover only."
  (let ((newer (harness-ui-version--status-in (plist-get harness-ui-version--report :origins)
                                              "newer" "diverged" "ahead")))
    (harness-ui-one-line
     (format "Not latest: %s (mouse-1: open)"
             (or (mapconcat (lambda (o) (or (plist-get o :name) "origin")) newer ", ")
                 "unknown")))))

(defvar harness-ui-version--nag-map nil
  "Keymap of the nag icon: a click shows the version page.")

;; Made at top level, not in the `defvar', so a reload updates it.
(setq harness-ui-version--nag-map (harness-ui-mouse-keymap #'harness-version))

(defun harness-ui-version-nag ()
  "Return the nag icon while the harness is not the latest, else nil.
The icon in the caution face; hovering names the origins with commits
the harness lacks, and a click shows the version page.  Where it shows
is `harness-ui-version-nag-places'."
  (when (harness-ui-version-behind-p)
    ;; No `mouse-face': an image keeps the background it was drawn on,
    ;; which would show as a box.
    (propertize (harness-ui-icon 'harness-icon-update)
                'face 'harness-caution-face
                'help-echo #'harness-ui-version--nag-help
                'local-map harness-ui-version--nag-map)))

(defun harness-ui-version--nag-in (place)
  "Return the nag icon when it shows in PLACE now, else nil.
PLACE is one of `harness-ui-version-nag-places'."
  (and (memq place harness-ui-version-nag-places) (harness-ui-version-nag)))

(defun harness-ui-version--chat-header ()
  "The nag icon's segment of a chat's header line, or nil.
On `harness-chat-header-end-functions'."
  (when-let* ((nag (harness-ui-version--nag-in 'chat-header)))
    (list (concat "  " nag) harness-ui-version--nag-priority)))

(defun harness-ui-version--board-header ()
  "The nag icon's segment of the task board's header line, or nil.
On `harness-ui-tasks-header-functions'."
  (when-let* ((nag (harness-ui-version--nag-in 'board-header)))
    (list nag harness-ui-version--nag-priority)))

(defun harness-ui-version--notify-segment ()
  "The nag icon's segment of the mode line notifier, or nil.
On `harness-ui-notify-segment-functions'."
  (when-let* ((nag (harness-ui-version--nag-in 'mode-line)))
    (concat " " nag)))

(defun harness-ui-version--nag-changed (&optional force)
  "Redraw the places of the nag icon when it came or went, or when FORCE.
The header lines draw it as they are drawn; the mode line notifier
works its text out again."
  (let ((shown (and harness-ui-version-nag-places (harness-ui-version-behind-p) t)))
    (when (or force (not (eq shown harness-ui-version--nag-shown)))
      (setq harness-ui-version--nag-shown shown)
      (when (and (bound-and-true-p harness-notify-mode) (fboundp 'harness-ui-notify-refresh))
        (harness-ui-notify-refresh))
      (force-mode-line-update t))))

;;;; Commands

(defun harness-ui-version-refresh ()
  "Check the running harness against its origins again."
  (interactive)
  (harness-ui-version--check 0))

(defvar harness-ui-version-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "g") #'harness-ui-version-refresh)
    (define-key map (kbd "r") #'harness-reload)
    (define-key map (kbd "u") #'harness-ui-version-update)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-version-mode'.")

(define-derived-mode harness-ui-version-mode special-mode "Version"
  "Major mode of the version page: is the running harness the latest?
\\{harness-ui-version-mode-map}"
  (setq truncate-lines t buffer-read-only t))

;; The page's keys in the harness menu, behind `.'.
(put 'harness-ui-version-mode 'harness-menu-group
     '("Version"
       ["Version and update"
        (". g" "Check again" harness-ui-version-refresh)
        (". r" "Reload harness" harness-reload)
        (". u" "Update harness" harness-ui-version-update)]))

;;;###autoload
(defun harness-version ()
  "Show whether the running harness is the latest, against its origins.
The origins are the checkout it was loaded from, the repository that
checkout pulls from (GitHub, sourcehut, whichever it was cloned from),
local checkouts of the harness and `harness-version-origins'.  The
checks run in the background: the page shows the last report at once."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-version--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-version-mode) (harness-ui-version-mode))
      (harness-ui-version--render))
    (harness-ui-display-view buf)
    (harness-ui-version--check harness-ui-version--max-age)))

;;;; Following the harness

(defun harness-ui-version--on-event (event args)
  "Follow EVENT with ARGS: keep the report `version/checked' brings.
After `harness/reloaded' the harness may run another commit, so the nag
icon goes until the check it makes a few seconds later."
  (pcase event
    ("version/checked" (harness-ui-version--take (car args)))
    ("harness/reloaded"
     (setq harness-ui-version--reloaded t)
     (harness-ui-version--nag-changed))))

(defun harness-ui-version--on-update (&rest _)
  "Redraw the page after an update settles, and ask for a fresh report.
The harness process reloads in the background, so its check is asked
for a moment after the update: the rows then show what the update made
current."
  (harness-ui-version--redraw-all)
  (if (eq harness-ui-connection-address 'process)
      (run-with-timer 1 nil #'harness-ui-version-refresh)
    (harness-ui-version--check 0)))

(defun harness-ui-version--on-plugin-update (&rest _)
  "Redraw after a plugin update, and ask for a fresh report.
The plugin's checkout moved; the report reads its version and status
from disk, so a check shows both."
  (harness-ui-version--redraw-all)
  (if (eq harness-ui-connection-address 'process)
      (run-with-timer 1 nil #'harness-ui-version-refresh)
    (harness-ui-version--check 0)))

(defun harness-ui-version--on-connected ()
  "Forget the report of the harness the UI was connected to before.
Ask the harness for its own: a fresh enough one while a page shows,
else the last one it made, for the nag icon."
  (setq harness-ui-version--report nil
        harness-ui-version--checking nil
        harness-ui-version--error nil
        harness-ui-version--reloaded nil)
  (harness-ui-version--nag-changed)
  (if (harness-ui-version--buffers)
      (harness-ui-version--check harness-ui-version--max-age)
    (harness-ui-version--fetch)))

(defun harness-ui-version--init ()
  "Wire the page and the nag icon into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-version--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-version--redraw-all)
  (add-hook 'harness-ui-connected-hook #'harness-ui-version--on-connected)
  (add-hook 'harness-update-hook #'harness-ui-version--on-update)
  (add-hook 'harness-plugin-update-hook #'harness-ui-version--on-plugin-update)
  (define-key harness-ui-map (kbd "v") #'harness-version)
  (harness-ui-version--init-nag)
  ;; Started again while connected, as after `harness-stop': no
  ;; connection opens to ask for the report.
  (when (and (harness-ui-connected-p) (null harness-ui-version--report))
    (harness-ui-version--fetch)))

(defun harness-ui-version--init-nag ()
  "Add the hooks the nag icon shows through, after the other segments there."
  (add-hook 'harness-chat-header-end-functions #'harness-ui-version--chat-header 95)
  (add-hook 'harness-ui-tasks-header-functions #'harness-ui-version--board-header 95)
  (add-hook 'harness-ui-notify-segment-functions #'harness-ui-version--notify-segment)
  (harness-ui-version--nag-changed t))

(defun harness-ui-version--shutdown ()
  "Unwire the page and the nag icon, and forget the last report."
  (remove-hook 'harness-ui-event-functions #'harness-ui-version--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-version--redraw-all)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-version--on-connected)
  (remove-hook 'harness-update-hook #'harness-ui-version--on-update)
  (remove-hook 'harness-plugin-update-hook #'harness-ui-version--on-plugin-update)
  (remove-hook 'harness-chat-header-end-functions #'harness-ui-version--chat-header)
  (remove-hook 'harness-ui-tasks-header-functions #'harness-ui-version--board-header)
  (remove-hook 'harness-ui-notify-segment-functions #'harness-ui-version--notify-segment)
  (setq harness-ui-version--report nil
        harness-ui-version--checking nil
        harness-ui-version--error nil
        harness-ui-version--reloaded nil)
  (harness-ui-version--nag-changed t))

(harness-define-module 'ui-version
  :doc "Version page: whether the running harness is the latest, against its origins."
  :requires '(ui)
  :init #'harness-ui-version--init
  :shutdown #'harness-ui-version--shutdown)

(provide 'harness-ui-version)
;;; harness-ui-version.el ends here
