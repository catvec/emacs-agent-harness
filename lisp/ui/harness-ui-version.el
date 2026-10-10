;;; harness-ui-version.el --- The version page: is the running harness the latest?  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-version' (C-c h v) answers "are we running the latest
;; changes?".  It shows the commit the harness runs against the origins
;; newer versions come from, as the version module (harness-version.el)
;; reports them: the checkout the harness was loaded from as it is now,
;; the repository that checkout pulls from (sourcehut, GitHub, whichever
;; the package manager's recipe named), the local checkouts of the
;; harness that sessions work in, and any `harness-version-origins'.
;; An origin with commits the harness lacks lists the newest of them,
;; when a local repository has them, and the page says what to do about
;; it: reload, pull, or push first.
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
;;
;; Beside the harness process, the page shows the commit this Emacs
;; loaded the UI from (harness-revision.el): the two load their files
;; separately, so a restart of the harness process alone can leave them
;; on different commits.

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
(declare-function harness-reload "harness")
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

(defun harness-ui-version--label (origin)
  "Return what the page calls ORIGIN."
  (if (equal (plist-get origin :kind) "loaded")
      "loaded checkout"
    (or (plist-get origin :name) "origin")))

(defun harness-ui-version--names (origins)
  "Return the names of ORIGINS joined in a sentence."
  (let ((names (mapcar #'harness-ui-version--label origins)))
    (if (cdr names)
        (concat (string-join (butlast names) ", ") " and " (car (last names)))
      (car names))))

(defun harness-ui-version--sentence (string)
  "Return STRING with its first character upcased."
  (if (string-empty-p string) string (concat (upcase (substring string 0 1)) (substring string 1))))

(defun harness-ui-version--where (origin)
  "Return ORIGIN's location, branch and state, for its second line."
  (let ((location (or (plist-get origin :location) "")))
    (concat (if (equal (plist-get origin :kind) "remote") location (abbreviate-file-name location))
            (if-let* ((branch (plist-get origin :branch))) (concat ", " branch) "")
            (if (harness-ui-version--true origin :dirty) ", with uncommitted changes" "")
            (if (harness-ui-version--true origin :upstream) ", which the loaded checkout pulls from" ""))))

(defun harness-ui-version--status-in (origins &rest statuses)
  "Return the ORIGINS whose status is one of STATUSES."
  (cl-remove-if-not (lambda (o) (member (plist-get o :status) statuses)) origins))

(defun harness-ui-version--of-kind (origins kind)
  "Return the ORIGINS of KIND."
  (cl-remove-if-not (lambda (o) (equal (plist-get o :kind) kind)) origins))

(defun harness-ui-version--level (status)
  "Return how STATUS went, for `harness-ui-level-icon'."
  (pcase status
    ((or "same" "older") 'success)
    ("error" 'failure)
    (_ 'caution)))

(defun harness-ui-version--status-text (origin running)
  "Return what ORIGIN's status says, next to the commit RUNNING."
  (let ((missing (or (plist-get origin :missing) 0))
        (extra (or (plist-get origin :extra) 0)))
    (pcase (plist-get origin :status)
      ("same" "the commit running")
      ("newer" (format "%s the harness lacks" (harness-ui-version--commits missing)))
      ("older" (format "lacks %s the harness runs" (harness-ui-version--commits extra)))
      ("diverged" (format "diverged: %s the harness lacks; it lacks %d the harness runs"
                          (harness-ui-version--commits missing) extra))
      ("ahead" "commits the harness lacks (not fetched, so not counted)")
      ("unknown" (if (plist-get running :commit)
                     "no local repository holds both it and the commit running"
                   "cannot be compared"))
      ("error" (or (plist-get origin :error) "cannot be read"))
      (_ ""))))

(defun harness-ui-version--width ()
  "Return the width the page is drawn for."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 70 (1- (if window (window-width window) 100)))))

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
  "Return the straight.el package name of this harness, or nil."
  (when (and (boundp 'harness-directory) (stringp harness-directory)
             (string-match-p "/straight/build[^/]*/" harness-directory))
    (file-name-nondirectory (directory-file-name harness-directory))))

(defun harness-ui-version--checking-p ()
  "Non-nil while the page waits for a check it asked for."
  (and harness-ui-version--checking
       (< (- (float-time) harness-ui-version--checking) harness-ui-version--patience)))

;;;; Rendering

(defun harness-ui-version--verdict (report)
  "Return (LEVEL . TEXT): the answer REPORT gives."
  (let* ((origins (plist-get report :origins))
         (running (plist-get report :running))
         (newer (harness-ui-version--status-in origins "newer" "diverged" "ahead"))
         (unknown (harness-ui-version--status-in origins "unknown"))
         (failed (harness-ui-version--status-in origins "error")))
    (pcase (plist-get report :verdict)
      ("latest"
       (if failed
           (cons 'caution (format "No origin read has a commit the harness lacks, but %s could not be read."
                                  (harness-ui-version--names failed)))
         (cons 'success "Running the latest: no origin has a commit the harness lacks.")))
      ("behind" (cons 'caution (format "Not the latest: %s %s commits the harness lacks."
                                       (harness-ui-version--names newer)
                                       (if (cdr newer) "have" "has"))))
      (_ (cons 'caution
               (cond ((not (plist-get running :commit))
                      (format "Cannot tell: the harness was not loaded from a git checkout (%s)."
                              (or (plist-get running :error) "no commit")))
                     (unknown
                      (format "Cannot tell how %s compare%s: no local repository holds both commits."
                              (harness-ui-version--names unknown) (if (cdr unknown) "" "s")))
                     (t "Cannot tell: no origin could be read.")))))))

(defun harness-ui-version--header ()
  "Return the header line."
  (let ((report harness-ui-version--report))
    (list (propertize " Harness version " 'face 'harness-version-heading-face)
          (propertize (format "%s " (or (plist-get report :version)
                                        (and (boundp 'harness-version) harness-version)
                                        ""))
                      'face 'harness-dim-face)
          (cond ((harness-ui-version--checking-p) (propertize " checking…" 'face 'harness-dim-face))
                ((null report) "")
                (t (propertize (pcase (plist-get report :verdict)
                                 ("latest" " the latest") ("behind" " not the latest") (_ " cannot tell"))
                               'face (harness-ui-level-face (car (harness-ui-version--verdict report)))))))))

(defun harness-ui-version--details (&rest parts)
  "Insert a line of PARTS (strings, or functions inserting) at the details column."
  (insert (make-string harness-ui-version--indent ?\s))
  (dolist (part parts)
    (if (functionp part) (funcall part) (insert part)))
  (insert "\n"))

(defun harness-ui-version--commit-line (commit subject date width)
  "Return COMMIT's line: its short hash, SUBJECT and DATE, fitted to WIDTH."
  (let ((room (max 20 (min 72 (- width harness-ui-version--indent 9 10)))))
    (concat (propertize (harness-ui-version--short commit) 'face 'harness-label-face) "  "
            (string-pad (harness-truncate-end (or subject "") room) room)
            (propertize (format "  %s" (harness-ui-version--ago date)) 'face 'harness-dim-face))))

(defun harness-ui-version--reload-button ()
  "Insert the button reloading the harness."
  (harness-ui-button "[Reload harness]" #'harness-reload
                     :help "Load the harness's files again, in this Emacs and in the harness process"))

(defun harness-ui-version--insert-running (report)
  "Insert what REPORT says runs: the harness process's commit, and this Emacs's."
  (let* ((running (plist-get report :running))
         (commit (plist-get running :commit))
         (width (harness-ui-version--width)))
    (insert " " (propertize (string-pad "Running" (1- harness-ui-version--indent)) 'face 'harness-version-heading-face))
    (insert (if commit
                (harness-ui-version--commit-line commit (plist-get running :subject) (plist-get running :date) width)
              (format "version %s, from no git checkout" (plist-get report :version)))
            "\n")
    ;; Where it was loaded from is the loaded checkout's line, under
    ;; Origins; without a commit there is no such line.
    (harness-ui-version--details
     (propertize (concat (if (harness-ui-version--separate-p) "the harness process, loaded " "loaded ")
                         (harness-ui-version--ago (plist-get running :loaded))
                         (if commit
                             ""
                           (concat " from " (abbreviate-file-name (or (plist-get running :directory) "?"))))
                         (if (harness-ui-version--true running :dirty) ", with uncommitted changes" ""))
                 'face 'harness-dim-face))
    (when (harness-ui-version--separate-p)
      (let ((ui (harness-ui-version--ui-revision)))
        (cond
         ((null ui))
         ((plist-get ui :error)
          (harness-ui-version--details (propertize (format "this Emacs: %s" (plist-get ui :error)) 'face 'harness-dim-face)))
         ((equal (plist-get ui :commit) commit)
          (harness-ui-version--details (propertize (format "this Emacs: the same commit, loaded %s"
                                                           (harness-ui-version--ago (plist-get ui :loaded)))
                                                   'face 'harness-dim-face)))
         (t
          (harness-ui-version--details
           (propertize (format "this Emacs runs %s, loaded %s: not the harness process's commit."
                               (harness-ui-version--short (plist-get ui :commit))
                               (harness-ui-version--ago (plist-get ui :loaded)))
                       'face 'harness-caution-face))
          (when (harness-ui-version--reloadable-p)
            (harness-ui-version--details #'harness-ui-version--reload-button))))))))

(defun harness-ui-version--insert-commits (commits more width)
  "Insert COMMITS, then a line for MORE commits not listed; fit WIDTH."
  (dolist (c commits)
    (harness-ui-version--details
     (harness-ui-version--commit-line (plist-get c :commit) (plist-get c :subject) (plist-get c :date) width)))
  (when (> more 0)
    (harness-ui-version--details
     (propertize (format "and %d more, merges included" more) 'face 'harness-dim-face))))

(defun harness-ui-version--insert-origins (report)
  "Insert REPORT's origins, with the commits each has that the harness lacks."
  (let ((running (plist-get report :running))
        (width (harness-ui-version--width))
        (listed nil))
    (insert " " (propertize "Origins" 'face 'harness-version-heading-face) "\n")
    (unless (plist-get report :origins)
      (harness-ui-version--details (propertize "none: see `harness-version-origins'" 'face 'harness-dim-face)))
    (dolist (o (plist-get report :origins))
      (let* ((status (plist-get o :status))
             (level (harness-ui-version--level status))
             (commit (plist-get o :commit))
             (key (list commit status))
             (twin (and commit (cdr (assoc key listed)))))
        (insert "   " (harness-ui-level-icon level) " "
                (string-pad (harness-ui-version--label o) (- harness-ui-version--indent 5))
                (if commit (concat (propertize (harness-ui-version--short commit) 'face 'harness-label-face) "  ") "")
                (propertize (harness-ui-version--status-text o running)
                            'face (if (eq level 'success) 'default (harness-ui-level-face level)))
                "\n")
        (harness-ui-version--details (propertize (harness-ui-version--where o) 'face 'harness-dim-face))
        (pcase status
          ((or "newer" "diverged" "older")
           (let* ((older (equal status "older"))
                  (commits (plist-get o (if older :extra-commits :missing-commits)))
                  (count (or (plist-get o (if older :extra :missing)) 0)))
             (cond
              (twin (harness-ui-version--details
                     (propertize (format "the same commits as %s" twin) 'face 'harness-dim-face)))
              (t (when older
                   (harness-ui-version--details
                    (propertize "commits the harness runs that it lacks:" 'face 'harness-dim-face)))
                 (harness-ui-version--insert-commits commits (- count (length commits)) width)
                 (push (cons key (harness-ui-version--label o)) listed))))))))))

(defun harness-ui-version--hints (report)
  "Return what to do about REPORT: a list of (TEXT . BUTTON-FUNCTION-OR-NIL)."
  (let* ((origins (plist-get report :origins))
         (running (plist-get report :running))
         (dir (abbreviate-file-name (or (plist-get running :directory) "")))
         (loaded (car (harness-ui-version--of-kind origins "loaded")))
         (moved (member (plist-get loaded :status) '("newer" "diverged" "ahead")))
         (remotes (harness-ui-version--of-kind origins "remote"))
         (newer-remotes (harness-ui-version--status-in remotes "newer" "diverged" "ahead"))
         (newer-locals (harness-ui-version--status-in (harness-ui-version--of-kind origins "local")
                                                      "newer" "diverged" "ahead"))
         (package (harness-ui-version--straight-package))
         (hints nil))
    (when moved
      (push (cons "The checkout the harness was loaded from has moved on: reload to run what it holds now."
                  (and (harness-ui-version--reloadable-p) #'harness-ui-version--reload-button))
            hints))
    (when (and newer-remotes (not moved) (plist-get running :commit))
      (push (list (format "To run the commits of %s, pull them into %s%s, then reload."
                          (harness-ui-version--names newer-remotes) dir
                          (if package (format " (M-x straight-pull-package RET %s)" package) "")))
            hints))
    (when (and newer-locals (not newer-remotes) remotes
               (cl-every (lambda (o) (member (plist-get o :status) '("same" "older"))) remotes))
      (push (list (format "%s %s commits %s lacks: push them, then pull them into %s."
                          (harness-ui-version--sentence (harness-ui-version--names newer-locals))
                          (if (cdr newer-locals) "have" "has")
                          (harness-ui-version--names remotes) dir))
            hints))
    (nreverse hints)))

(defun harness-ui-version--insert-hints (hints width)
  "Insert HINTS from `harness-ui-version--hints', filled to WIDTH."
  (pcase-dolist (`(,text . ,button) hints)
    (let ((start (point)))
      (insert " " text "\n")
      (let ((fill-column width) (fill-prefix " "))
        (fill-region start (point))))
    (when button
      (insert " ")
      (funcall button)
      (insert "\n"))))

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
        (insert " " (propertize (if (and harness-ui-version--error (not (harness-ui-version--checking-p)))
                                    (format "The check failed: %s" harness-ui-version--error)
                                  "Checking the running harness against its origins…")
                                'face (if (and harness-ui-version--error (not (harness-ui-version--checking-p)))
                                          'harness-failure-face 'harness-dim-face))
                "\n")
      (pcase-let ((`(,level . ,text) (harness-ui-version--verdict report)))
        (insert " " (harness-ui-level-icon level) " " (propertize text 'face (harness-ui-level-face level)) "\n\n"))
      (harness-ui-version--insert-running report)
      (insert "\n")
      (harness-ui-version--insert-origins report)
      (when-let* ((hints (harness-ui-version--hints report)))
        (insert "\n")
        (harness-ui-version--insert-hints hints width))
      (insert "\n "
              (propertize (format "Checked %s; the harness checks by itself every half hour.  "
                                  (harness-ui-version--ago (plist-get report :checked)))
                          'face 'harness-dim-face))
      (if (harness-ui-version--checking-p)
          (insert (propertize "Checking…" 'face 'harness-dim-face))
        (harness-ui-button "[Check now]" #'harness-ui-version-refresh :help "Check the origins again (g)"))
      (insert "\n")
      (when harness-ui-version--error
        (insert " " (propertize (format "The last check failed: %s" harness-ui-version--error)
                                'face 'harness-failure-face)
                "\n")))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun harness-ui-version--redraw-all ()
  "Redraw every version page from the last report."
  (dolist (buf (harness-ui-version--buffers))
    (with-current-buffer buf (harness-ui-version--render))))

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
     (format "The harness is not the latest: %s %s commits it lacks (mouse-1: what to do)"
             (or (harness-ui-version--names newer) "an origin")
             (if (cdr newer) "have" "has")))))

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
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "g") #'harness-ui-version-refresh)
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
       ["Version"
        (". g" "Check again" harness-ui-version-refresh)]))

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
  (define-key harness-ui-map (kbd "v") #'harness-version)
  (harness-ui-version--init-nag)
  ;; Started again while connected, as after `harness-stop': no
  ;; connection opens to ask for the report.
  (when (and (harness-ui-connected-p) (null harness-ui-version--report))
    (harness-ui-version--fetch)))

(defun harness-ui-version--init-nag ()
  "Add the hooks the nag icon shows through, after the other segments there.
A reload does not initialise a running module again, so the file adds
them itself when the module is ready (below)."
  (add-hook 'harness-chat-header-end-functions #'harness-ui-version--chat-header 95)
  (add-hook 'harness-ui-tasks-header-functions #'harness-ui-version--board-header 95)
  (add-hook 'harness-ui-notify-segment-functions #'harness-ui-version--notify-segment)
  (harness-ui-version--nag-changed t))

(defun harness-ui-version--shutdown ()
  "Unwire the page and the nag icon, and forget the last report."
  (remove-hook 'harness-ui-event-functions #'harness-ui-version--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-version--redraw-all)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-version--on-connected)
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

(when (harness-module-ready-p 'ui-version)
  (harness-ui-version--init-nag))

(provide 'harness-ui-version)
;;; harness-ui-version.el ends here
