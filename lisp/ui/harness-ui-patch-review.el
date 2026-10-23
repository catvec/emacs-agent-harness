;;; harness-ui-patch-review.el --- A task's changes in its session and report: a file tree, threads, Ediff  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task waiting for review is a patch waiting for its reviewer.  This
;; module puts the patch in the review: in the review banner of the task's
;; session, where its work is handed in, and in its report (the popout
;; [Review Changes] opens on the board and in the session), and reviews it
;; file by file in Ediff, with the comments made on it kept as threads.
;;
;; THE LIBRARY AND THIS ADAPTER.  What a review is -- a change set with
;; versions, threads of comments, each comment recording its thread, its
;; place in the code, its author and the revision it was written against
;; -- and how it looks, is the library change-review
;; (lisp/vendor/change-review), which knows nothing of the harness: its
;; threads view, its diff view, its one drawing of a thread.  This module
;; is the adapter that gives that library a task to review, in this Emacs:
;;
;;   change set   the task; each time its agent hands the work in is a
;;                version of it, named by the commit the branch ends at,
;;                the revision the comments made against it record;
;;   files        read from git here, in the task's repository, and the
;;                files of the version;
;;   threads      kept by the harness (harness-patch-review.el), which
;;                this module sends the operations the user makes
;;                (`patch-review/apply') and hears of those the agent
;;                makes with its tools (`patch-review/changed'), so that
;;                an agent's comment shows as it is made, with the session
;;                and tool call it came from, a link to that point of its
;;                conversation;
;;   authors      the user, by name; the agent, by session and tool call.
;;
;; THE CHANGES, drawn the same on three surfaces: in the review banner of
;; the task's session, between the report the agent handed in and
;; [Verify], so the work is looked over where it is handed in, with no
;; click on [Review Changes] (the banner asks for them through
;; `harness-ui-review-changes-functions'); in the report, under the
;; evidence, above the review banner and its box; and in the tree beside
;; Ediff (below).  What the task's branch changes against its merge base
;; with the branch it was made from -- what merging it brings in, not
;; what that branch did since -- or the diff the reviewer chooses instead
;; (see THE DIFF SHOWN), shows as a tree of the directories and their
;; files, and below it the threads:
;;
;;   a file      its status, its name, the lines it adds and deletes,
;;               a dim ✓ once it was looked at in Ediff and a bold green
;;               ✔ once it was approved -- only the approved are
;;               skipped, as the hint under the files and the row's
;;               tooltip say --, how many threads it has, open and
;;               closed -- and how many of those the agent closed that the
;;               reviewer has not looked at yet, "to review" -- and
;;               whether it changed since the reviewer's
;;               last comment on it.  RET or a click compares it in
;;               Ediff; n and p move between rows; a approves it, A
;;               approves every file, t shows the files flat instead.
;;               An approved file need not be looked at again unless the
;;               branch changes it.  The marks are kept by the harness
;;               with the review, each by the file's path and blob
;;               (`patch-review/set-viewed'), so they are there after a
;;               restart.  V takes every file as viewed but those the
;;               branch's newest commit changed, for a review gone
;;               through before the marks were kept
;;               (`patch-review/assume-viewed'); the heading says so when
;;               files were taken as viewed and not looked at.
;;   directories the files group under the directories that hold them,
;;               with how many files each holds and the lines they add
;;               and delete, as a file tree shows them.  TAB, RET or a
;;               click folds a directory, and a approves its files.
;;   threads     a section below the files, in the same buffer -- not a
;;               view of its own: the library's drawing of each thread
;;               (who wrote each comment, when, which revision it was
;;               against, its place in the thread, open or closed), by
;;               file, under a heading whose buttons filter them by
;;               status.  r replies in a thread, x closes it or opens it
;;               again, RET on its header compares the file in Ediff at
;;               its line, on a comment shows where it was made, o
;;               follows an agent's comment to its conversation, c
;;               comments on the change as a whole, f changes the
;;               filter.  T goes to the section; where there is none, in
;;               Ediff, it shows the tree beside it and goes there.
;;
;; Reviewing a branch is going through its files, and two settings make
;; that go the way a reviewer wants, each a button of the changes with its
;; key (s and u), in Ediff's help, in the harness menu, and an option:
;;
;;   skip approved   (`harness-ui-patch-review-skip-approved', on): going
;;               on from file to file -- n and p on the rows, N and P in
;;               Ediff, n at the last difference, the row point lands on
;;               when Ediff ends -- steps over the files already
;;               approved, and says how many it went over: n at the last
;;               difference says it will ("..., skipping 2 approved
;;               files"), and once the next file is up, last, so that
;;               nothing Ediff says covers it, so does the note that it
;;               did.  RET on one still compares it.
;;   auto-approve    (`harness-ui-patch-review-auto-approve', on): leaving
;;               a file in Ediff approves it when the reviewer was at its
;;               last difference -- went through what it changes -- and
;;               has no draft on it, no open thread they wrote in and no
;;               reply in a thread waiting in the report's box (C-c > on
;;               lines of a version starts one, a card there that is no
;;               thread of the review until the feedback is sent, and it
;;               counts before any word is written under it).  A file with
;;               a comment of yours is not settled, one with a thread the
;;               agent started and you did not answer is.  The approval
;;               is the one a makes, kept by the harness.  A file with a
;;               new comment is not an approved one, however it got to be
;;               approved: a draft you write on an approved file -- a
;;               comment, a reply in the agent's thread, a reply card --
;;               takes the approval off it (the file stays viewed), and an
;;               approval you give after the comment, with a, stands.
;;               What you decide by hand stands: a file whose approval
;;               you took off (a again) while you compared it stays not
;;               approved as you leave it, though you went through it.
;;
;; THE ORDER of the files is the one they show in -- the tree from top to
;; bottom, else the diff's -- so the next file is the one on the next row.
;;
;;   Ediff       the file at the merge base against the file on the
;;               branch, in the frame of the report or the session, the
;;               report small at the bottom of it with its feedback box
;;               (opened for it from the banner, closed with the Ediff),
;;               and on the left the TREE of the files, as a file tree
;;               shows beside an editor (`harness-ui-patch-review-ediff-tree',
;;               `harness-ui-patch-review-ediff-tree-width'): the
;;               directories and files with their marks, the file
;;               compared marked and highlighted, the threads under
;;               them, in a buffer of its own that Ediff leaves be.  RET
;;               or a click on a file there compares it in place of the
;;               one under way, TAB folds a directory, q ends Ediff, and
;;               t in Ediff hides the tree or shows it again.  The
;;               control panel keeps Ediff's keys and has more: c
;;               comments on the current difference, r replies to the
;;               thread there, TAB folds the threads of the difference
;;               (see below), T goes to the threads, e goes to the
;;               report's box, a approves the file or takes its approval
;;               off, s and u switch the settings, N and P go on to the
;;               next or previous file,
;;               q comes back to where Ediff began, point on the next
;;               file to review.  n is Ediff's next difference, and at
;;               the last one says the next difference is the next file
;;               -- and how many approved files it steps over:
;;               n again opens it.
;;   threads     c reads a comment and starts a thread with it, a draft,
;;               under the line it is about: in the control panel on the
;;               current difference, in either version Ediff compares on
;;               the line at point.  Every thread of the file shows in
;;               both versions under its line, drawn by the library as
;;               its views draw it: who wrote each comment, when, which
;;               revision it was against, its place in the thread, open
;;               or closed; r, x, RET and o there are as in the threads
;;               section.  T goes to the threads; d there comes back to
;;               Ediff, at the thread's line.
;;   quote reply C-c > replies to a comment with what you highlight of it
;;               quoted, as a mail's reply is, point under the quote.  In
;;               the threads list it is the region.  In Ediff's versions a
;;               comment is drawn under its line and is no text of the
;;               buffer, so no region holds any of it: a drag of the mouse
;;               over it selects (a double click a word, a triple click a
;;               line), the selection shows, and C-c > quotes it; with
;;               none it quotes the last comment of the thread there.  In
;;               the control panel it quotes what is selected in a version,
;;               else the last comment of the thread at the current
;;               difference.  The reply is a draft, as r's.
;;   thread on   C-c > in a version with lines selected starts a thread on
;;   lines       them, in place of the quote reply: a card in the box of the
;;               report, the file, the side, the lines and the revision
;;               recorded with them (`harness-ui-patch-review-thread-reply'),
;;               and the words written under it the comment.  Sent with
;;               the feedback it is a thread on those lines, which the
;;               agent answers.
;;   drafts      A draft is yours to change or to take back until the
;;               feedback sends it: it has an [Edit] button, which edits
;;               that draft, a [Delete] button, which deletes it after
;;               asking, and e and k do the same to one found by where
;;               point is: under the line in a version, at the current
;;               difference in the control panel (the only draft there,
;;               or the one chosen of several), on a thread's row in the
;;               report, on a thread's header or a comment in the
;;               threads list.  e with no draft in Ediff goes to the
;;               report's box; k says there is none.  A thread that is
;;               nothing but drafts has a [Delete thread] button in its
;;               header, and K deletes it, found the same way: the
;;               thread you commented in by mistake goes whole, with
;;               its drafts.  The first draft of a thread that has more
;;               cannot go alone, so k and its [Delete] ask about the
;;               thread.  What the feedback sent is not a draft any
;;               more, and stays.  A deletion is the library's
;;               `delete-comment' operation, one for each draft, sent
;;               to the harness like any other (`patch-review/apply'),
;;               which keeps the threads: the draft is gone there too.
;;   folds       A closed thread is one line under its line, the
;;               first words of what it says, no wider than the window
;;               shows; so is any thread folded.  TAB on its line (in
;;               the control panel: on the threads of the current
;;               difference), or a click on its triangle or its words,
;;               opens it to its conversation, ▸ becoming ▾; a thread
;;               longer than the window has room for is cut, saying
;;               how many lines more there are, and TAB again shows all
;;               of it, then one more folds it to a line.  What was folded
;;               is kept for the review, so it stays so when the next file
;;               comes and the first comes back.  The threads are drawn to
;;               the width of the window that shows them, and again when
;;               it changes, as it does when the two versions are put
;;               side by side.
;;
;; A comment is Markdown (`harness-ui-patch-review-markdown'): the user
;; writes it in a buffer, an agent in its tool call, and wherever it is
;; drawn -- the threads view, the threads under the lines of Ediff, a row
;; of the report -- it shows rendered, as the chat renders a message,
;; wrapped under its bar; a thread named by its first words has them
;; without the markers.  What is kept, edited and sent with the feedback
;; is the Markdown as it was typed.
;;
;; WHERE A COMMENT WAS MADE.  The lines under a comment (RET, or its
;; `▸ where') are the diff of the commit it was written against, as it was
;; then: the answer to a comment changes the code it is about, and the
;; newest diff would make the comment read as if it asked for what is
;; there already.  The commit is recorded with every comment, by its sha: a
;; comment made in Ediff has the commit the branch was read at, the
;; agent's the one it was at.  A comment made on a line keeps the diff
;; around it.  A reply, or a thread the agent started on a line, keeps
;; none of the commit it was written on, so the review reads the branch at
;; that commit, once (a snapshot, `harness-ui-patch-review--snapshot'):
;; its diff against the merge base the version recorded, the thread's
;; place in it, and the diff around that line.  While git answers, the
;; details say "reading the diff at 68726a2…"; a commit the repository no
;; longer has says so, and shows what the thread kept.  The details lead
;; to the code too.  [Source @ v1], and D in the threads view, show it in
;; Ediff as that commit had it -- the merge base against the file of that
;; commit, the line in sight, "as it was at 68726a2" in the control
;; panel; [Source @ v2], and d, in the branch as it is; RET, or a click,
;; on a line of the diff, that line of the source.  An Ediff of an
;; earlier commit is looked at, not reviewed: its files are not marked
;; seen or approved, and a comment made in it is written against that
;; commit.
;;
;; THE DIFF SHOWN.  A line under the heading chooses what the files are
;; of -- three buttons, or d in the report
;; (`harness-ui-patch-review-select-diff'):
;;
;;   task branch against main   the one the report starts with: what
;;                              merging the branch brings in, from its
;;                              merge base with the branch it was made
;;                              from;
;;   since last review          the branch against where it was when its
;;                              work was last handed in -- the version of
;;                              the review before the one the branch is
;;                              at -- so that a task sent back shows only
;;                              what the agent did since.  Work handed in
;;                              again with no new commit changed nothing
;;                              since, and the report says so;
;;   other                      any revisions of the repository, typed as
;;                              `git diff' takes them: A..B, A...B (from
;;                              the merge base of A and B), A B, or A
;;                              alone, against the branch.  An end left
;;                              out is the branch's tip, a start left out
;;                              the branch it was made from.
;;
;; The files, their counts, Ediff and the threads follow the choice, which
;; the review keeps while it lasts: a report closed and opened again
;; shows it.  Ediff's two versions are named after what they are in the
;; diff ("merge base 8d1fb32", "v1 1c9e4a0", "main~3 5be0a77"), and so
;; are the old version's comments ("line 5 of v1").  A thread on a file
;; the diff shown does not change stays among the threads, under its
;; file, where it is now in the branch's whole change.  What cannot be
;; shown -- a revision that is not there, a review before this one of
;; which nothing is known -- is said, and the diff shown stays.
;;
;; WHAT THE AGENT CLOSED.  The agent answers a thread with its
;; `review_comment' tool and closes it when its point is done; whether
;; it is, is for the reviewer to say.  A thread the agent closed is "to
;; review" until the reviewer has looked at it (the library's
;; `change-review-thread-unreviewed-p'), however many rounds ago it was
;; closed.  The report's heading counts them as a button that lists
;; them (`[3 to review]', the threads view with its filter on them), a
;; file's row says how many it has, and the report lists them under
;; their file, a line each, with the open threads.  Ediff draws them
;; whole under their line, the agent's answer in sight, where a closed
;; thread is one line.  m on such a row, in either version of Ediff or
;; in its control panel, marks the thread reviewed (and again, makes it
;; wait once more), M every one that waits, and a reply to it is as good
;; as m.  The mark is on that close: a thread the agent closes again
;; after it was opened is to review again, and nothing marks one by
;; itself, so a close missed for two rounds waits still.  The harness
;; keeps the marks with the threads (`patch-review/apply').
;;
;; Replies you wrote by hand before there were threads -- under a quote of
;; the agent's words, in a round of feedback or typed in its session while it
;; worked -- are threads too, closed, each with the quote it answered:
;; `harness-ui-patch-review-import-manual' (M-x, in a task's report, session
;; or card) makes them from what the harness kept (`patch-review/import-manual').
;;
;; The drafts go with the feedback.  Whatever sends the task back --
;; the report's box, a message typed in its session, another client --
;; takes the drafts with it, quoted from the diff above each comment as a
;; reply on a mailing list has it; the harness does it
;; (harness-patch-review.el), the drafts are marked sent, and the box
;; holds the words that go with them.  Sending the feedback from the box
;; beside Ediff ends Ediff and gives the frame back.
;;
;; The box stays in sight while Ediff compares the files: the report
;; keeps the bottom of the frame, 30% of it at most
;; (`harness-ui-patch-review-ediff-box-height'), and ends in the box.  e
;; in Ediff goes to the box; C-c C-d in the report goes back to Ediff,
;; which was never left: the comparison, and where in it the reviewer
;; was, are as they were.
;;
;; A task sent back keeps its threads: the comments of its earlier
;; rounds, and the agent's answers, show where their lines are now, in
;; the newest version of the file (in the merge base's version for a
;; comment on a removed line), with what became of the line since
;; ("line 44 (was 42)", "line 44 (changed since)").  A comment records the
;; revision it was written against; the line it was on is carried through
;; the diff from that revision to the branch as it is, so a line that
;; moved shows at its new number.  A comment whose revision is no longer
;; in the repository is placed by the lines it quotes.  What has no file
;; row -- threads on the change as a whole, on files the branch no longer
;; changes -- is in the threads too, under its own heading.  Each file
;; also says whether it changed since the reviewer's last comment on it
;; or stayed the same -- an approved file that changed is approved no
;; more.
;;
;; THE BANNER keeps the reader's place as it draws again (a key that
;; approves a file, a thread closed): the tail of a chat is deleted and
;; drawn whole, so point goes back to the row, thread or comment it was
;; on, and the window shows it on the line it was; a thread that went
;; leaves point on the one that took its place.
;;
;; AFTER AN UPDATE.  The harness updates by reloading in place, with the
;; reviews it holds, and a struct that gained a slot reads the review its
;; older definition made wrong: one slot for another, or past its end,
;; which signals `args-out-of-range' and, where that was printed, put the
;; whole review -- the task's hand-in in it -- in the message.  A review
;; remembers the layout of the structs it is made of when it was made
;; (`harness-ui-patch-review--layout'), and loading this file drops every
;; one made under another layout, a version that kept none included
;; (`harness-ui-patch-review--drop-stale-reviews'); the report and the
;; banner that showed it are drawn again once the module starts, which
;; makes the review again, from the threads and the files viewed the
;; harness keeps and from the branch.  Changes that cannot be drawn for
;; any other reason say so in one short line with a [Try again] button,
;; which makes the review again, and the rest of the report -- [Verify]
;; and [Send back] -- and of the banner is drawn all the same.
;;
;; A LINK TO A THREAD.  An agent that answers a thread, or points at one,
;; writes a link to it (harness:thread/ID, lisp/harness-links.el), and a
;; click on it comes here (`harness-ui-patch-review-show-thread'): the
;; review opens in the task's report, once its threads are fetched and
;; its branch read, with point on the thread and the filter changed to
;; show it when the filter hid it.  Where the report cannot draw the
;; changes -- the repository is not on this machine -- the library's
;; threads view shows the thread instead.  ui-linking owns the click
;; (`harness-ui-linking-handlers'); this module registers the one for
;; threads, and the session a review's links are written in.
;;
;; From a task's session history -- or a board card -- C-c C-d opens the
;; report with the changes, even after the task left review, when it shows
;; them without the review banner (`harness-ui-patch-review-mode').  C-u
;; C-c C-d asks which diff to open it at, as d does in the report.
;;
;; Git runs here, in the Emacs that shows the UI, in the task's
;; repository: the changes show where that is a directory of this
;; machine, so not for a harness on another one.
;;
;; The module draws in the report through the hook the report has for
;; panels (`harness-ui-report-panel-functions'), in the banner through
;; the review's own (`harness-ui-review-changes-functions'), and leaves
;; sending to the review's box.  Disabled (`harness-disabled-modules'),
;; it takes its part of the report and the banner out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'pulse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-markdown)
(require 'harness-ui-popout)
(require 'harness-ui-report)

;; change-review is in lisp/vendor/change-review, which the harness puts
;; on `load-path' (`harness--setup-load-path').  A harness older than
;; that directory, reloading after an update, first checks that this
;; file compiles with the `load-path' it has, before it loads the
;; harness.el that adds the directory.  So when the library is not found,
;; look for it beside the file being compiled or loaded.
(defvar byte-compile-current-file)
(eval-and-compile
  (unless (or (featurep 'change-review) (locate-library "change-review"))
    (when-let* ((file (or (and (boundp 'byte-compile-current-file)
                               (stringp byte-compile-current-file)
                               byte-compile-current-file)
                          load-file-name
                          buffer-file-name))
                (dir (expand-file-name "../vendor/change-review/" (file-name-directory file)))
                ((file-directory-p dir)))
      (add-to-list 'load-path dir))))
(require 'change-review)
(require 'change-review-ui)
(require 'change-review-diff)

(defvar harness-ui-patch-review--row-map)
(defvar change-review-ui--set)
(defvar change-review-ui--redraw-function)
(defvar change-review-ui--details)
(defvar harness-ui-review-pending-functions)
(defvar harness-ui-popout--max-height)
(defvar harness-ui-popout-window-parameters)
(defvar harness-ui-popout-min-height)
(defvar harness-ui-report-max-height)
(defvar ediff-window-setup-function)
(defvar ediff-brief-help-message-function)
(defvar ediff-mode-map)
(defvar ediff-after-quit-hook-internal)
(defvar ediff-current-difference)
(defvar ediff-number-of-differences)
(defvar ediff-buffer-A)
(defvar ediff-buffer-B)
(defvar ediff-keep-variants)
(defvar ediff-help-message)
(defvar ediff-whitespace)
(defvar evil-local-mode)
(defvar window-restore-killed-buffer-windows)
(declare-function change-review-ui--overlay-selection "change-review-ui" ())
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-windows-plain "ediff-wind" (buffer-a buffer-b buffer-c control-buffer))
(declare-function ediff-really-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-get-diff-posn "ediff-util" (buf-type pos &optional n control-buf))
(declare-function ediff-next-difference "ediff-util" (&optional arg))
(declare-function ediff-set-help-message "ediff-help" ())
(declare-function ediff-indent-help-message "ediff-help" ())
(declare-function ediff-set-help-overlays "ediff-help" ())
(declare-function ediff-multiframe-setup-p "ediff-init" ())
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function harness-ui-report-task "harness-ui-report" ())
(declare-function harness-ui-report--call-position "harness-ui-report" (item))
(declare-function harness-ui-display-session "harness-ui" (session-id))
(declare-function harness-ui-review--task "harness-ui-review" (sid))
(declare-function harness-ui-tasks--task "harness-ui-tasks" (&optional noerror))
(defvar harness-ui-linking-handlers)
(defvar harness-ui-linking-context-functions)

(defgroup harness-ui-patch-review nil
  "A task's changes in its session and report: Ediff file by file, comments quoted in the feedback."
  :group 'harness-ui)

(defcustom harness-ui-patch-review-ediff-window-setup #'ediff-setup-windows-plain
  "How Ediff lays out its windows while it compares a task's change.
The default keeps the control panel in the frame, under the two
versions; nil leaves it to `ediff-window-setup-function', which on a
graphical display gives the panel a frame of its own.  Whether the two
versions are side by side is Ediff's `ediff-split-window-function'."
  :type '(choice (const :tag "Ediff's own setting" nil) function))

(defcustom harness-ui-patch-review-ediff-box-height 0.3
  "How much of the frame's height the report takes beside an Ediff.
While Ediff compares a file the report stays at the bottom of the frame,
under the two versions and Ediff's control panel, with its feedback box
at the end in sight: the comments made so far can be read there, and
edited, without leaving Ediff
\(\\<harness-ui-patch-review-lines-mode-map>\\[harness-ui-patch-review-edit-feedback] in Ediff goes to the box).  This is a fraction of the
frame's height, at most; nil takes the report off the frame while Ediff
shows, as the whole frame is Ediff's then."
  :type '(choice (const :tag "Out of sight" nil) number))

(define-obsolete-variable-alias 'harness-ui-patch-review-context-lines
  'change-review-diff-context-lines "2026-10-19")

(defcustom harness-ui-patch-review-closed-threads nil
  "Whether the threads below the files start by showing the closed ones too.
The threads of the changes -- in the report, in the review banner and in
the tree beside Ediff -- show the open ones at first; the closed ones,
the good ending, only count in the file's row until the filter's buttons
show them.  Non-nil starts each of them on all the threads.  The
filter is the buffer's, and \\<harness-ui-patch-review--thread-map>\\[change-review-ui-cycle-filter] changes it there."
  :type 'boolean)

(defcustom harness-ui-patch-review-file-tree t
  "Whether a report shows the changed files as a tree.
The directories group the files they hold, with the lines the files
under each add and delete; nil shows every file in a flat list, in the
diff's order.  \\<harness-ui-patch-review--row-map>\\[harness-ui-patch-review-toggle-file-tree]
switches it for the review at point."
  :type 'boolean)

(defcustom harness-ui-patch-review-skip-approved t
  "Whether going on from file to file steps over the files already approved.
N and P in Ediff, n at the last difference, n and p on the rows of the
changes, and the row point lands on when Ediff ends all go to the next
file that is not approved: an approved file need not be looked at again
unless the branch changes it.  Only an approved file (the bold ✔) is
skipped, not one that was only looked at (the dim ✓).  The steps say how
many files they went over.  RET or a click on an approved file still
compares it.  \\<harness-ui-patch-review--row-map>\\[harness-ui-patch-review-toggle-skip-approved] switches it, for every review, wherever the
changes show and in Ediff."
  :type 'boolean)

(defcustom harness-ui-patch-review-auto-approve t
  "Whether a file you looked through and made no comment on is approved.
Leaving a file in Ediff -- n past its last difference, N, P or q --
approves it when you reached its last difference, so went through what
it changes, and you have no draft on it, no open thread you wrote in and
no reply in a thread waiting in the report's box (C-c > on lines of a
version): a file with a comment of yours is not settled.  The approval is
the firm check mark, kept by the harness like one you made with
\\<harness-ui-patch-review--row-map>\\[harness-ui-patch-review-approve].
A comment you write on a file that is approved takes its approval off.
A file whose approval you took off while you compared it, with that
key, is not approved again as you leave it: what you decided by hand
stands.  \\[harness-ui-patch-review-toggle-auto-approve] switches this off and on, for every review, wherever the changes
show and in Ediff."
  :type 'boolean)

(defcustom harness-ui-patch-review-ediff-tree t
  "Whether Ediff shows the changed files in a tree beside the two versions.
A window on the left of the frame, as a file tree shows beside the
editor: the directories and files with their marks and the file Ediff
compares marked, and under them the threads.  RET or a click on a file
compares it in place of the one under way, TAB folds a directory.  The
tree goes when Ediff ends.  t in Ediff's control panel shows or hides it
\(`harness-ui-patch-review-toggle-ediff-tree')."
  :type 'boolean)

(defcustom harness-ui-patch-review-ediff-tree-width 46
  "How many columns wide the tree beside Ediff is, at most.
In a narrow frame it takes 40% of it at the most, so the two versions
keep their room."
  :type 'natnum)

(defcustom harness-ui-patch-review-markdown t
  "Whether the comments of a review are drawn as Markdown.
The user writes a comment in a buffer and an agent in its tool call,
and either may use Markdown: emphasis, code and fenced blocks of it,
lists, quotes, tables, links.  Drawn as Markdown they show rendered,
as a message does in the chat, in the threads view and under the
lines of Ediff, and a thread named by its first words -- a row of the
report, a closed thread -- shows them without the markers.  A line
break stays one, as in the comments of a code host.  Nil draws what
was typed, markers and all.  Editing a comment always shows its
Markdown."
  :type 'boolean)

(defface harness-ui-patch-review-plus-face '((t :inherit diff-indicator-added))
  "Counts of added lines, and the status of an added file, in a report.")
(defface harness-ui-patch-review-minus-face '((t :inherit diff-indicator-removed))
  "Counts of deleted lines, and the status of a deleted file, in a report.")
(defface harness-ui-patch-review-seen-face '((t :inherit shadow))
  "The mark of a file seen in Ediff but not approved, in a report.
Dim, beside the approved mark's bold green: looking at a file is not
approving it, and only an approved file is skipped.")
;; The harness updates by reloading in place, and a `defface' that is
;; defined already is not read again: the face stays as it was (green, as
;; the approved mark) until Emacs restarts.  The dim mark is the default
;; now, so it is set here too, unless the user customized the face.
(unless (or (get 'harness-ui-patch-review-seen-face 'customized-face)
            (get 'harness-ui-patch-review-seen-face 'saved-face)
            (get 'harness-ui-patch-review-seen-face 'theme-face))
  (face-spec-set 'harness-ui-patch-review-seen-face '((t :inherit shadow))
                 'face-defface-spec))
(defface harness-ui-patch-review-approved-face '((t :inherit success :weight bold))
  "The mark of a file approved for this review, in a report.")
(defface harness-ui-patch-review-comments-face '((t :inherit bold))
  "The count of comments on a file, in a report.")
(defface harness-ui-patch-review-current-face '((t :inherit highlight :extend t))
  "The row of the file Ediff compares, in the tree beside it.")
;;;; Data

(cl-defstruct (harness-ui-patch-review--review
               (:constructor harness-ui-patch-review--review-create)
               (:conc-name harness-ui-patch-review--r-)
               (:copier nil))
  "The review of a task's changes, which the task's report shows.
ID and TASK are the task's, as last heard.  DIR is the repository the
branch is read in, BRANCH the task's branch and BASE the branch it was
made from.  SELECTOR says which diff the report shows: nil, the branch
against its merge base with BASE; `since-review', the branch against
where it was when the work was last handed in for review; a string, the
revisions the reviewer typed (`harness-ui-patch-review--parse-spec').
SHOWN-SELECTOR is the selector FILES were read for, which is SELECTOR
once the reading is done.  MERGE-BASE and TIP are the commits that diff
compares -- for the nil selector the merge base and the branch's tip --
OLD-NAME and NEW-NAME what they are called, FILES what the diff of the
two holds.  BRANCH-BASE, BRANCH-TIP and BRANCH-FILES are the branch's
whole change, against its merge base with BASE: the same as MERGE-BASE,
TIP and FILES for the nil selector, and what the version of SET is
always.  SELECTION-ERROR says why the diff the reviewer chose could not
be read, when it could not.  SET is the change set of the review
\(`harness-ui-patch-review--set'): its versions, the newest being the
branch at BRANCH-TIP, with BRANCH-FILES, and the threads of comments,
which the harness keeps; SYNCED is non-nil once they were fetched from
it.  SEEN holds the files seen in Ediff, APPROVED those the reviewer
accepted, both by `harness-ui-patch-review--seen-key' -- a
file the branch changes again is neither -- and both kept by the harness
\(`harness-ui-patch-review--load-viewed'); ASSUMED, when the harness took
files as viewed without their being looked at, says which commit and why,
as `patch-review/viewed' gives it.  PLACEMENTS says where each
thread is now, in the newest version of its file, by the thread's id:
the line it is on there and whether the line moved, changed or stayed
\(`change-review-diff-place'); PLACING is the reading of the files that
places them, while it runs.  SINCE says for each commented file, by its
path, whether it `changed' or stayed the `same' since the reviewer's
last comment on it.  TREE, non-nil while the files show as a tree; FOLDED holds the
directories (their paths) folded in it.
SHOW, non-nil when the review is shown for a task no longer waiting for
one, opened from its session's history.  DIRTY is non-nil when the
task's worktree has changes not committed.  LOADING is non-nil while the
branch is read, ERROR what the last reading failed with.  STARTED is
non-nil once the review asked for the branch and the threads, LOADED-AT
when the branch was last read.  The changes show on SURFACES: POPOUT is
the report they show in, BANNERS the chat buffers whose review banner
shows them, TREE-BUFFER the tree beside Ediff.  ORIGIN is the buffer an
Ediff was started from, where point goes back to when it ends.  EDIFF is
the comparison under way: a plist of :index, the buffers :a, :b and
:control, the :windows to give back as it ends, the first line :start
the report's window showed, the :box window of the report kept beside it,
:reached, non-nil once the reviewer was at the last difference, and
:unapproved, non-nil once the reviewer took the file's approval off
\(leaving does not approve it again).
GONE is non-nil once the task went, done or deleted, while its Ediff
showed.  SNAPSHOTS holds the review as it was at earlier commits of the
branch, by the commit, each a promise of a copy of this review with the
files and the places of the threads of that commit
\(`harness-ui-patch-review--snapshot'); SNAPSHOT is non-nil in such a
copy, the commit it is of.  The comments written against that commit are
about its code, which the branch has gone past."
  id task dir branch base merge-base tip files
  selector shown-selector old-name new-name
  branch-base branch-tip branch-files selection-error
  (seen (make-hash-table :test 'equal))
  (approved (make-hash-table :test 'equal))
  assumed set synced
  (placements (make-hash-table :test 'equal))
  placing
  (since (make-hash-table :test 'equal))
  (tree harness-ui-patch-review-file-tree)
  (folded (make-hash-table :test 'equal))
  show dirty loading error started
  popout banners tree-buffer origin ediff gone
  (snapshots (make-hash-table :test 'equal))
  snapshot)

(defvar harness-ui-patch-review--reviews (make-hash-table :test 'equal)
  "Task id -> the review of its changes.")

(defvar-local harness-ui-patch-review--review nil
  "In an Ediff control panel of a review, the review.")

(defvar-local harness-ui-patch-review--index nil
  "In an Ediff control panel of a review, the index of the file it compares.")

(defvar-local harness-ui-patch-review--next-file-offer nil
  "In an Ediff control panel, non-nil when the next difference would go on.
It says the last difference was reached once, so a second n goes to the
next file instead of staying there.")

(defvar-local harness-ui-patch-review--box-limit nil
  "In a report shown beside an Ediff, the height limit it had before: (LIMIT).
Nil while the report is not limited.")

(defvar-local harness-ui-patch-review--drawn-size nil
  "In a version Ediff compares, what its threads were drawn to.
\(WIDTH . MAX-LINES), the window's room at the last drawing
\(`change-review-ui-current-size'); the drawing is made again when the
window has another.")

(defvar harness-ui-patch-review--active nil
  "Non-nil while the module is on: reports show the changes.")

(defvar harness-ui-patch-review--drawing nil
  "Non-nil while a report draws the changes: nothing draws it again then.")

(defun harness-ui-patch-review--short (sha)
  "Return commit or blob SHA shortened, or \"none\" for nil."
  (cond ((not (stringp sha)) "none")
        ((> (length sha) 7) (substring sha 0 7))
        (t sha)))

(defun harness-ui-patch-review--title (review)
  "Return the title of REVIEW's task, as the board shows it."
  (or (harness-ui-task-title (harness-ui-patch-review--r-task review))
      (harness-ui-patch-review--r-id review)))

(defun harness-ui-patch-review--reviewing-p (task)
  "Non-nil when TASK waits for review, not archived."
  (and task
       (equal (plist-get task :state) "review")
       (not (harness-json-true-p (plist-get task :archived)))))

(defun harness-ui-patch-review--current ()
  "Return the review of this Ediff control panel.
An Ediff that began before the harness was updated holds a review of
the older version's layout (`harness-ui-patch-review--stale-p'), which
reads wrong; it is no review any more, and `ediff-quit' ends it."
  (let ((review harness-ui-patch-review--review))
    (cond ((null review) (user-error "Not an Ediff of a task's changes"))
          ((harness-ui-patch-review--stale-p review)
           (user-error "This Ediff began before the harness was updated and its review is gone: M-x ediff-quit ends it, and the changes open again from the report"))
          (t review))))

(defun harness-ui-patch-review--fail (format-string &rest args)
  "Return a promise rejected with the error FORMAT-STRING and ARGS make."
  (harness-rejected (list 'error (apply #'format-message format-string args))))

(defun harness-ui-patch-review--plural (count word)
  "Return COUNT WORD, WORD in the plural unless COUNT is 1."
  (format "%d %s%s" count word (if (= count 1) "" "s")))

;;;; The change set of a review

(cl-defstruct (harness-ui-patch-review--set
               (:include change-review-set)
               (:constructor harness-ui-patch-review--make-set (&key id title))
               (:copier nil))
  "The change set of a task's review, in this Emacs.
REVIEW is the review it belongs to.  The harness keeps the threads: what
the user does in the set is performed here at once and sent there
\(`change-review-dispatch'), and what happens there -- an agent's
comment, the drafts sent -- is performed here too
\(`patch-review/changed').  The files of its versions are read here,
from the repository."
  review)

;;;; Reviews an older definition made

;; A reload replaces the definitions and keeps what runs, the reviews with
;; it, and updating the harness is a reload.  A struct that gained a slot
;; reads the instance its older definition made wrong -- one slot for
;; another, or past its end, "args out of range" -- and every draw of the
;; review, every event about its task, runs into it: the report fails to
;; draw, and a listener that fails keeps the ones after it from hearing
;; what the task did, the review banner's among them.  So a review keeps
;; the layout of the structs it is made of as it was made, and a load drops
;; every review made under another, whichever version it came from: one
;; made by a version that did not keep this has nothing to say for it, and
;; goes the same.  What it showed is drawn again from what the harness
;; keeps -- the threads, the files viewed -- and from the branch.

(defconst harness-ui-patch-review--layout-structs
  '(harness-ui-patch-review--review harness-ui-patch-review--set
    change-review-author change-review-location change-review-comment
    change-review-thread change-review-file change-review-version change-review-set)
  "The structs a review is made of: its own, its set, and what the set holds.
The set of a review keeps the threads and the versions of the library,
so a slot the library's structs gain makes the reviews of the older
layout as wrong as one of the review's own.")

(defun harness-ui-patch-review--layout-now ()
  "Return what the structs of a review look like in the definitions loaded.
A list of (STRUCT SLOT...), the slots in the order they lie."
  (mapcar (lambda (struct)
            (cons struct (mapcar #'car (cdr (cl-struct-slot-info struct)))))
          harness-ui-patch-review--layout-structs))

(defvar harness-ui-patch-review--layout nil
  "What the structs of a review look like in the definitions now loaded.
See `harness-ui-patch-review--layout-now'; set as this file loads.")
(setq harness-ui-patch-review--layout (harness-ui-patch-review--layout-now))

(defvar harness-ui-patch-review--made-with (make-hash-table :test 'eq :weakness 'key)
  "Review -> `harness-ui-patch-review--layout' as it was when the review was made.
Beside the review, not in it, so a review of any layout can be asked
without reading a slot it may not have.")

(defun harness-ui-patch-review--stale-p (review)
  "Non-nil when REVIEW was made under another layout of its structs than this one.
Such a review cannot be read with the accessors: they would read it
wrong, or past its end."
  (not (and (harness-ui-patch-review--review-p review)
            (equal (gethash review harness-ui-patch-review--made-with)
                   harness-ui-patch-review--layout))))

(defvar harness-ui-patch-review--dropped nil
  "The tasks whose review was dropped for being made under an older layout.
The module draws what showed them again once it is ready to
\(`harness-ui-patch-review--redraw-dropped').")

(defun harness-ui-patch-review--discard-stale (id review)
  "Drop REVIEW of task ID, which an older layout of the structs made.
Only what can be done without reading it: it leaves the table, and the
library's views that hold its set stop pointing at it, as they would
read it wrong.  Its Ediff and the buffers of that, which only a
review of this layout can end, are left to their own quit."
  (remhash id harness-ui-patch-review--reviews)
  (dolist (set change-review-ui-sets)
    (ignore-errors
      (when (and (harness-ui-patch-review--set-p set)
                 (eq (harness-ui-patch-review--set-review set) review))
        (setf (harness-ui-patch-review--set-review set) nil)))))

(defun harness-ui-patch-review--drop-stale-reviews ()
  "Drop the reviews an older layout of the structs made; return their task ids.
Run as the file loads, so no code of this definition meets one."
  (let (stale)
    (maphash (lambda (id review)
               (when (harness-ui-patch-review--stale-p review)
                 (push (cons id review) stale)))
             harness-ui-patch-review--reviews)
    (pcase-dolist (`(,id . ,review) stale)
      (harness-ui-patch-review--discard-stale id review)
      (cl-pushnew id harness-ui-patch-review--dropped :test #'equal))
    (when stale
      (harness-log 'info "patch review: dropped %d review%s an older layout made, to be made again"
                   (length stale) (if (cdr stale) "s" "")))
    (mapcar #'car stale)))

(harness-ui-patch-review--drop-stale-reviews)

(cl-defmethod change-review-dispatch ((set harness-ui-patch-review--set) op)
  (prog1 (change-review-apply set op)
    (harness-ui-call "_harness/patch-review/apply"
                     (list :task-id (change-review-set-id set) :op op)
                     #'ignore
                     (lambda (err)
                       (message "Could not keep the review with the harness: %s"
                                (harness-error-message err))))))

(cl-defmethod change-review-save ((_set harness-ui-patch-review--set))
  nil)

;; Only the user reviews: the harness's own half of the review writes as
;; the user too, under the name its Emacs guesses, which need not be the
;; name this one has.
(cl-defmethod change-review-own-author-p ((_set harness-ui-patch-review--set) author)
  (and author (eq (change-review-author-kind author) 'user)))

(cl-defmethod change-review-follow-author ((_set harness-ui-patch-review--set) author)
  (harness-ui-patch-review--open-conversation (change-review-author-session author)
                                              (change-review-author-tool-call author)))

(cl-defmethod change-review-placement ((set harness-ui-patch-review--set) thread &optional version)
  (or (and (null version)
           (when-let* ((review (harness-ui-patch-review--set-review set)))
             (gethash (change-review-thread-id thread) (harness-ui-patch-review--r-placements review))))
      (cl-call-next-method)))

;; What a comment is written against is what its author saw: in an Ediff,
;; the commit it shows -- the branch's end, or an earlier commit's code.
(cl-defmethod change-review-default-revision ((set harness-ui-patch-review--set))
  (or (and (harness-ui-patch-review--review-p harness-ui-patch-review--review)
           (eq set (harness-ui-patch-review--r-set harness-ui-patch-review--review))
           (harness-ui-patch-review--r-tip harness-ui-patch-review--review))
      (cl-call-next-method)))

(cl-defmethod change-review-origin ((set harness-ui-patch-review--set) thread comment)
  (pcase-let* ((`(,location . ,exact) (change-review-kept-location thread comment))
               (revision (change-review-comment-revision comment))
               (review (harness-ui-patch-review--set-review set)))
    (if (or exact (null location) (null revision) (null review))
        ;; What the comment kept is the diff it was made on.
        (cl-call-next-method)
      ;; A reply, an agent's thread: the diff of the commit it was written on.
      (let ((view (harness-ui-patch-review--view-at review revision)))
        (cond
         ((harness-ui-patch-review--review-p view)
          (if-let* ((found (harness-ui-patch-review--location-in view thread)))
              (list :location found)
            (cl-call-next-method)))
         ((eq view 'pending)
          (list :location (harness-ui-patch-review--bare-location location)
                :note (format "reading the diff at %s…" (harness-ui-patch-review--short revision))))
         (t
          (let ((stale (cl-call-next-method)))
            (list :location (plist-get stale :location)
                  :note (format "%s: showing the lines the thread started on"
                                (plist-get view :failed))))))))))

(defun harness-ui-patch-review--target-place (set target)
  "Return (THREAD . LOCATION) for TARGET, a thread, a comment or a location of SET.
LOCATION is the thread's, or TARGET itself when it is one; either may be nil."
  (let* ((thread (cond ((change-review-thread-p target) target)
                       ((change-review-comment-p target)
                        (car (change-review-find-comment set (change-review-comment-id target))))))
         (location (cond (thread (change-review-thread-location thread))
                         ((change-review-location-p target) target))))
    (cons thread location)))

(defun harness-ui-patch-review--goto (side line)
  "Return (:SIDE . LINE) for a line of a version Ediff shows, or nil without LINE.
SIDE is `new' or `old', nil for `new'.  That is the form
`harness-ui-patch-review-ediff' takes a line to have in sight in."
  (and line (cons (intern (concat ":" (symbol-name (or side 'new)))) line)))

(cl-defmethod change-review-visit ((set harness-ui-patch-review--set) target &optional version)
  (let* ((review (harness-ui-patch-review--set-review set))
         (revision (harness-ui-patch-review--version-revision set version)))
    (if (and revision (not (change-review-same-revision-p
                            revision (harness-ui-patch-review--r-tip review))))
        ;; An earlier commit: the code as it was, when the comment was written.
        (harness-ui-patch-review--visit-at review target revision)
      (pcase-let* ((`(,thread . ,location) (harness-ui-patch-review--target-place set target))
                   (index (and location
                               (cl-position-if (lambda (file) (harness-ui-patch-review--location-file-p location file))
                                               (harness-ui-patch-review--r-files review))))
                   (placement (and thread (change-review-placement set thread))))
        (cond
         ((null location)
          (user-error (if thread
                          "The change as a whole is not a file this version changes"
                        "No thread to show")))
         ((null index)
          (user-error "%s is not a file this version changes" (change-review-location-label location)))
         (t
          (harness-ui-patch-review-ediff
           review index
           (harness-ui-patch-review--goto
            (or (plist-get placement :side) (change-review-location-side location))
            (or (plist-get placement :line) (change-review-location-line location))))))))))

;; The text of a comment is Markdown (`harness-ui-patch-review-markdown'),
;; drawn as the chat draws a message: in the threads view, under the
;; lines of Ediff and in the report's rows alike, as the library draws
;; every thread through these two.  What a person typed keeps its line
;; breaks, which the renderer joins unless told not to.
;;
;; A comment the renderer cannot take is drawn as it was typed, rather
;; than as an error that draws none of the review.
(defmacro harness-ui-patch-review--markdown-or (&rest body)
  "Return what BODY, which renders Markdown, returns.
Nil when the option is off or BODY fails: the caller then draws the
text as it was typed."
  (declare (indent 0))
  `(and harness-ui-patch-review-markdown
        (condition-case err
            (progn ,@body)
          (error (harness-log 'warn "patch review: a comment would not render as Markdown: %S" err)
                 nil))))

(cl-defmethod change-review-ui-body-lines ((_set harness-ui-patch-review--set) comment width)
  (or (harness-ui-patch-review--markdown-or
        (let ((harness-ui-markdown-hard-breaks t))
          ;; The id of a session the UI knows is a link to it, as in the chat.
          (mapcar (lambda (line)
                    (harness-ui-link-session-ids line #'harness-ui-markdown-code-at-p))
                  (harness-ui-markdown-render-lines (change-review-comment-body comment) width))))
      (cl-call-next-method)))

(cl-defmethod change-review-ui-body-summary ((_set harness-ui-patch-review--set) comment)
  (or (harness-ui-patch-review--markdown-or
        (harness-ui-markdown-summary (change-review-comment-body comment)))
      (cl-call-next-method)))

(defun harness-ui-patch-review--link-directory (review)
  "Return the directory a link to a file in a comment of REVIEW is relative to.
A comment names the files of the branch, the way a message of the
agent's does in its chat: where the task worked, its worktree, else the
repository the branch is read in."
  (let ((worktree (plist-get (harness-ui-patch-review--r-task review) :worktree)))
    (file-name-as-directory
     (expand-file-name
      (if (and (stringp worktree) (not (string-empty-p worktree))
               (not (file-remote-p worktree)) (file-directory-p worktree))
          worktree
        (or (harness-ui-patch-review--r-dir review) default-directory))))))

(cl-defmethod change-review-send ((set harness-ui-patch-review--set))
  (let* ((review (harness-ui-patch-review--set-review set))
         (popout (harness-ui-patch-review--feedback-box review))
         (window (or (get-buffer-window popout t)
                     (progn (pop-to-buffer popout) (get-buffer-window popout t)))))
    (when (window-live-p window) (select-window window))
    (goto-char (buffer-local-value 'harness-compose-end popout))
    (message "%s go with the feedback: %s sends it"
             (harness-ui-patch-review--plural (length (change-review-drafts set)) "draft")
             (substitute-command-keys "\\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit]"))))

(defun harness-ui-patch-review--open-conversation (session-id call-id)
  "Show the session SESSION-ID, at the tool call CALL-ID when it has one."
  (unless (and (stringp session-id) (fboundp 'harness-ui-display-session))
    (user-error "The session of this comment is not known here"))
  (let ((buffer (harness-ui-display-session session-id)))
    (when (and call-id (buffer-live-p buffer))
      (with-current-buffer buffer
        (if-let* ((pos (harness-ui-report--call-position (list :call-id call-id))))
            (progn (goto-char pos)
                   (when (eq (window-buffer) buffer) (recenter)))
          (message "The call %s is not in this session's transcript" call-id))))))

(defun harness-ui-patch-review--location-file-p (location file)
  "Return non-nil when LOCATION is on FILE: at its path, or the one it had."
  (let ((path (and location (change-review-location-file location))))
    (and path
         (or (equal path (change-review-file-path file))
             (and (change-review-file-old-path file)
                  (equal path (change-review-file-old-path file)))))))

(defun harness-ui-patch-review--thread-file-p (thread file)
  "Return non-nil when THREAD is about FILE: at its path, or the one it had."
  (harness-ui-patch-review--location-file-p (change-review-thread-location thread) file))

(defun harness-ui-patch-review--file-threads (review file)
  "Return the threads of REVIEW's set that are about FILE, by line."
  ;; A copy: `cl-remove-if-not' returns the set's own list when every
  ;; thread is about FILE, and sorting that would reorder the set.
  (sort (copy-sequence
         (cl-remove-if-not (lambda (thread) (harness-ui-patch-review--thread-file-p thread file))
                           (change-review-set-threads (harness-ui-patch-review--r-set review))))
        (lambda (a b) (< (or (change-review-thread-line a) 0) (or (change-review-thread-line b) 0)))))

(defun harness-ui-patch-review--attach-files (review)
  "Give the version REVIEW's branch ends at the files of the branch's change.
That is the version the harness recorded when the task came to review;
if it has none yet, the version is made here.  Its files are those of the
whole change, against the merge base with the branch it was made from,
whichever diff the report shows (`harness-ui-patch-review--r-selector')."
  (when-let* ((tip (harness-ui-patch-review--r-branch-tip review))
              ;; Not when the whole change could not be read, beside a
              ;; diff the reviewer chose that could.
              ((harness-ui-patch-review--r-branch-base review))
              (set (harness-ui-patch-review--r-set review)))
    (let ((files (harness-ui-patch-review--r-branch-files review)))
      (if-let* ((version (change-review-find-version set tip)))
          (setf (change-review-version-files version) files)
        (let ((task (harness-ui-patch-review--r-task review)))
          (change-review-add-version
           set (change-review-make-version
                :id tip :tip tip :base (harness-ui-patch-review--r-branch-base review)
                :time (or (plist-get task :report-at) (float-time))
                :title (harness-ui-patch-review--title review)
                :files files)))))))

(defun harness-ui-patch-review--viewed-keys (entries)
  "Return the seen keys of ENTRIES, files as the harness keeps them viewed."
  (cl-loop for entry in (append entries nil)
           when (and (consp entry) (stringp (plist-get entry :path)))
           collect (cons (plist-get entry :path)
                         (let ((blob (plist-get entry :blob))) (and (stringp blob) blob)))))

(defun harness-ui-patch-review--load-viewed (review &optional replace)
  "Fetch the files viewed in REVIEW's task from the harness, and show them.
The harness keeps the files seen in Ediff and those approved, and says
when it took files as viewed without their being looked at
\(`harness-ui-patch-review-assume-viewed').  They add to the marks made
meanwhile, unless REPLACE: then they are the marks."
  (let ((id (harness-ui-patch-review--r-id review)))
    (when id
      (harness-ui-call
       "_harness/patch-review/viewed" (list :task-id id)
       (lambda (data)
         (when (eq review (gethash id harness-ui-patch-review--reviews))
           (when replace
             (clrhash (harness-ui-patch-review--r-seen review))
             (clrhash (harness-ui-patch-review--r-approved review)))
           (dolist (key (harness-ui-patch-review--viewed-keys (plist-get data :seen)))
             (puthash key t (harness-ui-patch-review--r-seen review)))
           (dolist (key (harness-ui-patch-review--viewed-keys (plist-get data :approved)))
             (puthash key t (harness-ui-patch-review--r-approved review)))
           (setf (harness-ui-patch-review--r-assumed review)
                 (let ((assumed (plist-get data :assumed))) (and (consp assumed) assumed)))
           (harness-ui-patch-review--refresh review)))
       (lambda (err)
         (message "Could not read the files viewed from the harness: %s" (harness-error-message err)))))))

(defun harness-ui-patch-review--sync (review)
  "Fetch REVIEW's threads and versions from the harness, and show them.
The harness keeps them, and made the set of a task whose earlier rounds
of feedback were text when it was first asked for it.  The files viewed
come with them."
  (let ((set (harness-ui-patch-review--r-set review))
        (id (harness-ui-patch-review--r-id review)))
    (harness-ui-patch-review--load-viewed review)
    (harness-ui-call
     "_harness/patch-review/get" (list :task-id id)
     (lambda (data)
       (when (eq review (gethash id harness-ui-patch-review--reviews))
         (change-review-set-from-data data set)
         (setf (change-review-set-title set) (harness-ui-patch-review--title review)
               (harness-ui-patch-review--r-synced review) t)
         (harness-ui-patch-review--attach-files review)
         (change-review-ui-refresh set)
         (harness-ui-patch-review--refresh review)
         (when (harness-ui-patch-review--r-tip review)
           (harness-ui-patch-review--place-threads review))))
     (lambda (err)
       (message "Could not read the threads of the review: %s" (harness-error-message err))))))

;; The threads of a set drawn in a surface -- the report, the banner, the
;; tree beside Ediff -- are a view of the set like the library's own
;; (`change-review-ui--redraw-function' of the surface's buffer), so an
;; operation that changed the set draws them again through the library
;; (`change-review-changed-functions').

(defun harness-ui-patch-review--pending-p (task)
  "Return non-nil when the review of TASK has drafts to send with its feedback.
On `harness-ui-review-pending-functions'."
  (when-let* ((review (and (plist-get task :id)
                           (harness-ui-patch-review--known (plist-get task :id))))
              (set (harness-ui-patch-review--r-set review)))
    (and (change-review-drafts set) t)))

;;;; Where the branch is

(defun harness-ui-patch-review--repository (task)
  "Return the local directory TASK's branch can be read in, or nil.
That is its project, else its worktree, when it is a directory of this
machine: not for a harness elsewhere, and not over TRAMP."
  (unless (stringp harness-ui-connection-address)
    (cl-loop for dir in (list (plist-get task :project) (plist-get task :worktree))
             when (and (stringp dir) (not (string-empty-p dir))
                       (not (file-remote-p dir)) (file-directory-p dir))
             return (file-name-as-directory (expand-file-name dir)))))

(defun harness-ui-patch-review--offered-p (task)
  "Non-nil when TASK waits for review on a branch this Emacs can read."
  (and (harness-ui-patch-review--reviewing-p task)
       (not (harness-string-blank-p (plist-get task :branch)))
       (harness-ui-patch-review--repository task)
       t))

(defun harness-ui-patch-review--why-not (task)
  "Return why TASK's changes cannot be reviewed here."
  (let ((title (if task (harness-ui-task-title task) "This task")))
    (cond ((null task) "No task waits for review here")
          ((not (equal (plist-get task :state) "review")) (format "%s does not wait for review" title))
          ((harness-json-true-p (plist-get task :archived)) (format "%s is archived" title))
          ((harness-string-blank-p (plist-get task :branch))
           (format "%s has no branch of its own: it worked in the main checkout" title))
          ((stringp harness-ui-connection-address)
           (format "The harness runs at %s: the repository of %s is not on this machine"
                   harness-ui-connection-address title))
          (t (format "The repository of %s is not a directory of this machine" title)))))

;;;; Git

(defun harness-ui-patch-review--decode (bytes &optional coding)
  "Return BYTES, as git wrote them, decoded with CODING (default UTF-8)."
  (decode-coding-string (if (multibyte-string-p bytes)
                            (condition-case nil (string-to-unibyte bytes)
                              (error (encode-coding-string bytes 'utf-8)))
                          bytes)
                        (or coding 'utf-8)))

(defun harness-ui-patch-review--git (dir &rest args)
  "Return a promise of what git, run in DIR with ARGS, writes: its bytes.
It rejects with git's message when git fails.  Git takes no optional
lock, so a status does not get in the way of the task's own git."
  (let ((coding-system-for-read 'binary))
    (harness-then
     (harness-run-command (append '("git" "--no-pager" "-c" "core.quotePath=false") args)
                          :cwd dir :timeout 60 :name "harness-patch-review"
                          :env '(("GIT_OPTIONAL_LOCKS" . "0")))
     (lambda (result)
       (if (eql (plist-get result :exit) 0)
           (plist-get result :stdout)
         (let ((err (string-trim (harness-ui-patch-review--decode (plist-get result :stderr)))))
           (harness-ui-patch-review--fail
            "git %s: %s" (car args)
            (cond ((not (string-empty-p err)) (harness-first-line err))
                  ((eq (plist-get result :exit) 'timeout) "timed out")
                  (t (format "exit status %s" (plist-get result :exit)))))))))))

(defun harness-ui-patch-review--rev (dir rev missing)
  "Return a promise of the commit REV names in DIR; it rejects with MISSING."
  (harness-then (harness-ui-patch-review--git dir "rev-parse" "--verify" "--quiet" rev)
                (lambda (out) (string-trim (harness-ui-patch-review--decode out)))
                (lambda (_) (harness-ui-patch-review--fail "%s" missing))))

(defun harness-ui-patch-review--merge-base (dir base tip)
  "Return a promise of (NAME . COMMIT), the merge base of TIP with BASE in DIR.
BASE is the branch the task's branch was made from.  When it is not
known, or no longer there, it is what DIR has checked out: NAME HEAD."
  (let ((with (lambda (name)
                (harness-then (harness-ui-patch-review--git dir "merge-base" name tip)
                              (lambda (out) (cons name (string-trim (harness-ui-patch-review--decode out))))))))
    (harness-catch (if (harness-string-blank-p base)
                       (funcall with "HEAD")
                     (harness-catch (funcall with base) (lambda (_) (funcall with "HEAD"))))
                   (lambda (_)
                     (harness-ui-patch-review--fail "The branch has no commit in common with %s"
                                                    (if (harness-string-blank-p base) "HEAD" base))))))

(defun harness-ui-patch-review--parse-raw (raw)
  "Return the files of RAW, what `git diff --raw -z' wrote, in its order."
  (let ((fields (split-string raw "\0" t))
        files)
    (while fields
      (let ((head (pop fields)))
        (when (string-match "\\`:\\([0-7]+\\) \\([0-7]+\\) \\([0-9a-f]+\\) \\([0-9a-f]+\\) \\([A-Z]\\)" head)
          (let* ((status (match-string 5 head))
                 (old-sha (match-string 3 head))
                 (new-sha (match-string 4 head))
                 (old-mode (match-string 1 head))
                 (new-mode (match-string 2 head))
                 (two (member status '("R" "C")))
                 (first (pop fields))
                 (second (and two (pop fields))))
            (push (change-review-make-file
                   :status status
                   :path (or second first)
                   :old-path (and two first)
                   :old-mode old-mode :new-mode new-mode
                   :old-blob (and (not (string-match-p "\\`0+\\'" old-sha)) old-sha)
                   :new-blob (and (not (string-match-p "\\`0+\\'" new-sha)) new-sha))
                  files)))))
    (nreverse files)))

(defun harness-ui-patch-review--split-patch (patch)
  "Return PATCH, a diff, cut into the parts of its files, in order.
Each part starts with its `diff --git' line; no line of a hunk can."
  (let ((starts nil) (pos 0))
    (while (string-match "^diff --git " patch pos)
      (push (match-beginning 0) starts)
      (setq pos (match-end 0)))
    (cl-loop for (start . rest) on (nreverse starts)
             collect (substring patch start (or (car rest) (length patch))))))

(defun harness-ui-patch-review--count (file)
  "Count FILE's added and deleted lines in its patch, and see if it is binary."
  (let ((added 0) (deleted 0) (in-hunk nil) (binary nil))
    (dolist (line (split-string (or (change-review-file-patch file) "") "\n"))
      (cond ((string-prefix-p "@@" line) (setq in-hunk t))
            ((not in-hunk)
             (when (or (string-prefix-p "Binary files " line) (string-prefix-p "GIT binary patch" line))
               (setq binary t)))
            ((string-prefix-p "+" line) (cl-incf added))
            ((string-prefix-p "-" line) (cl-incf deleted))))
    (setf (change-review-file-added file) added
          (change-review-file-deleted file) deleted
          (change-review-file-binary file) binary)))

(defun harness-ui-patch-review--pair (files parts)
  "Give each of FILES its part of the patch, from PARTS, and count it.
The two come from diffs of the same commits, in the same order, a part
for each file; when their numbers differ, a file gets the part whose
first line names it, if any."
  (let ((in-order (= (length files) (length parts))))
    (dolist (file files)
      (let ((part (if in-order
                      (pop parts)
                    (let ((want (format "diff --git a/%s b/%s\n"
                                        (or (change-review-file-old-path file)
                                            (change-review-file-path file))
                                        (change-review-file-path file))))
                      (cl-find-if (lambda (p) (string-prefix-p want p)) parts)))))
        (setf (change-review-file-patch file) part)
        (harness-ui-patch-review--count file)))
    files))

(defun harness-ui-patch-review--read-diff (dir old new)
  "Return a promise of the files commit NEW changes against commit OLD in DIR.
They come in git's order, each with the part of the patch that is its own,
and counted."
  (harness-then
   (harness-all
    (list (harness-ui-patch-review--git dir "diff" "--raw" "-z" "-M" "--no-abbrev" old new)
          (harness-ui-patch-review--git dir "diff" "-M" "--no-color" "--no-ext-diff" "--no-textconv"
                                        "--src-prefix=a/" "--dst-prefix=b/" old new)))
   (lambda (outputs)
     (let ((files (harness-ui-patch-review--parse-raw
                   (harness-ui-patch-review--decode (nth 0 outputs)))))
       (harness-ui-patch-review--pair
        files (harness-ui-patch-review--split-patch (harness-ui-patch-review--decode (nth 1 outputs))))))))

;;;; The diff the reviewer chooses

(defun harness-ui-patch-review--parse-spec (spec)
  "Return (OLD NEW MERGE-BASE) for SPEC, a diff the reviewer typed.
SPEC names the revisions of the task's repository to compare as `git
diff' takes them:

  A..B     from A to B
  A...B    from the merge base of A and B to B
  A B      the same as A..B
  A        from A to the task's branch

OLD and NEW are the revisions as typed, nil for one left out: left out,
OLD is the branch the task was made from and NEW is the task's branch.
MERGE-BASE is non-nil for the three dots.  Signal a `user-error' for a
SPEC that names no revision, names more than two, or has one that starts
with a dash, which git would take for an option."
  (let* ((spec (string-trim (or spec "")))
         (three (string-search "..." spec))
         (two (and (null three) (string-search ".." spec)))
         (cut (or three two))
         (parts (if cut
                    (list (string-trim (substring spec 0 cut))
                          (string-trim (substring spec (+ cut (if three 3 2)))))
                  (split-string spec))))
    (when (or (null parts) (cl-every #'string-empty-p parts))
      (user-error "Name the revisions to compare, such as main..HEAD or a commit"))
    (when (> (length parts) 2)
      (user-error "A diff is between two revisions: %s names %d" spec (length parts)))
    (dolist (part parts)
      (when (string-prefix-p "-" part)
        (user-error "%s is not a revision: it starts with a dash" part)))
    (let ((old (car parts))
          (new (nth 1 parts)))
      (list (and old (not (string-empty-p old)) old)
            (and new (not (string-empty-p new)) new)
            (and three t)))))

(defun harness-ui-patch-review--missing-commit (dir revision)
  "Return what to say of REVISION, which names no commit in DIR."
  (format-message "There is no commit `%s' in %s" revision (abbreviate-file-name dir)))

(defconst harness-ui-patch-review--no-earlier-review
  "No earlier review of this task is known to compare with"
  "What is said when the diff since the last review is asked for and there is none.")

(defun harness-ui-patch-review--resolve-since (dir branch tip last-review)
  "Return a promise of the diff from the last review to TIP in DIR.
TIP is the tip of BRANCH.  LAST-REVIEW is a function of TIP giving
\(COMMIT . NAME) for where the branch was when its work was last handed
in, or nil when that is not known.  The promise resolves to a plist:
:kind `since-review', :old and :new, the commits compared, :old-name and
:new-name, what they are called."
  (let ((last (and last-review (funcall last-review tip))))
    (if (null last)
        (harness-ui-patch-review--fail "%s" harness-ui-patch-review--no-earlier-review)
      (harness-then
       (harness-ui-patch-review--rev
        dir (concat (car last) "^{commit}")
        (format-message "The commit of the last review, %s, is no longer in the repository"
                        (harness-ui-patch-review--short (car last))))
       (lambda (commit)
         (list :kind 'since-review :old commit :new tip :old-name (cdr last) :new-name branch))))))

(defun harness-ui-patch-review--resolve-spec (dir branch tip base spec)
  "Return a promise of the diff SPEC names in DIR.
It resolves to what `harness-ui-patch-review--resolve-since' gives.  SPEC
is what `harness-ui-patch-review--parse-spec' reads; BRANCH, TIP
and BASE are the task's: a revision left out of SPEC is the branch's tip,
or BASE.  The promise's :kind is `custom'."
  (condition-case err
      (pcase-let* ((`(,old ,new ,merge-base) (harness-ui-patch-review--parse-spec spec))
                   (old-name (or old (if (harness-string-blank-p base) "HEAD" base)))
                   (new-name (or new branch)))
        (harness-then
         (harness-all
          (list (harness-ui-patch-review--rev dir (concat old-name "^{commit}")
                                              (harness-ui-patch-review--missing-commit dir old-name))
                (if new
                    (harness-ui-patch-review--rev dir (concat new "^{commit}")
                                                  (harness-ui-patch-review--missing-commit dir new))
                  tip)))
         (lambda (commits)
           (let ((old-commit (nth 0 commits))
                 (new-commit (nth 1 commits)))
             (harness-then
              (if merge-base
                  (harness-then
                   (harness-catch (harness-ui-patch-review--git dir "merge-base" old-commit new-commit)
                                  (lambda (_)
                                    (harness-ui-patch-review--fail "%s and %s have no commit in common"
                                                                   old-name new-name)))
                   (lambda (out) (string-trim (harness-ui-patch-review--decode out))))
                (harness-resolved old-commit))
              (lambda (from)
                (list :kind 'custom :old from :new new-commit
                      :old-name old-name :new-name new-name)))))))
    (user-error (harness-ui-patch-review--fail "%s" (cadr err)))))

(defun harness-ui-patch-review--read-branch (dir branch base &optional worktree selector last-review)
  "Return a promise of what BRANCH changes, by default against its merge base.
The merge base is that of BRANCH with BASE.  DIR is the repository.
SELECTOR says what is compared instead:
`since-review', the branch against where it was when its work was last
handed in -- LAST-REVIEW, a function of the branch's tip, gives that
commit and its name, (COMMIT . NAME), or nil -- or a string, the
revisions the reviewer typed (`harness-ui-patch-review--parse-spec').

The promise resolves to a plist: :base, the branch the merge base is with
\(HEAD when BASE is not there), :merge-base and :tip, the commits
compared, :files, the files changed between them, :kind, `base',
`since-review' or `custom', :old-name and :new-name, what the two commits
are called, and :dirty, non-nil when WORKTREE, the branch's worktree, has
changes not committed.  Whichever the diff, :branch-base, :branch-tip and
:branch-files are those of the branch's whole change against its merge
base with BASE, which :merge-base, :tip and :files are for a nil SELECTOR."
  (harness-then
   (harness-ui-patch-review--rev dir (concat branch "^{commit}")
                                 (format-message "There is no branch `%s' in %s" branch (abbreviate-file-name dir)))
   (lambda (tip)
     (let* ((whole (harness-then
                    (harness-ui-patch-review--merge-base dir base tip)
                    (lambda (found)
                      (harness-then
                       (harness-ui-patch-review--read-diff dir (cdr found) tip)
                       (lambda (files)
                         (list :kind 'base :base (car found) :old (cdr found) :new tip
                               :old-name (car found) :new-name branch :files files))))))
            (picked (and selector
                         (harness-then
                          (if (eq selector 'since-review)
                              (harness-ui-patch-review--resolve-since dir branch tip last-review)
                            (harness-ui-patch-review--resolve-spec dir branch tip base selector))
                          (lambda (diff)
                            (harness-then
                             (harness-ui-patch-review--read-diff dir (plist-get diff :old) (plist-get diff :new))
                             (lambda (files) (append diff (list :files files))))))))
            (status (if worktree
                        (harness-catch (harness-ui-patch-review--git worktree "status" "--porcelain" "-z"
                                                                     "--untracked-files=no")
                                       (lambda (_) ""))
                      "")))
       (harness-then
        ;; The whole change is what the version is; a diff the reviewer
        ;; chose is shown whether or not it can be read.
        (harness-all (list (if picked (harness-catch whole (lambda (_) nil)) whole)
                           status
                           (or picked (harness-resolved nil))))
        (lambda (results)
          (let* ((whole (nth 0 results))
                 (shown (or (nth 2 results) whole)))
            (list :base (or (plist-get whole :base) (if (harness-string-blank-p base) "HEAD" base))
                  :merge-base (plist-get shown :old) :tip (plist-get shown :new)
                  :files (plist-get shown :files)
                  :kind (plist-get shown :kind)
                  :old-name (plist-get shown :old-name) :new-name (plist-get shown :new-name)
                  :dirty (not (string-empty-p (nth 1 results)))
                  :branch-base (plist-get whole :old) :branch-tip tip
                  :branch-files (plist-get whole :files)))))))))

(defun harness-ui-patch-review--blob (review sha)
  "Return a promise of the text of blob SHA in REVIEW's repository, \"\" for nil."
  (if (null sha)
      (harness-resolved "")
    (harness-then (harness-ui-patch-review--git (harness-ui-patch-review--r-dir review) "cat-file" "blob" sha)
                  (lambda (bytes) (harness-ui-patch-review--decode bytes 'undecided)))))

;;;; Reviews

(defun harness-ui-patch-review--version-tip (version)
  "Return the commit VERSION of a review ends at."
  (or (change-review-version-tip version) (change-review-version-id version)))

(defun harness-ui-patch-review--handed-in-again-p (review version)
  "Non-nil when REVIEW's task was sent back since VERSION was handed in.
The harness records the round of feedback a version was handed in at
\(`harness-patch-review--version-op'); a task sent back since then, whose
branch has no new commit, comes back to review as the same version.  A
version that has no round -- one this Emacs made for a branch it read --
says nothing."
  (let ((round (plist-get (change-review-version-meta version) :round))
        (rounds (length (plist-get (harness-ui-patch-review--r-task review) :feedback))))
    (and (integerp round) (> rounds round))))

(defun harness-ui-patch-review--last-review (review tip)
  "Return (COMMIT . NAME) for where the branch was at the last review, or nil.
REVIEW is the review, TIP where the branch is now.  Each time the work
was handed in -- looked at, in the report -- is a version of REVIEW's
set, named by the commit the branch was at.  The last review is the
newest version that is not TIP's own, among those before it when TIP is
a version: the work the reviewer has seen, so what the branch changed
since is what they have not.  A task sent back whose branch has no new
commit was handed in again at TIP: that is the last review too, and
nothing changed since.  COMMIT is that of the version, NAME its name
\(\"v1\"); nil when the set knows no version to compare with."
  (let* ((versions (and (harness-ui-patch-review--r-set review)
                        (change-review-set-versions (harness-ui-patch-review--r-set review))))
         (here (cl-position tip versions :key #'harness-ui-patch-review--version-tip :test #'equal))
         (earlier (cl-find tip (if here (cl-subseq versions 0 here) versions)
                           :key #'harness-ui-patch-review--version-tip :test-not #'equal :from-end t))
         (version (or earlier
                      (and here (harness-ui-patch-review--handed-in-again-p review (nth here versions))
                           (nth here versions)))))
    (and version
         (cons (harness-ui-patch-review--version-tip version) (change-review-version-name version)))))

(defun harness-ui-patch-review--known (id)
  "Return the review of task ID, or nil when it has none.
One an older layout of the structs made, which a reload could not drop
\(`harness-ui-patch-review--drop-stale-reviews'), is dropped here."
  (let ((review (gethash id harness-ui-patch-review--reviews)))
    (if (and review (harness-ui-patch-review--stale-p review))
        (progn (harness-ui-patch-review--discard-stale id review) nil)
      review)))

(defun harness-ui-patch-review--review-for (task)
  "Return the review of TASK, made now when it has none."
  (let* ((id (plist-get task :id))
         (review (or (harness-ui-patch-review--known id)
                     (let ((made (harness-ui-patch-review--review-create
                                  :id id :tree harness-ui-patch-review-file-tree)))
                       (puthash made harness-ui-patch-review--layout
                                harness-ui-patch-review--made-with)
                       (puthash id made harness-ui-patch-review--reviews)))))
    (setf (harness-ui-patch-review--r-task review) task)
    (if-let* ((set (harness-ui-patch-review--r-set review)))
        (setf (change-review-set-title set) (harness-ui-patch-review--title review))
      (let ((set (harness-ui-patch-review--make-set :id id :title (harness-ui-patch-review--title review))))
        (setf (harness-ui-patch-review--set-review set) review
              (harness-ui-patch-review--r-set review) set)))
    review))

(defun harness-ui-patch-review--window-places (popout)
  "Return where the windows showing POPOUT that are not selected have point.
A list of (WINDOW . OFFSET): OFFSET is where in the feedback box point is,
nil when it is above it.  The report drawing again leaves those windows
without a place."
  (with-current-buffer popout
    (cl-loop for window in (get-buffer-window-list popout nil t)
             unless (eq window (selected-window))
             collect (cons window
                           (and (harness-compose-live-p)
                                (harness-compose-in-p (window-point window))
                                (- (window-point window) harness-compose-start))))))

(defun harness-ui-patch-review--restore-places (popout places)
  "Give the windows showing POPOUT the places PLACES say.
PLACES is what `harness-ui-patch-review--window-places' returned.  A
window that had point in the box shows the box again, ending the
window, point where it was in it; any other shows what it did, from where
the report's drawing put its start."
  (when (buffer-live-p popout)
    (with-current-buffer popout
      (pcase-dolist (`(,window . ,offset) places)
        (when (and (window-live-p window) (eq (window-buffer window) popout))
          (if (and offset (harness-compose-live-p))
              (harness-ui-patch-review--scroll-box window (cons offset offset))
            (set-window-point window (window-start window))))))))

(defun harness-ui-patch-review--refresh-popout (review)
  "Draw the report REVIEW shows in again, when it is open.
Not while it draws: what it draws is current then.  A window beside an
Ediff, which shows the feedback box, goes on showing it."
  (unless (or harness-ui-patch-review--drawing (harness-ui-patch-review--r-snapshot review))
    (let ((popout (harness-ui-patch-review--r-popout review)))
      (when (buffer-live-p popout)
        (let ((places (harness-ui-patch-review--window-places popout)))
          (harness-ui-popout-refresh (buffer-local-value 'harness-ui-popout-key popout))
          (harness-ui-patch-review--restore-places popout places))))))

(defun harness-ui-patch-review--refresh (review &optional now)
  "Draw again every surface the changes of REVIEW show on that is open.
That is the report, the review banners of the task's session and the
tree beside Ediff.  Not while one draws: what it draws is current then.
The banners are drawn once however often this is asked for, a moment
later, as the tail of a chat is long to draw; at once with NOW."
  (unless harness-ui-patch-review--drawing
    (harness-ui-patch-review--refresh-popout review)
    (harness-ui-patch-review--draw-tree review)
    ;; A task that left review has no banner to draw: its chats forget it.
    (setf (harness-ui-patch-review--r-banners review)
          (and (harness-ui-patch-review--reviewing-p (harness-ui-patch-review--r-task review))
               (cl-remove-if-not #'buffer-live-p (harness-ui-patch-review--r-banners review))))
    (when (harness-ui-patch-review--r-banners review)
      (if now
          (harness-ui-patch-review--redraw-banners review)
        (harness-debounce (list 'harness-ui-patch-review-banner (harness-ui-patch-review--r-id review))
                          0.05 #'harness-ui-patch-review--redraw-banners review)))))

(defun harness-ui-patch-review--redraw-banners (review)
  "Draw the review banners of REVIEW's task again, in the chats that show them."
  (when (eq review (gethash (harness-ui-patch-review--r-id review) harness-ui-patch-review--reviews))
    (dolist (buffer (harness-ui-patch-review--r-banners review))
      (when (buffer-live-p buffer)
        (harness-ui-patch-review--redraw-chat buffer)))))

(defvar harness-ui-patch-review--opening-box nil
  "Non-nil while the report opens only for the box beside Ediff.
The branch was read when the files came to show, and what Ediff compares
must not change under it, so the report that opens reads nothing.")

(defun harness-ui-patch-review--ensure-loaded (review &optional fresh)
  "Have REVIEW read its branch and fetch its threads from the harness, once.
The first surface that draws the changes starts it; the others find it
under way or done.  A surface that opens afresh -- FRESH, a report
opened anew -- reads the branch again, unless it opens only for the box
beside Ediff (`harness-ui-patch-review--opening-box')."
  (cond
   ((harness-ui-patch-review--r-loading review) nil)
   ((or (not (harness-ui-patch-review--r-started review))
        (and fresh (not harness-ui-patch-review--opening-box)))
    (setf (harness-ui-patch-review--r-started review) t)
    (harness-ui-patch-review--sync review)
    (harness-ui-patch-review--load review))
   ((not (or (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-error review)))
    (harness-ui-patch-review--load review))))

(defun harness-ui-patch-review--load (review &optional keep-selection-error)
  "Read REVIEW's branch again, then draw its report.
What is read is the diff the reviewer chose
\(`harness-ui-patch-review--r-selector').  One that cannot be read is
not shown: the diff shown before comes back -- the branch against its
merge base when there was none -- and the report says why, until the
next reading, unless KEEP-SELECTION-ERROR.  Return a promise of REVIEW."
  (let* ((task (harness-ui-patch-review--r-task review))
         (dir (harness-ui-patch-review--repository task))
         (branch (plist-get task :branch))
         (selector (harness-ui-patch-review--r-selector review))
         (worktree (let ((wt (plist-get task :worktree)))
                     (and (stringp wt) (not (file-remote-p wt)) (file-directory-p wt) wt)))
         (token (list 'loading)))
    (setf (harness-ui-patch-review--r-loading review) token
          (harness-ui-patch-review--r-error review) nil)
    (unless keep-selection-error
      (setf (harness-ui-patch-review--r-selection-error review) nil))
    (harness-ui-patch-review--refresh review)
    (harness-then
     (if dir
         (harness-ui-patch-review--read-branch
          dir branch (plist-get task :base) worktree selector
          (lambda (tip) (harness-ui-patch-review--last-review review tip)))
       (harness-ui-patch-review--fail "%s" (harness-ui-patch-review--why-not task)))
     (lambda (result)
       ;; A later reading wins over this one.
       (if (not (eq (harness-ui-patch-review--r-loading review) token))
           review
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-dir review) dir
               (harness-ui-patch-review--r-branch review) branch
               (harness-ui-patch-review--r-base review) (plist-get result :base)
               (harness-ui-patch-review--r-merge-base review) (plist-get result :merge-base)
               (harness-ui-patch-review--r-tip review) (plist-get result :tip)
               (harness-ui-patch-review--r-files review) (plist-get result :files)
               (harness-ui-patch-review--r-shown-selector review) selector
               (harness-ui-patch-review--r-old-name review) (plist-get result :old-name)
               (harness-ui-patch-review--r-new-name review) (plist-get result :new-name)
               (harness-ui-patch-review--r-branch-base review) (plist-get result :branch-base)
               (harness-ui-patch-review--r-branch-tip review) (plist-get result :branch-tip)
               (harness-ui-patch-review--r-branch-files review) (plist-get result :branch-files)
               (harness-ui-patch-review--r-dirty review) (plist-get result :dirty))
         (harness-ui-patch-review--attach-files review)
         (harness-ui-patch-review--refresh review)
         ;; The report is there; where the threads are now, in the files
         ;; just read, comes a moment later.
         (harness-ui-patch-review--place-threads review)))
     (lambda (err)
       (cond
        ((not (eq (harness-ui-patch-review--r-loading review) token)) review)
        ;; A diff the reviewer just chose that cannot be read: the one
        ;; shown before stays, or the default comes, if nothing was.
        ((and selector (not (equal selector (harness-ui-patch-review--r-shown-selector review))))
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-selection-error review)
               (format "Could not show %s: %s" (harness-ui-patch-review--selector-label selector)
                       (harness-error-message err))
               (harness-ui-patch-review--r-selector review)
               (harness-ui-patch-review--r-shown-selector review))
         (if (harness-ui-patch-review--r-tip review)
             (progn (harness-ui-patch-review--refresh review) review)
           (harness-ui-patch-review--load review t)))
        (t
         (setf (harness-ui-patch-review--r-loading review) nil
               (harness-ui-patch-review--r-error review) (harness-error-message err))
         (harness-ui-patch-review--refresh review)
         review))))))

(defun harness-ui-patch-review--sync-and-load (review)
  "Fetch REVIEW's threads and versions from the harness, and read its branch.
The two go on together, so the changes show as soon as git has answered.
A diff since the last review needs the versions to tell which commit that
was, so it waits for them.  Return a promise."
  (if (eq (harness-ui-patch-review--r-selector review) 'since-review)
      (harness-then (harness-ui-patch-review--sync review)
                    (lambda (_) (harness-ui-patch-review--load review)))
    (harness-ui-patch-review--sync review)
    (harness-ui-patch-review--load review)))

(defun harness-ui-patch-review--seen-key (file)
  "Return what marks FILE seen: its path and its blob on the branch.
A file the branch changed again since it was seen is not seen."
  (cons (change-review-file-path file) (change-review-file-new-blob file)))

(defun harness-ui-patch-review--seen-p (review file)
  "Non-nil when FILE of REVIEW was seen in Ediff."
  (gethash (harness-ui-patch-review--seen-key file) (harness-ui-patch-review--r-seen review)))

(defun harness-ui-patch-review--viewed-entry (file)
  "Return FILE as the harness keeps a file viewed: its path and its blob.
A file the branch deletes has no blob."
  (let ((blob (change-review-file-new-blob file)))
    (append (list :path (change-review-file-path file))
            (and blob (list :blob blob)))))

(defun harness-ui-patch-review--keep-viewed (review kind files on)
  "Have the harness keep FILES of REVIEW marked KIND, \"seen\" or \"approved\".
The mark comes off instead when ON is nil.  The harness keeps them with
the review, so that they are there after a restart; a failure only says so."
  (when (and files (harness-ui-patch-review--r-id review))
    (harness-ui-call "_harness/patch-review/set-viewed"
                     (list :task-id (harness-ui-patch-review--r-id review) :kind kind
                           :files (mapcar #'harness-ui-patch-review--viewed-entry files)
                           :on (if on t :false))
                     #'ignore
                     (lambda (err)
                       (message "Could not keep the files viewed with the harness: %s"
                                (harness-error-message err))))))

(defun harness-ui-patch-review--mark-seen (review file)
  "Mark FILE of REVIEW seen, and have the harness keep it so.
Not the file of a snapshot: an earlier commit's code is looked at, not
reviewed."
  (when (and file (not (harness-ui-patch-review--r-snapshot review)))
    (let ((key (harness-ui-patch-review--seen-key file))
          (table (harness-ui-patch-review--r-seen review)))
      (unless (gethash key table)
        (puthash key t table)
        (harness-ui-patch-review--keep-viewed review "seen" (list file) t)))))

(defun harness-ui-patch-review--approved-p (review file)
  "Non-nil when FILE of REVIEW was approved by the reviewer.
An approved file the branch changed again is not approved."
  (gethash (harness-ui-patch-review--seen-key file)
           (harness-ui-patch-review--r-approved review)))

(defun harness-ui-patch-review--note-unapproved (review file)
  "Note that the reviewer took FILE of REVIEW unapproved, if Ediff compares it.
It is the reviewer's own word on the file, and leaving Ediff must not
take it back: `harness-ui-patch-review--auto-approve' does not approve a
file noted so (`:unapproved' in the Ediff's state).  It holds for this
comparison; going through the file again is another one."
  (let* ((state (harness-ui-patch-review--r-ediff review))
         (index (plist-get state :index))
         (compared (and (integerp index)
                        (nth index (harness-ui-patch-review--r-files review)))))
    (when (and compared
               (equal (harness-ui-patch-review--seen-key compared)
                      (harness-ui-patch-review--seen-key file)))
      (setf (harness-ui-patch-review--r-ediff review)
            (plist-put state :unapproved t)))))

(defun harness-ui-patch-review--approve (review file &optional approved quiet)
  "Mark FILE of REVIEW approved, or not when APPROVED is nil.
Approving a file marks it seen too: it is reviewed and accepted.  The
harness keeps the mark, unless QUIET: the caller does, for many files.
Taking the approval off the file Ediff compares keeps it off as Ediff
ends, whatever auto-approve says (`harness-ui-patch-review--note-unapproved')."
  (when file
    (let ((key (harness-ui-patch-review--seen-key file)))
      (if approved
          (progn (puthash key t (harness-ui-patch-review--r-approved review))
                 (puthash key t (harness-ui-patch-review--r-seen review)))
        (remhash key (harness-ui-patch-review--r-approved review))
        (harness-ui-patch-review--note-unapproved review file))
      (unless quiet
        (harness-ui-patch-review--keep-viewed review "approved" (list file) approved)))))

(defun harness-ui-patch-review--user-wrote-p (thread)
  "Non-nil when the user wrote a comment in THREAD."
  (cl-some (lambda (comment)
             (let ((author (change-review-comment-author comment)))
               (and author (eq (change-review-author-kind author) 'user))))
           (change-review-thread-comments thread)))

(defun harness-ui-patch-review--file-path-p (path file)
  "Non-nil when PATH is where FILE is, or where it was before a rename."
  (and (stringp path)
       (or (equal path (change-review-file-path file))
           (and (change-review-file-old-path file)
                (equal path (change-review-file-old-path file))))))

(defun harness-ui-patch-review--box-reply-p (review file)
  "Non-nil when the box of REVIEW's report holds a reply about FILE.
C-c > on lines of a version in Ediff starts a reply in a thread
\(`harness-ui-patch-review-thread-reply'): a card in the box, the words
under it the comment.  It is no thread of the review until the feedback
is sent, but it is a comment of the reviewer's on the file all the same,
whether or not the words are written yet."
  (let ((popout (harness-ui-patch-review--r-popout review)))
    (and (buffer-live-p popout)
         (cl-some (lambda (attachment)
                    (cl-some (lambda (ref)
                               (and (equal (harness-thread-ref-kind ref) "diff")
                                    (harness-ui-patch-review--file-path-p (plist-get ref :file) file)))
                             (harness-thread-refs (plist-get attachment :thread))))
                  (buffer-local-value 'harness-compose-attachments popout))
         t)))

(defun harness-ui-patch-review--commented-p (review file)
  "Non-nil when the user has a comment on FILE of REVIEW that is not settled.
That is a draft, or an open thread the user wrote in: one the user
closed, or the agent did, is done, and a thread the agent started and
the user did not answer is the agent's.  A reply in a thread waiting in
the report's box counts too, as a draft does
\(`harness-ui-patch-review--box-reply-p').  A file with such a comment is
not one the reviewer is through with."
  (or (cl-some (lambda (thread)
                 (or (change-review-thread-drafts thread)
                     (and (change-review-thread-open-p thread)
                          (harness-ui-patch-review--user-wrote-p thread))))
               (harness-ui-patch-review--file-threads review file))
      (harness-ui-patch-review--box-reply-p review file)))

(defun harness-ui-patch-review--auto-approve (review file reached &optional unapproved)
  "Approve FILE of REVIEW, which the reviewer is leaving in Ediff, if it is due.
That is with `harness-ui-patch-review-auto-approve' on, when REACHED says
the reviewer was at the file's last difference -- went through what it
changes -- and the file is not approved yet and has no comment of the
user's that is not settled (`harness-ui-patch-review--commented-p').
UNAPPROVED says the reviewer took the file's approval off while they
compared it: that was their word on it, which leaving does not undo.
Return non-nil when it was approved."
  (when (and harness-ui-patch-review-auto-approve file reached
             (not unapproved)
             (not (harness-ui-patch-review--approved-p review file))
             (not (harness-ui-patch-review--commented-p review file)))
    (harness-ui-patch-review--approve review file t)
    (message "Approved %s: you went through it and made no comment on it; u stops that"
             (change-review-file-path file))
    t))

(defun harness-ui-patch-review--redraw-ediff-help (review)
  "Draw the help of REVIEW's Ediff control panel again, when there is one.
The help says where the reviewer is among the files, how many are viewed
and approved, and what the file has in threads: it follows them.  A
failure to draw it is logged, not signalled: it is no reason for the
mark that changed to go unsaid."
  (let ((control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (when (buffer-live-p control)
      (harness-ignore-errors-logged "patch review: drawing the help of Ediff"
        (with-current-buffer control
          (harness-ui-patch-review--ediff-redraw-help))))))

(defun harness-ui-patch-review--refresh-approvals (review)
  "Draw again what shows which files of REVIEW are approved.
That is every surface of the changes, and the help of Ediff's control
panel, which counts the files approved."
  (harness-ui-patch-review--refresh review)
  (harness-ui-patch-review--redraw-ediff-help review))

(defun harness-ui-patch-review--withdraw-approval (review file &optional quiet)
  "Take the approval off FILE of REVIEW, the reviewer having commented on it.
A file with a new comment is not one the reviewer is through with, however
it came to be approved: by going through it, by a, or before the comment
was made.  The file stays viewed, the harness keeps the approval off, and
the changes show it.  Unless QUIET, the echo area says so.  Return non-nil
when FILE was approved.  An approval the reviewer gives after the comment
\(a) is theirs, and stands until the next one."
  (when (and file (harness-ui-patch-review--approved-p review file))
    (harness-ui-patch-review--approve review file nil)
    (harness-ui-patch-review--refresh-approvals review)
    (unless quiet
      (message "No longer approved %s: you commented on it" (change-review-file-path file)))
    t))

(defun harness-ui-patch-review--on-comment (set op)
  "Take the approval off the file a new draft of the user's is on.
On `change-review-changed-functions': OP is the operation that changed
SET.  Only a comment the user adds that waits to be sent counts -- a
comment, or a reply in a thread of the agent's: what the agent writes,
and what was sent in an earlier round, are no new comment of the
reviewer's.  The file is where the thread is, the root's place for a
reply; a comment on the change as a whole is on no file."
  (when (and (harness-ui-patch-review--set-p set)
             (equal (format "%s" (plist-get op :op)) "add-comment"))
    (harness-ignore-errors-logged "patch review: the approval of a file commented on"
      (when-let* ((review (harness-ui-patch-review--set-review set))
                  ((harness-ui-patch-review--review-p review))
                  ((not (harness-ui-patch-review--r-snapshot review)))
                  (found (change-review-find-comment set (plist-get (plist-get op :comment) :id)))
                  (thread (car found))
                  (comment (cdr found))
                  ((change-review-comment-draft-p comment))
                  (author (change-review-comment-author comment))
                  ((eq (change-review-author-kind author) 'user)))
        ;; The files the report shows, and the branch's whole change: the
        ;; diff shown may be a part of it, and the approval is by the file's
        ;; path and blob either way.
        (dolist (file (append (harness-ui-patch-review--r-files review)
                              (harness-ui-patch-review--r-branch-files review)))
          (when (harness-ui-patch-review--thread-file-p thread file)
            (harness-ui-patch-review--withdraw-approval review file)))))))

(defun harness-ui-patch-review--approve-directory (review path)
  "Approve every file of REVIEW under the directory PATH, or stop approving them.
They stop being approved when they all are."
  (let* ((files (harness-ui-patch-review--dir-files review path))
         (approved (not (cl-every (lambda (file) (harness-ui-patch-review--approved-p review file))
                                  files))))
    (dolist (file files) (harness-ui-patch-review--approve review file approved t))
    (harness-ui-patch-review--keep-viewed review "approved" files approved)
    (harness-ui-patch-review--refresh-approvals review)
    (message "%s %s under %s/" (if approved "Approved" "No longer approved")
             (harness-ui-patch-review--plural (length files) "file") path)))

(defun harness-ui-patch-review-approve ()
  "Approve the file of the row at point, or stop approving it.
An approved file need not be reviewed again unless the branch changes
it: the approval follows the file's path and blob, as being seen does.
On the row of a directory it approves every file under it, or stops
approving them when they all are."
  (interactive)
  (if-let* ((dir (harness-ui-patch-review--dir-at-point)))
      (harness-ui-patch-review--approve-directory (car dir) (cdr dir))
    (pcase-let* ((`(,review . ,index) (or (harness-ui-patch-review--at-point)
                                          (user-error "No file on this line")))
                 (file (nth index (harness-ui-patch-review--r-files review))))
      (let ((approved (not (harness-ui-patch-review--approved-p review file))))
        (harness-ui-patch-review--approve review file approved)
        (harness-ui-patch-review--refresh-approvals review)
        (message "%s %s" (if approved "Approved" "No longer approved")
                 (change-review-file-path file))))))

(defun harness-ui-patch-review-approve-all ()
  "Approve every file of the review at point.
A file the branch changes again loses its approval with the change."
  (interactive)
  (let* ((review (or (harness-ui-patch-review--review-here)
                     (user-error "No changes here to approve")))
         (files (harness-ui-patch-review--r-files review)))
    (dolist (file files) (harness-ui-patch-review--approve review file t t))
    (harness-ui-patch-review--keep-viewed review "approved" files t)
    (harness-ui-patch-review--refresh-approvals review)
    (message "Approved all %s"
             (harness-ui-patch-review--plural (length files) "file"))))

(defun harness-ui-patch-review--refresh-everywhere ()
  "Draw again every review that shows, and the help of every Ediff of one.
For what changes the look of all of them: the options that can be switched."
  (maphash (lambda (_id review)
             (harness-ui-patch-review--refresh review)
             (harness-ui-patch-review--redraw-ediff-help review))
           harness-ui-patch-review--reviews))

(defun harness-ui-patch-review-toggle-skip-approved ()
  "Switch whether going on from file to file steps over the files already approved.
On, N and P in Ediff, n at the last difference, n and p on the rows of
the changes, and the row point lands on after Ediff all go to the next
file that is not approved; off, to the next file.  RET or a click on a
file compares it either way.  It is `harness-ui-patch-review-skip-approved',
for every review: the heading of the changes and the help of Ediff show
whether it is on."
  (interactive)
  (setq harness-ui-patch-review-skip-approved (not harness-ui-patch-review-skip-approved))
  (harness-ui-patch-review--refresh-everywhere)
  (message "%s" (if harness-ui-patch-review-skip-approved
                    "Files already approved are skipped"
                  "Files already approved are visited like the others")))

(defun harness-ui-patch-review-toggle-auto-approve ()
  "Switch whether a file you looked through and made no comment on is approved.
On, leaving a file in Ediff -- n past its last difference, N, P or q --
approves it when you were at its last difference and have no draft on it,
no open thread of yours and no reply in a thread waiting in the report's
box; off, only a does.  It is
`harness-ui-patch-review-auto-approve', for every review: the heading of
the changes and the help of Ediff show whether it is on."
  (interactive)
  (setq harness-ui-patch-review-auto-approve (not harness-ui-patch-review-auto-approve))
  (harness-ui-patch-review--refresh-everywhere)
  (message "%s" (if harness-ui-patch-review-auto-approve
                    "A file you went through without a comment is approved as you leave it"
                  "Files are approved only when you approve them")))

(defun harness-ui-patch-review-assume-viewed (&optional revision)
  "Take every file as viewed but those the branch's newest commit changed.
For a review you went through before the files you looked at were kept:
what the newest commit left alone you saw already, so only the files it
changed are left to view.  The files viewed so far are replaced (those
approved stay), and the harness keeps the result.  With a prefix
argument, ask for the commit to count from instead of the one before
the newest: the files changed from it on are left to view."
  (interactive (list (and current-prefix-arg (read-string "Files changed from commit: "))))
  (let* ((review (or (harness-ui-patch-review--review-here)
                     (user-error "No changes here to take as viewed")))
         (revision (and (stringp revision) (not (string-blank-p revision)) (string-trim revision))))
    (unless (harness-ui-patch-review--r-tip review)
      (user-error "The branch is not read yet"))
    (when (y-or-n-p (format "Take every file as viewed but those %s changed?  The files viewed so far are replaced "
                            (if revision (format "commit %s on" revision) "the newest commit")))
      (harness-ui-call
       "_harness/patch-review/assume-viewed"
       (append (list :task-id (harness-ui-patch-review--r-id review))
               (and revision (list :revision revision)))
       (lambda (result)
         (harness-ui-patch-review--load-viewed review t)
         (message "%s taken as viewed; %d left to view, those changed from %s on"
                  (harness-ui-patch-review--plural (or (plist-get result :seen) 0) "file")
                  (or (plist-get result :unviewed) 0)
                  (harness-ui-patch-review--short (plist-get result :revision))))
       (lambda (err)
         (message "Could not take the files as viewed: %s" (harness-error-message err)))))))

(defun harness-ui-patch-review-import-manual ()
  "Make the replies you wrote by hand for this task threads of its review.
Replies under a quote of the agent's own words -- in a round of
feedback, or typed in its session while it worked -- that the review does
not hold yet become closed threads, each with the quote it answered, and
a reply kept without its quote gets it (`patch-review/import-manual').
Asking again changes nothing.  In the report of a task, in its session
or on its card on the board."
  (interactive)
  (let* ((review (harness-ui-patch-review--review-here))
         (task (or (and review (harness-ui-patch-review--r-task review))
                   (harness-ui-patch-review--task-here)))
         (id (plist-get task :id)))
    (unless id (user-error "No task here to import replies for"))
    (harness-ui-call
     "_harness/patch-review/import-manual" (list :task-id id)
     (lambda (result)
       (message "Replies by hand in %s: %s made, %d given the quote they answered"
                (harness-ui-task-title task)
                (harness-ui-patch-review--plural (or (plist-get result :added) 0) "thread")
                (or (plist-get result :edited) 0)))
     (lambda (err)
       (message "Could not import the replies: %s" (harness-error-message err))))))

(defun harness-ui-patch-review--ediff-buffers (review)
  "Return the buffers of REVIEW's Ediff: its control panel and its two versions."
  (let ((ediff (harness-ui-patch-review--r-ediff review)))
    (list (plist-get ediff :control) (plist-get ediff :a) (plist-get ediff :b))))

(defun harness-ui-patch-review--ediff-shows-p (review)
  "Non-nil when a window shows REVIEW's Ediff."
  (cl-some (lambda (buffer) (and (buffer-live-p buffer) (get-buffer-window buffer t)))
           (harness-ui-patch-review--ediff-buffers review)))

(defun harness-ui-patch-review--forget (review)
  "Drop REVIEW: end its Ediff, give the windows back if it shows, kill its buffers."
  (remhash (harness-ui-patch-review--r-id review) harness-ui-patch-review--reviews)
  (setq change-review-ui-sets (delq (harness-ui-patch-review--r-set review) change-review-ui-sets))
  (condition-case err
      (harness-ui-patch-review--end-ediff review (not (harness-ui-patch-review--ediff-shows-p review)))
    (error (harness-log 'warn "patch review: could not end Ediff: %S" err)))
  (dolist (buffer (harness-ui-patch-review--ediff-buffers review))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (harness-ui-patch-review--kill-tree review)
  (harness-ui-patch-review--unlimit-box (harness-ui-patch-review--r-popout review))
  (setf (harness-ui-patch-review--r-ediff review) nil)
  ;; The Ediffs of the code as earlier commits had it.
  (dolist (snapshot (harness-ui-patch-review--snapshot-list review))
    (condition-case err
        (harness-ui-patch-review--end-ediff snapshot (not (harness-ui-patch-review--ediff-shows-p snapshot)))
      (error (harness-log 'warn "patch review: could not end Ediff: %S" err)))
    (dolist (buffer (harness-ui-patch-review--ediff-buffers snapshot))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (clrhash (harness-ui-patch-review--r-snapshots review)))

;;;; Where the threads are now

(defconst harness-ui-patch-review--place-limit 3000000
  "The longest file, in characters, whose lines earlier comments are looked for in.")

(defun harness-ui-patch-review--blob-at (review revision path)
  "Return a promise of the blob of PATH at REVISION in REVIEW's repository, or nil."
  (if (not (and revision path))
      (harness-resolved nil)
    (harness-catch
     (harness-then (harness-ui-patch-review--git (harness-ui-patch-review--r-dir review)
                                                 "rev-parse" "--verify" "--quiet"
                                                 (concat revision ":" path))
                   (lambda (out) (let ((sha (string-trim (harness-ui-patch-review--decode out))))
                                   (and (not (string-empty-p sha)) sha))))
     (lambda (_) nil))))

(defun harness-ui-patch-review--ranges (review old new)
  "Return a promise of how the file changed from blob OLD to blob NEW, or nil.
The ranges are those of `change-review-diff-ranges', of a diff with no
context.  Nil when it cannot be told."
  (harness-catch
   (harness-then (harness-ui-patch-review--git (harness-ui-patch-review--r-dir review)
                                               "diff" "-U0" "--no-color" "--no-ext-diff" "--no-textconv" old new)
                 (lambda (diff) (change-review-diff-ranges (harness-ui-patch-review--decode diff))))
   (lambda (_) nil)))

(defun harness-ui-patch-review--read-text (review sha wanted file)
  "Return a promise of the lines of blob SHA of FILE, nil when not WANTED.
Not a binary file, nor one too large to search; nil for them too."
  (if (and wanted sha (not (change-review-file-binary file)))
      (harness-catch
       (harness-then (harness-ui-patch-review--blob review sha)
                     (lambda (text)
                       (and (<= (length text) harness-ui-patch-review--place-limit)
                            (change-review-diff-lines-of text))))
       (lambda (_) nil))
    (harness-resolved nil)))

(defun harness-ui-patch-review--user-revision (threads)
  "Return the revision of the newest comment the user wrote in THREADS, or nil."
  (let (best)
    (dolist (thread threads)
      (dolist (comment (change-review-thread-comments thread))
        (when (and (eq (and (change-review-comment-author comment)
                            (change-review-author-kind (change-review-comment-author comment)))
                       'user)
                   (change-review-comment-revision comment)
                   (or (null best)
                       (> (or (change-review-comment-time comment) 0) (or (car best) 0))))
          (setq best (cons (change-review-comment-time comment)
                           (change-review-comment-revision comment))))))
    (cdr best)))

(defun harness-ui-patch-review--place-file (review file threads &optional tip)
  "Return a promise of (PLACEMENTS . SINCE) for THREADS about FILE of REVIEW.
PLACEMENTS is an alist of a thread's id to where the thread is now in
the newest version of FILE (`change-review-diff-place'), read from the
repository: the file at the revision each thread was made against, and
how it changed since.  SINCE is `changed' or `same' for FILE since the
user's last comment on it, nil when that is not told.  TIP is the
commit FILE's new side is at, by default that of the diff the report
shows."
  (let* ((tip (or tip (harness-ui-patch-review--r-tip review)))
         (new-blob (change-review-file-new-blob file))
         (old-blob (change-review-file-old-blob file))
         (located (cl-remove-if-not
                   (lambda (th) (change-review-location-line (change-review-thread-location th)))
                   threads))
         (user-revision (harness-ui-patch-review--user-revision threads))
         (paths nil))
    ;; The revisions the threads were made against, with FILE's path then.
    (dolist (thread threads)
      (let ((revision (change-review-thread-revision thread)))
        (when (and revision (not (equal revision tip)) (not (assoc revision paths)))
          (push (cons revision (change-review-location-file (change-review-thread-location thread)))
                paths))))
    (when (and user-revision (not (equal user-revision tip)) (not (assoc user-revision paths)))
      (push (cons user-revision (change-review-file-path file)) paths))
    (harness-then
     (harness-all (mapcar (lambda (entry)
                            (harness-ui-patch-review--blob-at review (car entry) (cdr entry)))
                          paths))
     (lambda (blobs)
       (let* ((blob-of (cl-mapcar (lambda (entry blob) (cons (car entry) blob)) paths blobs))
              (on-side (lambda (thread side)
                         (eq (change-review-location-side (change-review-thread-location thread)) side)))
              (changed (cl-remove-if
                        (lambda (th)
                          (let ((revision (change-review-thread-revision th)))
                            (or (null revision) (equal revision tip)
                                (equal (cdr (assoc revision blob-of)) new-blob))))
                        (cl-remove-if-not (lambda (th) (funcall on-side th 'new)) located)))
              (want-old (cl-some (lambda (th) (funcall on-side th 'old)) located))
              (since (when (and user-revision (not (equal user-revision tip)))
                       (let ((then (cdr (assoc user-revision blob-of))))
                         (and then new-blob (if (equal then new-blob) 'same 'changed))))))
         (harness-then
          (harness-all
           (list (harness-ui-patch-review--read-text review old-blob want-old file)
                 (harness-ui-patch-review--read-text review new-blob (and changed t) file)
                 (harness-all
                  (mapcar (lambda (revision)
                            (let ((then (cdr (assoc revision blob-of))))
                              (harness-then
                               (if (and then new-blob (not (equal then new-blob))
                                        (cl-some (lambda (th) (equal (change-review-thread-revision th) revision))
                                                 changed))
                                   (harness-ui-patch-review--ranges review then new-blob)
                                 (harness-resolved nil))
                               (lambda (ranges) (cons revision ranges)))))
                          (delete-dups (delq nil (mapcar #'change-review-thread-revision changed)))))))
          (lambda (read)
            (let ((old-lines (nth 0 read)) (new-lines (nth 1 read)) (ranges (nth 2 read)))
              (cons (cl-loop for thread in located
                             for location = (change-review-thread-location thread)
                             for revision = (change-review-thread-revision thread)
                             collect (cons (change-review-thread-id thread)
                                           (if (and (null new-blob)
                                                    (eq (change-review-location-side location) 'new))
                                               ;; The branch deleted the file: no line to be on.
                                               (list :side 'new :line nil
                                                     :was (change-review-location-line location)
                                                     :status 'gone)
                                             (change-review-diff-place
                                              location old-lines new-lines
                                              (or (null revision) (equal revision tip)
                                                  (equal (cdr (assoc revision blob-of)) new-blob))
                                              (cdr (assoc revision ranges))))))
                    since)))))))))

(defun harness-ui-patch-review--unshown-files (review)
  "Return the files of REVIEW's whole change that the diff the report shows lacks.
Nil when the report shows the whole change."
  (let ((shown (harness-ui-patch-review--r-files review)))
    (unless (eq shown (harness-ui-patch-review--r-branch-files review))
      (cl-remove-if (lambda (file)
                      (cl-find (change-review-file-path file) shown
                               :key #'change-review-file-path :test #'equal))
                    (harness-ui-patch-review--r-branch-files review)))))

(defun harness-ui-patch-review--place-threads (review)
  "Place the threads of REVIEW in the newest version of their files.
Reads from the repository the files that have threads, and how they
changed since the revision each thread was made against; then draws the
report and the views of the threads again.  The files are those the
report shows, as that diff has them, and then those the branch changes
that it does not, as the whole change has them: a thread is where it is
now whatever the diff shown.  Return a promise of REVIEW; it never
rejects."
  (let* ((token (list 'placing))
         (set (harness-ui-patch-review--r-set review))
         (placed (make-hash-table :test 'equal))
         jobs)
    (setf (harness-ui-patch-review--r-placing review) token)
    ;; Each job is (FILE THREADS TIP): the file the threads are about and
    ;; the commit its new side is at.
    (cl-flet ((add (files tip)
                (dolist (file files)
                  (when-let* ((threads (cl-remove-if
                                        (lambda (thread) (gethash (change-review-thread-id thread) placed))
                                        (harness-ui-patch-review--file-threads review file))))
                    (dolist (thread threads) (puthash (change-review-thread-id thread) t placed))
                    (push (list file threads tip) jobs)))))
      (add (harness-ui-patch-review--r-files review) (harness-ui-patch-review--r-tip review))
      (add (harness-ui-patch-review--unshown-files review) (harness-ui-patch-review--r-branch-tip review)))
    (setq jobs (nreverse jobs))
    (harness-then
     (harness-all (mapcar (lambda (job)
                            (harness-ui-patch-review--place-file review (nth 0 job) (nth 1 job) (nth 2 job)))
                          jobs))
     (lambda (results)
       (when (eq (harness-ui-patch-review--r-placing review) token)
         (let ((placements (make-hash-table :test 'equal))
               (since (make-hash-table :test 'equal)))
           (cl-mapc (lambda (job result)
                      (dolist (entry (car result)) (puthash (car entry) (cdr entry) placements))
                      (when (cdr result)
                        (puthash (change-review-file-path (nth 0 job)) (cdr result) since)))
                    jobs results)
           (setf (harness-ui-patch-review--r-placements review) placements
                 (harness-ui-patch-review--r-since review) since
                 (harness-ui-patch-review--r-placing review) nil)
           (change-review-ui-refresh set)
           (harness-ui-patch-review--refresh review)))
       review)
     (lambda (err)
       (harness-log 'warn "patch review: could not place the threads: %s" (harness-error-message err))
       review))))

(defun harness-ui-patch-review--place-from-texts (review file old new)
  "Return where the threads about FILE of REVIEW are, from OLD and NEW, its texts.
An alist of a thread's id to its place (`change-review-diff-place'),
worked out from the lines the thread quotes: for the threads the
repository has not been asked about yet."
  (let ((tip (harness-ui-patch-review--r-tip review))
        (old-lines (and old (change-review-diff-lines-of old)))
        (new-lines (and new (change-review-diff-lines-of new))))
    (cl-loop for thread in (harness-ui-patch-review--file-threads review file)
             for location = (change-review-thread-location thread)
             for revision = (change-review-thread-revision thread)
             when (change-review-location-line location)
             collect (cons (change-review-thread-id thread)
                           (change-review-diff-place location old-lines new-lines
                                                     (or (null revision) (equal revision tip)))))))

(defun harness-ui-patch-review--since-text (review file)
  "Return what to say of FILE of REVIEW since the user's last comment, or nil."
  (pcase (gethash (change-review-file-path file) (harness-ui-patch-review--r-since review))
    ('same (propertize "same since your comment" 'face 'harness-dim-face))
    ('changed (propertize "changed since your comment" 'face 'warning))))

;;;; The review at an earlier commit

;; The comments written against an earlier commit are about its code, and
;; the branch has gone past it: the answer to a comment changed the lines
;; it is about.  To show them as they were, the review is read again at
;; that commit -- its diff against the merge base, the files, the places
;; of the threads in it -- once, and kept: a snapshot, a copy of the
;; review that has what that commit had.  The diff around a reply's line,
;; the code in Ediff, come from it.

(defun harness-ui-patch-review--version-at (review revision)
  "Return the version of REVIEW's set that ends at REVISION, or nil."
  (let ((set (harness-ui-patch-review--r-set review)))
    (and set (stringp revision)
         (cl-find-if (lambda (version)
                       (change-review-same-revision-p revision (change-review-version-id version)))
                     (change-review-set-versions set)))))

(defun harness-ui-patch-review--version-revision (set version)
  "Return the revision VERSION names in SET, or nil for none.
VERSION is a version, a number or a label of one, or a revision that is
no version's: itself."
  (cond ((null version) nil)
        ((change-review-version-p version) (change-review-version-id version))
        ((or (numberp version) (stringp version))
         (if-let* ((found (change-review-find-version set version)))
             (change-review-version-id found)
           (and (stringp version) version)))))

(defun harness-ui-patch-review--placement (review thread)
  "Return where THREAD is in the files of REVIEW, which may be a snapshot.
For the review itself that is where the thread is in the branch now."
  (or (gethash (change-review-thread-id thread) (harness-ui-patch-review--r-placements review))
      (change-review-placement (harness-ui-patch-review--r-set review) thread)))

(defun harness-ui-patch-review--location-in (view thread)
  "Return the location of THREAD in VIEW, a review or a snapshot of one, or nil.
That is the lines of the diff of its file in VIEW around the line the
thread is on there: nil when the file has no change there, or the
thread no line."
  (let* ((location (change-review-thread-location thread))
         (file (and location (change-review-location-line location)
                    (cl-find-if (lambda (file) (harness-ui-patch-review--location-file-p location file))
                                (harness-ui-patch-review--r-files view))))
         (placement (and file (harness-ui-patch-review--placement view thread)))
         (line (and placement (plist-get placement :line))))
    (when line
      (change-review-diff-location
       file (or (plist-get placement :side) (change-review-location-side location) 'new) line))))

(defun harness-ui-patch-review--bare-location (location)
  "Return LOCATION without its excerpt."
  (change-review-make-location
   :file (change-review-location-file location) :old-file (change-review-location-old-file location)
   :side (change-review-location-side location) :line (change-review-location-line location)
   :end-line (change-review-location-end-line location) :patch (change-review-location-patch location)))

(defun harness-ui-patch-review--make-snapshot (review result)
  "Return a copy of REVIEW that has RESULT, what the branch read gave.
RESULT is that of `harness-ui-patch-review--read-branch'.  The copy is
REVIEW as the commit RESULT names had it: its files and merge base,
with no place of any thread yet, no Ediff, no earlier commits."
  (let ((snapshot (copy-sequence review)))
    ;; Made under the layout its original was.
    (puthash snapshot (gethash review harness-ui-patch-review--made-with)
             harness-ui-patch-review--made-with)
    (setf (harness-ui-patch-review--r-snapshot snapshot) (plist-get result :tip)
          (harness-ui-patch-review--r-tip snapshot) (plist-get result :tip)
          (harness-ui-patch-review--r-merge-base snapshot) (plist-get result :merge-base)
          (harness-ui-patch-review--r-files snapshot) (plist-get result :files)
          (harness-ui-patch-review--r-placements snapshot) (make-hash-table :test 'equal)
          (harness-ui-patch-review--r-since snapshot) (make-hash-table :test 'equal)
          (harness-ui-patch-review--r-snapshots snapshot) (make-hash-table :test 'equal)
          (harness-ui-patch-review--r-ediff snapshot) nil
          (harness-ui-patch-review--r-placing snapshot) nil
          (harness-ui-patch-review--r-loading snapshot) nil
          (harness-ui-patch-review--r-error snapshot) nil
          (harness-ui-patch-review--r-dirty snapshot) nil
          (harness-ui-patch-review--r-gone snapshot) nil)
    snapshot))

(defun harness-ui-patch-review--read-snapshot (review revision)
  "Return a promise of the snapshot of REVIEW at REVISION, read from git.
The merge base is the one the version that ended at REVISION recorded,
else the one the branch has with its base."
  (let* ((dir (harness-ui-patch-review--r-dir review))
         (version (harness-ui-patch-review--version-at review revision))
         (base (or (and version (change-review-version-base version))
                   (harness-ui-patch-review--r-base review))))
    (harness-then
     (harness-catch
      (harness-ui-patch-review--read-branch dir revision base)
      (lambda (err)
        (let ((text (harness-error-message err)))
          (harness-ui-patch-review--fail
           "%s" (if (string-match-p "There is no branch" text)
                    (format-message "The commit %s is not in the repository"
                                    (harness-ui-patch-review--short revision))
                  text)))))
     (lambda (result)
       (let ((snapshot (harness-ui-patch-review--make-snapshot review result)))
         (harness-then (harness-ui-patch-review--place-threads snapshot)
                       (lambda (_) snapshot)))))))

(defun harness-ui-patch-review--snapshot (review revision)
  "Return a promise of the snapshot of REVIEW at REVISION, a commit of its branch.
It is read once: a second ask gets the same promise, and a read that
failed stays failed.  The views of the review's threads draw again once
it is there, or is not."
  (if (not (harness-ui-patch-review--r-dir review))
      (harness-ui-patch-review--fail "The repository of the branch is not known yet")
    (let ((table (harness-ui-patch-review--r-snapshots review)))
      (or (gethash revision table)
          (let ((promise (harness-ui-patch-review--read-snapshot review revision))
                (set (harness-ui-patch-review--r-set review)))
            (puthash revision promise table)
            (harness-then promise
                          (lambda (_) (change-review-ui-refresh set) nil)
                          (lambda (_) (change-review-ui-refresh set) nil))
            promise)))))

(defun harness-ui-patch-review--snapshot-list (review)
  "Return the snapshots of REVIEW that are read, in no order."
  (let (snapshots)
    (maphash (lambda (_revision promise)
               (when (eq (harness-promise-state promise) 'resolved)
                 (push (harness-promise-value promise) snapshots)))
             (harness-ui-patch-review--r-snapshots review))
    snapshots))

(defun harness-ui-patch-review--view-at (review revision)
  "Return REVIEW as REVISION had it: the code the comments written then are about.
REVIEW itself when the branch is at REVISION; else its snapshot, once
read; `pending' while that is read -- it starts to be -- and
\(:failed MESSAGE) when it cannot be."
  (if (change-review-same-revision-p revision (harness-ui-patch-review--r-tip review))
      review
    (let ((promise (harness-ui-patch-review--snapshot review revision)))
      (pcase (harness-promise-state promise)
        ('resolved (harness-promise-value promise))
        ('rejected (list :failed (harness-error-message (harness-promise-value promise))))
        (_ 'pending)))))

(defun harness-ui-patch-review--visit-at (review target revision)
  "Show TARGET, a thread, a comment or a location, in Ediff as REVISION had it.
REVISION is a commit of the branch: the merge base against the file as
that commit had it, with the line the comment was made on in sight.
Return a promise."
  (harness-then
   (harness-ui-patch-review--snapshot review revision)
   (lambda (snapshot)
     (pcase-let* ((`(,thread . ,location) (harness-ui-patch-review--target-place
                                           (harness-ui-patch-review--r-set review) target))
                  (index (and location
                              (cl-position-if (lambda (file) (harness-ui-patch-review--location-file-p location file))
                                              (harness-ui-patch-review--r-files snapshot))))
                  (placement (and thread (harness-ui-patch-review--placement snapshot thread))))
       (if (null index)
           (message "%s is not a file the commit %s changes"
                    (if location (change-review-location-label location) "The change as a whole")
                    (harness-ui-patch-review--short revision))
         (harness-ui-patch-review-ediff
          snapshot index
          (harness-ui-patch-review--goto
           (or (plist-get placement :side) (change-review-location-side location))
           (or (plist-get placement :line) (change-review-location-line location)))))))
   (lambda (err)
     (message "Could not show the code of %s: %s"
              (harness-ui-patch-review--short revision) (harness-error-message err)))))

;;;; The box of the feedback

(defun harness-ui-patch-review--feedback-box (review)
  "Return the report of REVIEW's task, whose box takes the feedback; or signal.
A report closed meanwhile opens again, out of sight, for its box.  A
snapshot's is the review's own."
  (let* ((review (or (harness-ui-patch-review--known (harness-ui-patch-review--r-id review))
                     review))
         (task (harness-ui-patch-review--r-task review)))
    (unless (harness-ui-patch-review--reviewing-p task)
      (user-error "%s no longer waits for review: there is no feedback to comment in"
                  (harness-ui-patch-review--title review)))
    (unless (buffer-live-p (harness-ui-patch-review--r-popout review))
      (save-window-excursion (harness-ui-report-popout task)))
    (let ((popout (harness-ui-patch-review--r-popout review)))
      (unless (and (buffer-live-p popout) (with-current-buffer popout (harness-compose-live-p)))
        (user-error "The report of %s has no box for the feedback" (harness-ui-patch-review--title review)))
      popout)))

;;;; The changes in the report

;; The changes are drawn the same on every surface -- the report, the
;; review banner of the task's session, the tree beside Ediff -- as a
;; string of rows that carry their keys as text properties.  The buffer of
;; a surface is a view of the review's set, as the library's own views
;; are (`change-review-ui--set', `change-review-ui--redraw-function'): the
;; threads under the files are drawn by the library, its commands act on
;; them where point is, and an operation that changes the set draws the
;; surface again.

(defvar harness-ui-patch-review--common-map (make-sparse-keymap)
  "Keys on every row of the changes, whatever the row is about.")

(defvar harness-ui-patch-review--row-map (make-sparse-keymap)
  "Keys on a row of the changes in a report: RET or a click compares its file.")

(defvar harness-ui-patch-review--dir-map (make-sparse-keymap)
  "Keys on the row of a directory of the changes: RET, TAB or a click folds it.")

;; Filled at top level, not in the `defvar's, so a reload updates the maps.
(let ((map harness-ui-patch-review--common-map))
  (define-key map (kbd "s") #'harness-ui-patch-review-toggle-skip-approved)
  (define-key map (kbd "u") #'harness-ui-patch-review-toggle-auto-approve)
  (define-key map (kbd "t") #'harness-ui-patch-review-toggle-file-tree)
  (define-key map (kbd "T") #'harness-ui-patch-review-threads)
  (define-key map (kbd "d") #'harness-ui-patch-review-select-diff)
  (define-key map (kbd "c") #'change-review-ui-comment-on-change))

(let ((map harness-ui-patch-review--row-map))
  (set-keymap-parent map harness-ui-patch-review--common-map)
  (define-key map (kbd "RET") #'harness-ui-patch-review-ediff)
  (define-key map [mouse-1] #'harness-ui-patch-review-mouse-ediff)
  (define-key map [mouse-2] #'harness-ui-patch-review-mouse-ediff)
  ;; A double click compares once.
  (define-key map [double-mouse-1] #'ignore)
  (define-key map [triple-mouse-1] #'ignore)
  (define-key map (kbd "n") #'harness-ui-patch-review-next-file)
  (define-key map (kbd "p") #'harness-ui-patch-review-previous-file)
  (define-key map (kbd "a") #'harness-ui-patch-review-approve)
  (define-key map (kbd "A") #'harness-ui-patch-review-approve-all)
  (define-key map (kbd "d") #'harness-ui-patch-review-select-diff)
  (define-key map (kbd "V") #'harness-ui-patch-review-assume-viewed))

(let ((map harness-ui-patch-review--dir-map))
  (set-keymap-parent map harness-ui-patch-review--row-map)
  (define-key map (kbd "RET") #'harness-ui-patch-review-toggle-directory)
  (define-key map (kbd "TAB") #'harness-ui-patch-review-toggle-directory)
  (define-key map (kbd "<tab>") #'harness-ui-patch-review-toggle-directory)
  (define-key map [mouse-1] #'harness-ui-patch-review-mouse-toggle-directory)
  (define-key map [mouse-2] #'harness-ui-patch-review-mouse-toggle-directory))

(defun harness-ui-patch-review--counts (review)
  "Return the threads of REVIEW per file of its changes.
An alist of (PATH . (:open N :closed M :unreviewed U :drafts K)), for the
files that have threads; U is how many of the M closed threads wait for
the reviewer's look (`change-review-thread-unreviewed-p')."
  (let ((set (harness-ui-patch-review--r-set review))
        alist)
    (dolist (file (harness-ui-patch-review--r-files review))
      (let ((open 0) (closed 0) (unreviewed 0) (drafts 0))
        (dolist (thread (harness-ui-patch-review--file-threads review file))
          (if (change-review-thread-open-p thread) (cl-incf open) (cl-incf closed))
          (when (change-review-thread-unreviewed-p set thread) (cl-incf unreviewed))
          (cl-incf drafts (length (change-review-thread-drafts thread))))
        (when (> (+ open closed) 0)
          (push (cons (change-review-file-path file)
                      (list :open open :closed closed :unreviewed unreviewed :drafts drafts))
                alist))))
    (nreverse alist)))

;;;;; The threads, below the files

(defvar harness-ui-patch-review--thread-map (make-sparse-keymap)
  "Keys on a thread of the changes, and on the heading of the threads.
RET compares the file in Ediff with the thread's line in sight, or shows
where a comment was made; r replies, x closes the thread or opens it
again.  The library's commands act on the thread or the comment at point.")

(let ((map harness-ui-patch-review--thread-map))
  (set-keymap-parent map harness-ui-patch-review--common-map)
  (define-key map (kbd "RET") #'harness-ui-patch-review-thread-return)
  (define-key map (kbd "d") #'change-review-ui-show-in-diff)
  (define-key map (kbd "r") #'change-review-ui-reply)
  (define-key map (kbd "x") #'change-review-ui-toggle-status)
  (define-key map (kbd "m") #'change-review-ui-toggle-reviewed)
  (define-key map (kbd "M") #'change-review-ui-mark-all-reviewed)
  (define-key map (kbd "o") #'change-review-ui-follow-author)
  (define-key map (kbd "e") #'change-review-ui-edit-draft)
  (define-key map (kbd "k") #'change-review-ui-delete-draft)
  (define-key map (kbd "K") #'change-review-ui-delete-draft-thread)
  (define-key map (kbd "n") #'change-review-ui-next-comment)
  (define-key map (kbd "p") #'change-review-ui-previous-comment)
  (define-key map (kbd "N") #'change-review-ui-next-thread)
  (define-key map (kbd "P") #'change-review-ui-previous-thread)
  (define-key map (kbd "f") #'change-review-ui-cycle-filter))

(defconst harness-ui-patch-review--thread-hint
  "RET compares the file at the thread's line or shows where a comment was made, r replies, e edits a draft, k deletes one and K a thread of drafts, x closes a thread or opens it again, o follows an agent's comment, c comments on the change as a whole, f changes which threads show."
  "What the changes say under the heading of the threads.")

(defun harness-ui-patch-review--text-width (&optional margin)
  "Return how wide to draw threads in the current buffer, less MARGIN columns.
That is the body of the widest window showing the buffer, else 100."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (max 36 (- (if windows (apply #'max (mapcar #'window-body-width windows)) 100)
               (or margin 0)))))

(defun harness-ui-patch-review--wrap-headers (string)
  "Return STRING, threads the library drew, wrapping under their headers.
The header of a thread, and of each of its comments, is one long line
with its buttons: where the window is narrow it wraps, and the rest
would start at the window's edge.  A thread's goes under its mark, a
comment's under its bar, which goes on down the lines."
  (let ((string (copy-sequence string))
        (pos 0))
    (while (setq pos (let ((thread (text-property-any pos (length string) 'change-review-thread-start t string))
                           (comment (text-property-any pos (length string) 'change-review-comment-start t string)))
                       (and (or thread comment) (min (or thread most-positive-fixnum) (or comment most-positive-fixnum)))))
      (let* ((end (or (string-search "\n" string pos) (length string)))
             (comment (get-text-property pos 'change-review-comment-start string))
             (lead (let ((i pos)) (while (and (< i end) (eq (aref string i) ?\s)) (setq i (1+ i))) (- i pos))))
        (put-text-property
         pos end 'wrap-prefix
         (if comment
             (concat (make-string lead ?\s)
                     (propertize "┃" 'face (get-text-property (+ pos lead) 'face string))
                     "      ")
           (make-string (+ lead 4) ?\s))
         string)
        (setq pos (1+ end))))
    string))

(defun harness-ui-patch-review--threads-section (review &optional compact)
  "Return the threads of REVIEW as the changes show them, below the files.
A heading with the library's filter buttons, a line of what the keys do
\(not when COMPACT, as in the tree beside Ediff), then the threads of
the status the buffer's filter lets through, by file, drawn as the
library's threads view draws them.  The buffer is a view of the review's
set (`harness-ui-patch-review--view'), so the library's commands find the
thread or comment at point and its buttons draw the section again."
  (let* ((set (harness-ui-patch-review--r-set review))
         (filter (or change-review-ui--filter 'open))
         (text (concat
                (propertize (change-review-ui-threads-heading set filter)
                            'harness-ui-patch-review-threads t 'wrap-prefix "  ")
                (if compact ""
                  (propertize (concat "  " harness-ui-patch-review--thread-hint "\n")
                              'face 'harness-hint-face 'wrap-prefix "  "))
                (harness-ui-patch-review--wrap-headers
                 (change-review-ui-threads-string
                  set :filter filter :details change-review-ui--details
                  :width (harness-ui-patch-review--text-width (if compact 2 8))
                  :indent "  ")))))
    (harness-ui-with-keymap
     (propertize text 'harness-ui-patch-review-task (harness-ui-patch-review--r-id review))
     harness-ui-patch-review--thread-map)))

(defun harness-ui-patch-review-thread-return ()
  "Do what RET does on a thread of the changes, or on the file it is under.
On a comment: show where it was made, or hide that again.  On the header
of a thread: compare the file in Ediff with the thread's line in sight.
On the name of a file above its threads: compare that file."
  (interactive)
  (cond
   ((get-text-property (point) 'change-review-comment) (change-review-ui-show-origin))
   ((get-text-property (point) 'change-review-thread) (change-review-ui-show-in-diff))
   ((stringp (get-text-property (point) 'change-review-file))
    (let* ((review (or (harness-ui-patch-review--review-here) (user-error "No review here")))
           (path (get-text-property (point) 'change-review-file))
           (index (cl-position-if (lambda (file) (equal path (change-review-file-path file)))
                                  (harness-ui-patch-review--r-files review))))
      (if index
          (harness-ui-patch-review-ediff review index)
        (user-error "%s is not a file this version changes" path))))
   (t (user-error "No thread here"))))

;;;;; The files

(defun harness-ui-patch-review--path-label (file)
  "Return the path of FILE for its row, \"OLD → NEW\" for a rename."
  (if (change-review-file-old-path file)
      (format "%s → %s" (change-review-file-old-path file) (change-review-file-path file))
    (change-review-file-path file)))

(defun harness-ui-patch-review--submodule-p (file)
  "Non-nil when FILE is a submodule on either side."
  (or (equal (change-review-file-old-mode file) "160000")
      (equal (change-review-file-new-mode file) "160000")))

(defun harness-ui-patch-review--change-label (file)
  "Return what changed in FILE, for its row: the lines added and deleted."
  (let* ((added (change-review-file-added file))
         (deleted (change-review-file-deleted file))
         (old-mode (change-review-file-old-mode file))
         (new-mode (change-review-file-new-mode file))
         (mode (and (not (member old-mode '("000000" nil))) (not (member new-mode '("000000" nil)))
                    (not (equal old-mode new-mode))
                    (format "mode %s → %s" old-mode new-mode)))
         (lines (and (> (+ added deleted) 0)
                     (concat (propertize (format "+%d" added) 'face 'harness-ui-patch-review-plus-face)
                             " "
                             (propertize (format "−%d" deleted) 'face 'harness-ui-patch-review-minus-face)))))
    (cond ((harness-ui-patch-review--submodule-p file) (propertize "submodule" 'face 'harness-dim-face))
          ((change-review-file-binary file) (propertize "binary" 'face 'harness-dim-face))
          ((and lines mode) (concat lines "  " (propertize mode 'face 'harness-dim-face)))
          (lines)
          (mode (propertize mode 'face 'harness-dim-face))
          ((change-review-file-old-path file) (propertize "same content" 'face 'harness-dim-face))
          (t ""))))

(defun harness-ui-patch-review--status-face (file)
  "Return the face of FILE's status letter."
  (pcase (change-review-file-status file)
    ("A" 'harness-ui-patch-review-plus-face)
    ("D" 'harness-ui-patch-review-minus-face)
    (_ 'bold)))

(defun harness-ui-patch-review--state-text (review file)
  "Return where FILE of REVIEW stands, in words.
Approved, viewed only, or not viewed yet.  Only an approved file is
skipped (`harness-ui-patch-review-skip-approved')."
  (cond ((harness-ui-patch-review--approved-p review file)
         (if harness-ui-patch-review-skip-approved
             "approved, so going on from file to file steps over it" "approved"))
        ((harness-ui-patch-review--seen-p review file) "viewed, not approved")
        (t "not viewed yet")))

(defun harness-ui-patch-review--mark (review file)
  "Return the mark of FILE of REVIEW: approved, else seen in Ediff, else a space.
The two check marks differ in weight and colour, the approved one bold and
green, the seen one dim: a file looked at is not an approved one."
  (cond ((harness-ui-patch-review--approved-p review file)
         (propertize "✔" 'face 'harness-ui-patch-review-approved-face))
        ((harness-ui-patch-review--seen-p review file)
         (propertize "✓" 'face 'harness-ui-patch-review-seen-face))
        (t " ")))

(cl-defun harness-ui-patch-review--row (review file index width counts
                                               &key (indent "  ") label compact avail current)
  "Return the row of FILE of REVIEW, at INDEX of its files.
The path is padded to WIDTH; COUNTS are the threads per file
\(`harness-ui-patch-review--counts').  INDENT is what the row starts
with, \"  \" by default; LABEL names the file, its path by default.
COMPACT draws the row to fit AVAIL columns, as the tree beside Ediff
does: the name gives way to the lines the file changes and how many
threads are open on it.  CURRENT marks the row of the file Ediff compares."
  (let* ((threads (cdr (assoc (change-review-file-path file) counts)))
         (open (or (plist-get threads :open) 0))
         (closed (or (plist-get threads :closed) 0))
         (unreviewed (or (plist-get threads :unreviewed) 0))
         (drafts (or (plist-get threads :drafts) 0))
         (label (or label (harness-ui-patch-review--path-label file)))
         (status (propertize (change-review-file-status file)
                             'face (harness-ui-patch-review--status-face file)))
         (mark (harness-ui-patch-review--mark review file))
         (indent (if current (concat "▶" (substring indent (min 1 (length indent)))) indent))
         (row
          (if compact
              (let* ((lead (concat indent mark " " status " "))
                     (change (harness-ui-patch-review--change-label file))
                     (tail (concat (if (string-empty-p change) "" (concat " " change))
                                   (if (> open 0)
                                       (concat " " (propertize (format "●%d" open)
                                                               'face 'harness-ui-patch-review-comments-face))
                                     "")
                                   (if (> drafts 0)
                                       (concat " " (propertize (format "✎%d" drafts)
                                                               'face 'change-review-ui-draft-face))
                                     "")))
                     (room (max 8 (- (or avail 40) (string-width lead) (string-width tail)))))
                (concat lead (string-pad (harness-truncate-middle label room) room) tail))
            (let ((since (harness-ui-patch-review--since-text review file)))
              (concat indent mark " " status "  "
                      (string-pad (harness-truncate-middle label width) width)
                      "  "
                      (harness-ui-patch-review--change-label file)
                      (if (> open 0)
                          (concat "   " (propertize (format "%d open" open)
                                                    'face 'harness-ui-patch-review-comments-face))
                        "")
                      (if (> closed 0)
                          (concat "   " (propertize (format "%d closed" closed) 'face 'harness-dim-face))
                        "")
                      (if (> unreviewed 0)
                          (concat " " (propertize (format "(%d to review)" unreviewed)
                                                  'face 'change-review-ui-review-face
                                                  'help-echo "Closed by the agent, and not reviewed by you yet: m marks a thread reviewed"))
                        "")
                      (if (> drafts 0)
                          (concat "   " (propertize (harness-ui-patch-review--plural drafts "draft")
                                                    'face 'change-review-ui-draft-face))
                        "")
                      (if since (concat "   " since) ""))))))
    (when current (add-face-text-property 0 (length row) 'harness-ui-patch-review-current-face t row))
    (add-text-properties 0 (length row)
                         (list 'harness-ui-patch-review-file index
                               'harness-ui-patch-review-task (harness-ui-patch-review--r-id review)
                               'mouse-face 'highlight
                               'help-echo (format "%s: %s\nRET or a click: compare it in Ediff; a approves it"
                                                  (harness-ui-patch-review--path-label file)
                                                  (harness-ui-patch-review--state-text review file))
                               'keymap harness-ui-patch-review--row-map)
                         row)
    row))

(defun harness-ui-patch-review--tree-label (file)
  "Return FILE's name under its directory, \"OLD → NEW\" for a rename."
  (let ((old (change-review-file-old-path file))
        (path (change-review-file-path file)))
    (cond
     ((and old (not (equal (file-name-directory old) (file-name-directory path))))
      (format "%s → %s" old path))
     (old (format "%s → %s" (file-name-nondirectory old) (file-name-nondirectory path)))
     (t (file-name-nondirectory path)))))

(defun harness-ui-patch-review--tree-node ()
  "Return an empty node of the file tree."
  (list :name nil :dirs nil :files nil))

(defun harness-ui-patch-review--tree-add (node file &optional parts)
  "Put FILE in tree NODE, by the directories of its path.
PARTS is what is left of the path; nil to start at its first directory."
  (let* ((parts (or parts (split-string (change-review-file-path file) "/" t)))
         (rest (cdr parts)))
    (if (null rest)
        (setf (plist-get node :files) (cons file (plist-get node :files)))
      (let ((child (assoc (car parts) (plist-get node :dirs))))
        (unless child
          (setq child (cons (car parts)
                            (list :name (car parts) :dirs nil :files nil)))
          (setf (plist-get node :dirs) (cons child (plist-get node :dirs))))
        (harness-ui-patch-review--tree-add (cdr child) file rest)))))

(defun harness-ui-patch-review--tree (files)
  "Return FILES as a tree of directories and the files they hold."
  (let ((root (harness-ui-patch-review--tree-node)))
    (dolist (file files) (harness-ui-patch-review--tree-add root file))
    root))

(defun harness-ui-patch-review--tree-stats (node)
  "Return (COUNT ADDED DELETED) for the files of NODE and its directories."
  (let ((count (length (plist-get node :files)))
        (added 0)
        (deleted 0))
    (dolist (file (plist-get node :files))
      (cl-incf added (change-review-file-added file))
      (cl-incf deleted (change-review-file-deleted file)))
    (dolist (child (plist-get node :dirs))
      (pcase-let ((`(,child-count ,child-added ,child-deleted)
                   (harness-ui-patch-review--tree-stats (cdr child))))
        (cl-incf count child-count)
        (cl-incf added child-added)
        (cl-incf deleted child-deleted)))
    (list count added deleted)))

(defun harness-ui-patch-review--tree-indent (depth)
  "Return the indentation of a tree row at DEPTH."
  (concat "  " (make-string (* 2 depth) ?\s)))

(defun harness-ui-patch-review--tree-entries (node)
  "Return the entries of tree NODE in the order they show: by name.
Each is (LABEL file . FILE) or (LABEL dir . CHILD-NODE); a directory's
label ends in a slash."
  (sort (append (mapcar (lambda (file)
                          (cons (harness-ui-patch-review--tree-label file) (cons 'file file)))
                        (plist-get node :files))
                (mapcar (lambda (dir)
                          (cons (concat (car dir) "/") (cons 'dir (cdr dir))))
                        (plist-get node :dirs)))
        (lambda (a b) (string< (car a) (car b)))))

(defun harness-ui-patch-review--order (review)
  "Return the indices of REVIEW's files in the order they show.
That is the tree from its top to its bottom, directories folded or not,
else the diff's order.  Going from file to file follows it, so the next
file is the one on the next row."
  (let ((files (harness-ui-patch-review--r-files review)))
    (if (not (harness-ui-patch-review--r-tree review))
        (number-sequence 0 (1- (length files)))
      (let ((indices (make-hash-table :test 'eq))
            order)
        (cl-loop for file in files for i from 0 do (puthash file i indices))
        (cl-labels ((walk (node)
                      (dolist (entry (harness-ui-patch-review--tree-entries node))
                        (if (eq (cadr entry) 'file)
                            (push (gethash (cddr entry) indices) order)
                          (walk (cddr entry))))))
          (walk (harness-ui-patch-review--tree files)))
        (nreverse order)))))

(defun harness-ui-patch-review--skip-p (review)
  "Return a function of a file's index that says whether to step over the file.
Over the files approved while `harness-ui-patch-review-skip-approved' is
on; nil when no file is skipped."
  (and harness-ui-patch-review-skip-approved
       (let ((files (harness-ui-patch-review--r-files review)))
         (lambda (index) (harness-ui-patch-review--approved-p review (nth index files))))))

(defun harness-ui-patch-review--neighbor (review index step &optional accept)
  "Return the index of the file STEP files on from INDEX, 1 or -1, or nil.
The files are taken in the order they show (`harness-ui-patch-review--order'),
and only those ACCEPT, a function of a file's index, lets through; the
files approved are not, while `harness-ui-patch-review-skip-approved' is
on.  Nil when there is no such file that way."
  (let* ((order (harness-ui-patch-review--order review))
         (here (cl-position index order))
         (skip (harness-ui-patch-review--skip-p review)))
    (when here
      (cl-find-if (lambda (candidate)
                    (and (or (null accept) (funcall accept candidate))
                         (not (and skip (funcall skip candidate)))))
                  (if (> step 0) (nthcdr (1+ here) order) (reverse (take here order)))))))

(defun harness-ui-patch-review--between (review from to)
  "Return how many files REVIEW shows between FROM and TO, exclusive, approved.
FROM and TO are indices of its files, in either order."
  (let* ((order (harness-ui-patch-review--order review))
         (a (cl-position from order))
         (b (cl-position to order))
         (files (harness-ui-patch-review--r-files review)))
    (if (and a b)
        (cl-count-if (lambda (index) (harness-ui-patch-review--approved-p review (nth index files)))
                     (cl-subseq order (1+ (min a b)) (max a b)))
      0)))

(defun harness-ui-patch-review--landing (review index)
  "Return the index of the file point goes to when the Ediff of INDEX ends.
The next file to review, so the next one that is not approved while
`harness-ui-patch-review-skip-approved' is on; else INDEX itself."
  (or (harness-ui-patch-review--neighbor review index 1) index))

(defun harness-ui-patch-review--dir-files (review path)
  "Return the files of REVIEW under the directory at PATH."
  (let ((prefix (concat path "/")))
    (cl-remove-if-not (lambda (file) (string-prefix-p prefix (change-review-file-path file)))
                      (harness-ui-patch-review--r-files review))))

(cl-defun harness-ui-patch-review--directory-row (review node path depth &key compact)
  "Return the row of directory NODE, at PATH, at DEPTH in the file tree.
It says how many files the directory holds and the lines they add and
delete, and whether it is folded (`harness-ui-patch-review-toggle-directory');
COMPACT leaves the count of files out."
  (pcase-let* ((`(,count ,added ,deleted) (harness-ui-patch-review--tree-stats node))
               (indent (harness-ui-patch-review--tree-indent depth))
               (folded (gethash path (harness-ui-patch-review--r-folded review)))
               (row (concat indent
                            (propertize (if folded "▸ " "▾ ") 'face 'harness-dim-face)
                            (propertize (concat (plist-get node :name) "/") 'face 'bold)
                            (if compact ""
                              (concat "  " (propertize (harness-ui-patch-review--plural count "file")
                                                       'face 'harness-dim-face)))
                            (if (> (+ added deleted) 0)
                                (concat "  " (propertize (format "+%d" added) 'face 'harness-ui-patch-review-plus-face)
                                        " " (propertize (format "−%d" deleted) 'face 'harness-ui-patch-review-minus-face))
                              ""))))
    (add-text-properties 0 (length row)
                         (list 'harness-ui-patch-review-dir path
                               'harness-ui-patch-review-task (harness-ui-patch-review--r-id review)
                               'mouse-face 'highlight
                               'help-echo (format "%s/\nRET, TAB or a click: %s; a approves its files"
                                                  path (if folded "unfold it" "fold it"))
                               'keymap harness-ui-patch-review--dir-map)
                         row)
    (concat row "\n")))

(cl-defun harness-ui-patch-review--tree-lines (review node depth width counts indices
                                                      &key path compact avail current)
  "Return the rows of tree NODE at DEPTH, as REVIEW's report shows them.
WIDTH pads a file's name; COUNTS are the box's comments; INDICES maps
each file to its place among REVIEW's files.  PATH is NODE's, nil at the
top.  COMPACT, AVAIL and CURRENT are those of `harness-ui-patch-review--row'.
A folded directory shows its own row alone."
  (let ((indent (harness-ui-patch-review--tree-indent depth)))
    (mapconcat
     (lambda (entry)
       (pcase (cadr entry)
         ('file
          (let ((file (cddr entry)))
            (concat (harness-ui-patch-review--row
                     review file (gethash file indices) width counts
                     :indent indent :label (harness-ui-patch-review--tree-label file)
                     :compact compact :avail avail
                     :current (eql current (gethash file indices)))
                    "\n")))
         ('dir
          (let* ((child (cddr entry))
                 (child-path (if path (concat path "/" (plist-get child :name)) (plist-get child :name))))
            (concat (harness-ui-patch-review--directory-row review child child-path depth
                                                            :compact compact)
                    (if (gethash child-path (harness-ui-patch-review--r-folded review))
                        ""
                      (harness-ui-patch-review--tree-lines
                       review child (1+ depth) width counts indices
                       :path child-path :compact compact :avail avail :current current)))))))
     (harness-ui-patch-review--tree-entries node) "")))

(defun harness-ui-patch-review--review-here ()
  "Return the review of the changes at point, or nil.
In a surface of the changes -- the report, the review banner of a task's
session, the tree beside Ediff -- from any row of them, and anywhere in
the report or the session of the task."
  (or (car (harness-ui-patch-review--at-point))
      (harness-ui-patch-review--known
       (get-text-property (line-beginning-position) 'harness-ui-patch-review-task))
      harness-ui-patch-review--review
      (when (derived-mode-p 'harness-ui-popout-mode)
        (when-let* ((task (and (fboundp 'harness-ui-report-task)
                               (harness-ui-report-task))))
          (harness-ui-patch-review--known (plist-get task :id))))
      (when (and (derived-mode-p 'harness-chat-mode) (bound-and-true-p harness-ui-session-id)
                 (fboundp 'harness-ui-review--task))
        (when-let* ((task (harness-ui-review--task harness-ui-session-id)))
          (harness-ui-patch-review--known (plist-get task :id))))))

(defun harness-ui-patch-review--threads-position ()
  "Return where the threads begin in this buffer, or nil."
  (harness-ui-patch-review--find-property
   'harness-ui-patch-review-threads t (harness-ui-patch-review--section-start)))

(defun harness-ui-patch-review-threads (&optional filter)
  "Go to the threads of the review at point: a section below its files.
In the report of a task's changes, in its session's review banner and in
the tree beside Ediff, point goes to the heading of the threads in the
same buffer.  From Ediff, in the control panel or in either version, the
tree is shown beside it (`harness-ui-patch-review-ediff-tree') and point
goes there.  Without a tree, the library's threads view lists them in a
buffer of its own (`change-review-open-threads').  FILTER, `open',
`unreviewed' (the threads the agent closed that you have not reviewed),
`closed' or `all', is the status to show them by, by default the
buffer's.  \\<change-review-threads-mode-map>\\[change-review-ui-quote-reply] there replies with what you selected of a comment
quoted."
  (interactive)
  (let ((review (or (harness-ui-patch-review--review-here)
                    (user-error "No review here"))))
    (when (and filter change-review-ui--redraw-function)
      (change-review-ui-set-filter filter))
    (if-let* ((pos (harness-ui-patch-review--threads-position)))
        (progn
          (goto-char pos)
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (set-window-point window pos)
            (with-selected-window window (recenter 1))))
      (if-let* ((window (and (harness-ui-patch-review--r-ediff review)
                             harness-ui-patch-review-ediff-tree
                             (harness-ui-patch-review--keep-tree review))))
          (progn
            (select-window window)
            (with-current-buffer (window-buffer window)
              (when (and filter change-review-ui--redraw-function)
                (change-review-ui-set-filter filter))
              (when-let* ((pos (harness-ui-patch-review--threads-position)))
                (goto-char pos)
                (set-window-point window pos)
                (recenter 1))))
        (let ((buffer (change-review-open-threads (harness-ui-patch-review--r-set review) filter)))
          ;; The links of its comments to files are the branch's.
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq default-directory (harness-ui-patch-review--link-directory review))))
          buffer)))))

(defun harness-ui-patch-review-toggle-file-tree ()
  "Show the changed files flat, in the diff's order, or as a tree.
In a report showing the changes, from a row or anywhere else in it."
  (interactive)
  (let ((review (or (harness-ui-patch-review--review-here)
                    (user-error "No changes here to show as a tree"))))
    (setf (harness-ui-patch-review--r-tree review)
          (not (harness-ui-patch-review--r-tree review)))
    (harness-ui-patch-review--refresh review)
    (message "The files show %s" (if (harness-ui-patch-review--r-tree review)
                                     "as a tree"
                                   "in a flat list"))))

(defun harness-ui-patch-review--dir-at-point ()
  "Return (REVIEW . PATH) for the directory row at point, or nil."
  (let* ((bol (line-beginning-position))
         (path (get-text-property bol 'harness-ui-patch-review-dir))
         (review (harness-ui-patch-review--known
                  (get-text-property bol 'harness-ui-patch-review-task))))
    (and path review (cons review path))))

(defun harness-ui-patch-review--reveal-file (review index)
  "Unfold the directories of REVIEW that hide the file at INDEX.
Return non-nil when one was folded."
  (let* ((path (change-review-file-path (nth index (harness-ui-patch-review--r-files review))))
         (parts (butlast (split-string path "/" t)))
         (folded (harness-ui-patch-review--r-folded review))
         (dir nil)
         changed)
    (dolist (part parts)
      (setq dir (if dir (concat dir "/" part) part))
      (when (gethash dir folded)
        (remhash dir folded)
        (setq changed t)))
    changed))

(defun harness-ui-patch-review-toggle-directory ()
  "Fold the directory of the row at point, or unfold it.
Its files go from the changes, and come back, in the report, the review
banner and the tree beside Ediff alike."
  (interactive)
  (pcase-let ((`(,review . ,path) (or (harness-ui-patch-review--dir-at-point)
                                      (user-error "No directory on this line"))))
    (let ((folded (harness-ui-patch-review--r-folded review)))
      (if (gethash path folded) (remhash path folded) (puthash path t folded)))
    (harness-ui-patch-review--refresh review)))

(defun harness-ui-patch-review-mouse-toggle-directory (event)
  "Fold or unfold the directory clicked on in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-patch-review-toggle-directory))


(defvar harness-ui-patch-review--spec-history nil
  "The diffs typed to choose what a report compares, newest first.")

(defun harness-ui-patch-review--selector-label (selector)
  "Return SELECTOR, a diff the report can show, as words for a message."
  (pcase selector
    ('since-review "the changes since the last review")
    ((pred stringp) (format-message "the diff `%s'" selector))
    (_ "the branch against its base")))

(defun harness-ui-patch-review--selector-of (choice)
  "Return CHOICE, which diff to show, as the review keeps it.
CHOICE is `base', which is nil, `since-review', or a string of
revisions, which is kept trimmed; one that cannot be right signals a
`user-error' (`harness-ui-patch-review--parse-spec')."
  (cond ((eq choice 'base) nil)
        ((stringp choice) (harness-ui-patch-review--parse-spec choice) (string-trim choice))
        (t choice)))

(defun harness-ui-patch-review--read-spec (review)
  "Read in the minibuffer revisions of REVIEW's repository to show a diff of.
They are as `harness-ui-patch-review--parse-spec' takes them; the ones
the report shows are what an empty answer takes."
  (let ((current (and (stringp (harness-ui-patch-review--r-selector review))
                      (harness-ui-patch-review--r-selector review))))
    (read-string (format-prompt "Diff of revisions (A..B, A...B, A B, or A against the branch)" current)
                 nil 'harness-ui-patch-review--spec-history current)))

(defun harness-ui-patch-review--read-selector (review)
  "Read in the minibuffer which diff REVIEW's report shows.
The answer is `base', `since-review' or, for revisions the reviewer
types, a string.  The three are offered in this order, with the one
shown now as the default."
  (let* ((choices (mapcar (lambda (choice)
                            (cons (car (harness-ui-patch-review--choice-text review choice)) choice))
                          '(base since-review other)))
         (answer (completing-read
                  "Show the diff: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity))
                      (complete-with-action action (mapcar #'car choices) string pred)))
                  nil t nil nil
                  (car (rassq (harness-ui-patch-review--choice-current review) choices))))
         (choice (or (cdr (assoc answer choices))
                     (user-error "No such diff to show: %s" answer))))
    (if (eq choice 'other) (harness-ui-patch-review--read-spec review) choice)))

(defun harness-ui-patch-review-select-diff (&optional selector review)
  "Choose the diff the report of the changes shows.
Asked in the minibuffer, one of three: the task's branch against the
branch it was made from, what merging it brings in, which the report
starts with; the branch since its last review, what changed since the
work was last handed in; or any revisions of the repository, as `git
diff' takes them -- A..B, A...B (from the merge base of A and B), A B, or
A alone, against the branch -- from a prompt of their own.  The files,
their counts, Ediff and the threads follow the choice, which a report
keeps until another is made; one that cannot be read says why and leaves
the diff shown as it is.

From Lisp SELECTOR is `base', `since-review' or a string of revisions,
and REVIEW the review whose report it is for, by default the one at
point.  In the report of a task's changes, from a row or anywhere else in
it."
  (interactive)
  (let* ((review (or review (harness-ui-patch-review--review-here)
                     (user-error "No changes here to choose a diff for")))
         ;; What cannot be right is refused before the report changes.
         (selector (harness-ui-patch-review--selector-of
                    (or selector (harness-ui-patch-review--read-selector review)))))
    (when (and (eq selector 'since-review) (harness-ui-patch-review--r-branch-tip review)
               (not (harness-ui-patch-review--last-review review (harness-ui-patch-review--r-branch-tip review))))
      (user-error "%s" harness-ui-patch-review--no-earlier-review))
    ;; The files Ediff compares are the old diff's: it ends first.
    (when (harness-ui-patch-review--r-ediff review)
      (harness-ui-patch-review--end-ediff review))
    (setf (harness-ui-patch-review--r-selector review) selector
          (harness-ui-patch-review--r-selection-error review) nil)
    (message "Reading %s…" (harness-ui-patch-review--selector-label selector))
    (harness-ui-patch-review--load review)))


(defun harness-ui-patch-review--viewed-text (review &optional short)
  "Return how much of REVIEW is reviewed: \"N of M files viewed, K left\".
N is how many files were compared in Ediff (`harness-ui-patch-review--seen-p'),
or taken as viewed, which the text says when the harness did.  SHORT
leaves the words out: \"N/M viewed, K approved\"."
  (let* ((files (harness-ui-patch-review--r-files review))
         (seen (cl-count-if (lambda (file) (harness-ui-patch-review--seen-p review file)) files))
         (approved (cl-count-if (lambda (file) (harness-ui-patch-review--approved-p review file)) files))
         (assumed (plist-get (harness-ui-patch-review--r-assumed review) :revision)))
    (if short
        (format "%d/%d viewed%s" seen (length files)
                (if (> approved 0) (format ", %d approved" approved) ""))
      (format "%d of %s viewed, %d left%s%s"
              seen (harness-ui-patch-review--plural (length files) "file")
              (- (length files) seen)
              (if (> approved 0) (format ", %d approved" approved) "")
              (if assumed
                  (format ", unchanged since %s taken as viewed" (harness-ui-patch-review--short assumed))
                "")))))

(defun harness-ui-patch-review--kind (review)
  "Return what the diff REVIEW's report shows is.
`base' is the branch against its merge base with the branch it was made
from, the default; `since-review' the branch against where it was when
its work was last handed in; `custom' the revisions the reviewer typed."
  (pcase (harness-ui-patch-review--r-shown-selector review)
    ('nil 'base)
    ('since-review 'since-review)
    (_ 'custom)))

(defun harness-ui-patch-review--ref-text (name commit)
  "Return what to call COMMIT, which was asked for as NAME: \"NAME @ abc1234\".
Only the short COMMIT when NAME is the start of it already."
  (let ((short (harness-ui-patch-review--short commit)))
    (if (or (not (stringp name)) (string-empty-p name)
            (and (stringp commit) (string-prefix-p name commit)))
        short
      (format "%s @ %s" name short))))

(defun harness-ui-patch-review--old-name (review)
  "Return what REVIEW's report calls the old side of the diff it shows.
It is the branch the task was made from for the default diff, the version
for the diff since the last review, and the revision typed for another."
  (or (harness-ui-patch-review--r-old-name review)
      (harness-ui-patch-review--r-base review)))

(defun harness-ui-patch-review--new-name (review)
  "Return what REVIEW's report calls the new side of the diff it shows."
  (or (harness-ui-patch-review--r-new-name review)
      (harness-ui-patch-review--r-branch review)))

(defun harness-ui-patch-review--diff-text (review)
  "Return what the heading of REVIEW's changes says is compared.
The new side, then the old one with where it is: \"task/fix against main @
8d1fb32\" for the default diff, \"task/fix since v1 @ 1c9e4a0\" for the diff
since the last review, \"HEAD against main~3 @ 5be0a77\" for another."
  (let* ((kind (harness-ui-patch-review--kind review))
         (tip (harness-ui-patch-review--r-tip review))
         (old (harness-ui-patch-review--r-merge-base review))
         (old-name (harness-ui-patch-review--old-name review))
         (new-name (harness-ui-patch-review--new-name review)))
    (concat
     (propertize new-name 'face 'bold)
     (propertize (format " %s %s" (if (eq kind 'since-review) "since" "against")
                         (harness-ui-patch-review--ref-text old-name old))
                 'face 'harness-dim-face
                 'help-echo
                 (pcase kind
                   ('since-review
                    (format "%s at %s against where it was at the last review, %s (%s): what it changed since then"
                            new-name (harness-ui-patch-review--short tip) old-name
                            (harness-ui-patch-review--short old)))
                   ('custom
                    (format "The diff %s: %s at %s against %s at %s"
                            (harness-ui-patch-review--r-shown-selector review)
                            new-name (harness-ui-patch-review--short tip)
                            old-name (harness-ui-patch-review--short old)))
                   (_
                    (format "The branch at %s against its merge base with %s, %s: what merging it brings in"
                            (harness-ui-patch-review--short tip) old-name
                            (harness-ui-patch-review--short old))))))))


(defun harness-ui-patch-review--heading (review &optional compact)
  "Return the first line of REVIEW's changes: what is compared, how much changed.
It also says how many threads the review has, open and closed.
COMPACT, for the tree beside Ediff, says how many files and how far
through them the reviewer is, and no more."
  (let* ((files (harness-ui-patch-review--r-files review))
         (tip (harness-ui-patch-review--r-tip review))
         (counts (change-review-thread-counts (harness-ui-patch-review--r-set review)))
         (open (plist-get counts :open))
         (closed (plist-get counts :closed))
         (unreviewed (plist-get counts :unreviewed))
         (label (propertize (if tip (format "Changes (%d)" (length files)) "Changes") 'face 'harness-label-face)))
    (harness-ui-with-keymap
     (propertize
     (if compact
         (concat label
                 (if (null files) ""
                   (concat "  " (propertize (harness-ui-patch-review--viewed-text review t)
                                             'face 'harness-dim-face))))
       (concat
        label
        ;; How far through the files the reviewer is, just after the count.
        (if (null files) ""
          (concat "   " (propertize (harness-ui-patch-review--viewed-text review)
                                    'face 'harness-dim-face
                                    'help-echo "The files you have compared in Ediff, those approved, and those left; V takes the files the newest commit did not change as viewed")))
        (if (not tip) ""
          (concat
           "   " (harness-ui-patch-review--diff-text review)
           (if (null files) ""
             (concat "   " (propertize (format "+%d" (apply #'+ (mapcar #'change-review-file-added files)))
                                       'face 'harness-ui-patch-review-plus-face)
                     " " (propertize (format "−%d" (apply #'+ (mapcar #'change-review-file-deleted files)))
                                     'face 'harness-ui-patch-review-minus-face)))))
        (if (> (+ open closed) 0)
            (concat "   " (propertize (format "%d open, %d closed" open closed)
                                      'face 'harness-ui-patch-review-comments-face
                                      'help-echo "The threads of comments, below the files: T goes to them")
                    (if (> unreviewed 0)
                        (concat " " (harness-ui-patch-review--to-review-button unreviewed))
                      "")
                    " " (harness-ui-patch-review--threads-button))
          "")))
     'harness-ui-patch-review-task (harness-ui-patch-review--r-id review))
     harness-ui-patch-review--common-map)))

(defun harness-ui-patch-review--to-review-button (count)
  "Return the heading's button that lists the COUNT threads to review.
Those are the threads the agent closed that the reviewer has not looked
at yet."
  (propertize (buttonize (format "[%d to review]" count)
                         (lambda (_) (harness-ui-patch-review-threads 'unreviewed))
                         nil "The threads the agent closed that you have not reviewed yet: list them")
              ;; The warning's colour, a button's underline.
              'face '(change-review-ui-review-face button)
              'mouse-face 'highlight))

(defun harness-ui-patch-review--threads-button ()
  "Return the [Threads] button of the report's heading."
  (propertize (buttonize "[Threads]" (lambda (_) (harness-ui-patch-review-threads))
                         nil "Go to the threads of comments, below the files")
              'mouse-face 'highlight))

(defun harness-ui-patch-review--toggle-button (label short on key command help)
  "Return a button for a setting: LABEL (SHORT when compact), ON or off, KEY.
Pressing it runs COMMAND, which switches the setting; HELP says what it
does.  A check mark in the brackets says the setting is on."
  (concat (propertize (buttonize (format "[%s] %s" (if on "✓" " ") (or short label))
                                 (lambda (_) (call-interactively command)) nil help)
                      'mouse-face 'highlight)
          " " (harness-ui-kbd key)))

(defun harness-ui-patch-review--toggles (review &optional compact)
  "Return the line of REVIEW's settings: what is skipped, approved and shown.
Skipping the files already approved, approving the files you went
through without a comment, the tree or the flat list; each a button with
its key.  COMPACT uses shorter words."
  (harness-ui-with-keymap
   (propertize
   (concat "  "
           (harness-ui-patch-review--toggle-button
            "Skip approved" (and compact "skip") harness-ui-patch-review-skip-approved
            "s" #'harness-ui-patch-review-toggle-skip-approved
            "Going on from file to file steps over the files already approved")
           "   "
           (harness-ui-patch-review--toggle-button
            "Auto-approve" (and compact "auto") harness-ui-patch-review-auto-approve
            "u" #'harness-ui-patch-review-toggle-auto-approve
            "A file you went through to its last difference and made no comment on is approved as you leave it")
           "   "
           (harness-ui-patch-review--toggle-button
            "Tree" nil (harness-ui-patch-review--r-tree review)
            "t" #'harness-ui-patch-review-toggle-file-tree
            "The files grouped by directory, or in a flat list")
           "\n")
   'harness-ui-patch-review-task (harness-ui-patch-review--r-id review))
   harness-ui-patch-review--common-map))

(defun harness-ui-patch-review--notes (review)
  "Return the lines that tell what to know about REVIEW, above its files."
  (let ((tip (harness-ui-patch-review--r-tip review)))
    (delq nil
          (list
           (and (harness-ui-patch-review--r-loading review)
                (propertize (if tip "Reading the branch again…" "Reading the branch…") 'face 'harness-dim-face))
           (and (harness-ui-patch-review--r-error review)
                (concat (propertize (format "Could not read the branch: %s" (harness-ui-patch-review--r-error review))
                                    'face 'error)
                        "  "
                        (propertize (buttonize "[Try again]"
                                               (lambda (_) (harness-ui-patch-review--load review))
                                               nil "Read the branch again")
                                    'mouse-face 'highlight)))
           ;; The diff the reviewer chose was not there to read: the one
           ;; before is shown, and this says why.
           (and (harness-ui-patch-review--r-selection-error review)
                (propertize (harness-ui-patch-review--r-selection-error review) 'face 'error))
           (let ((drafts (length (and (harness-ui-patch-review--r-set review)
                                      (change-review-drafts (harness-ui-patch-review--r-set review))))))
             (and (> drafts 0)
                  (propertize (format "%s to send: they go with the feedback that sends the task back, an empty box included."
                                      (harness-ui-patch-review--plural drafts "draft"))
                              'face 'change-review-ui-draft-face)))
           (and (harness-ui-patch-review--r-dirty review)
                (propertize "Its worktree has changes not committed: they are not on the branch, so not here."
                            'face 'warning))
           (and tip (null (harness-ui-patch-review--r-files review))
                (propertize (harness-ui-patch-review--nothing-text review) 'face 'harness-dim-face))))))

(defun harness-ui-patch-review--nothing-text (review)
  "Return what REVIEW's report says when the diff it shows changes no file."
  (let ((old-name (harness-ui-patch-review--old-name review)))
    (pcase (harness-ui-patch-review--kind review)
      ('since-review
       (format "Nothing changed since %s (%s): the branch is where it was at the last review."
               old-name (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review))))
      ('custom
       (format "Nothing differs between %s and %s." old-name (harness-ui-patch-review--new-name review)))
      (_ (format "The branch changes nothing against %s." (harness-ui-patch-review--r-base review))))))

(defconst harness-ui-patch-review--hint
  "RET or a click compares a file in Ediff (a directory: folds it), n and p move between files, a approves one (✔ approved, ✓ only viewed: only the approved are skipped), A all of them, V takes the files the newest commit left alone as viewed; s and u switch skipping the approved files and approving those you go through without a comment, t the tree, d chooses the diff shown, T goes to the threads, e on a thread edits one of its drafts, k deletes one and K the thread when it is only drafts, m marks a thread the agent closed as reviewed (M all of them).  In Ediff c comments, r replies, e edits a draft or goes to the box, k deletes a draft and K a thread of drafts, N and P go to the next and previous file, q comes back."
  "What the report says under the changes.")

(defun harness-ui-patch-review--tree-width (&optional frame)
  "Return how many columns wide the tree beside Ediff is in FRAME.
`harness-ui-patch-review-ediff-tree-width', but at the most 40% of the
frame's width, and 24 columns at the least."
  (max 24 (min harness-ui-patch-review-ediff-tree-width
               (floor (* 0.4 (frame-width frame))))))

(defun harness-ui-patch-review--avail ()
  "Return how many columns a row of the tree beside Ediff may take.
That is the body of the narrowest window showing this buffer, less one
column for the continuation glyph; else the tree's width."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (1- (if windows
            (apply #'min (mapcar #'window-body-width windows))
          (harness-ui-patch-review--tree-width)))))


;;;;; Choosing the diff

(defvar harness-ui-patch-review--heading-map (make-sparse-keymap)
  "Keys on the heading of the changes and the line that chooses the diff.")

(let ((map harness-ui-patch-review--heading-map))
  (define-key map (kbd "d") #'harness-ui-patch-review-select-diff)
  (define-key map (kbd "t") #'harness-ui-patch-review-toggle-file-tree)
  (define-key map (kbd "T") #'harness-ui-patch-review-threads))

(defun harness-ui-patch-review--add-keymap (string map)
  "Give the stretches of STRING with no keymap of their own the keymap MAP.
A button keeps its own.  Return STRING."
  (let ((pos 0) (len (length string)))
    (while (< pos len)
      (let ((next (or (next-single-property-change pos 'keymap string) len)))
        (unless (get-text-property pos 'keymap string)
          (put-text-property pos next 'keymap map string))
        (setq pos next))))
  string)

(defun harness-ui-patch-review--choice-text (review choice)
  "Return (LABEL HELP) for CHOICE, one of the diffs REVIEW's report can show.
CHOICE is `base', `since-review' or `other'."
  (pcase choice
    ('base
     (let ((base (or (harness-ui-patch-review--r-base review)
                     (plist-get (harness-ui-patch-review--r-task review) :base)
                     "its base")))
       (list (format "Task branch against %s" base)
             (format "What merging the task's branch brings into %s: the branch against its merge base with it" base))))
    ('since-review
     (let ((last (and (harness-ui-patch-review--r-branch-tip review)
                      (harness-ui-patch-review--last-review
                       review (harness-ui-patch-review--r-branch-tip review)))))
       (list (if last (format "Since last review (%s)" (cdr last)) "Since last review")
             (if last
                 (format "What the branch changed since the last review: the branch against where it was at %s (%s)"
                         (cdr last) (harness-ui-patch-review--short (car last)))
               "What the branch changed since the last review -- no earlier review of this task is known"))))
    (_
     (let ((spec (and (stringp (harness-ui-patch-review--r-selector review))
                      (harness-ui-patch-review--r-selector review))))
       (list (if spec (format "Other: %s" spec) "Other…")
             "Any revisions of the repository: A..B, A...B (from the merge base), A B, or A for A against the branch")))))

(defun harness-ui-patch-review--choice-current (review)
  "Return which of the diffs REVIEW's report can show the reviewer chose."
  (pcase (harness-ui-patch-review--r-selector review)
    ('nil 'base)
    ('since-review 'since-review)
    (_ 'other)))

(defun harness-ui-patch-review--choice-button (review choice)
  "Return the button that shows the diff CHOICE of REVIEW, marked when chosen."
  (pcase-let* ((`(,label ,help) (harness-ui-patch-review--choice-text review choice))
               (chosen (eq choice (harness-ui-patch-review--choice-current review)))
               (button (buttonize (concat "[" (if chosen "● " "") label "]")
                                  (lambda (_) (harness-ui-patch-review--choose review choice))
                                  nil help)))
    (propertize (if chosen (propertize button 'face 'bold) button) 'mouse-face 'highlight)))

(defun harness-ui-patch-review--selector-line (review)
  "Return the line that chooses the diff REVIEW's report shows.
Three buttons, the one chosen marked: the task's branch against the
branch it was made from, the branch since its last review, and any
revisions the reviewer types.  \\<harness-ui-patch-review--heading-map>\
\\[harness-ui-patch-review-select-diff] chooses from the keyboard.  The
line ends in a newline."
  (harness-ui-patch-review--add-keymap
   (concat "  " (propertize "Diff" 'face 'harness-label-face) "   "
           (mapconcat (lambda (choice) (harness-ui-patch-review--choice-button review choice))
                      '(base since-review other) "  ")
           "\n")
   harness-ui-patch-review--heading-map))

(defun harness-ui-patch-review--choose (review choice)
  "Show the diff CHOICE of REVIEW's report: `base', `since-review' or `other'.
`other' asks for the revisions."
  (harness-ui-patch-review-select-diff
   (if (eq choice 'other) (harness-ui-patch-review--read-spec review) choice)
   review))


(defun harness-ui-patch-review--section (review counts &optional compact)
  "Return REVIEW's changes as its report shows them.
The heading, the settings, what to know, the files -- the tree or a flat
list -- and under them the threads.  COUNTS are its threads per file.
COMPACT draws it for the narrow tree beside Ediff: rows that fit, the
file Ediff compares marked, and no line of keys."
  (let* ((files (harness-ui-patch-review--r-files review))
         (indices (let ((table (make-hash-table :test 'eq)))
                    (cl-loop for file in files for index from 0
                             do (puthash file index table))
                    table))
         (tree (and (harness-ui-patch-review--r-tree review)
                    (harness-ui-patch-review--tree files)))
         (avail (and compact (harness-ui-patch-review--avail)))
         (current (and compact (plist-get (harness-ui-patch-review--r-ediff review) :index)))
         (width (min 60 (max 12 (apply #'max 0
                                       (mapcar (lambda (file)
                                                 (string-width (harness-ui-patch-review--tree-label file)))
                                               files))))))
    (concat
     (harness-ui-patch-review--heading review compact) "\n"
     ;; Not before there is a branch to choose a diff of.
     (if (and (not compact)
              (or (harness-ui-patch-review--r-tip review) (harness-ui-patch-review--r-loading review)))
         (harness-ui-patch-review--selector-line review)
       "")
     (harness-ui-patch-review--toggles review compact)
     (mapconcat (lambda (note) (propertize (concat "  " note "\n") 'wrap-prefix "  "))
                (harness-ui-patch-review--notes review) "")
     (if (null files) ""
       (concat "\n"
               (if tree
                   (harness-ui-patch-review--tree-lines review tree 0 width counts indices
                                                        :compact compact :avail avail :current current)
                 (cl-loop for file in files for index from 0
                          concat (concat (harness-ui-patch-review--row
                                          review file index width counts
                                          :compact compact :avail avail :current (eql current index))
                                         "\n")))
               (if compact ""
                 (concat (propertize (concat "  " harness-ui-patch-review--hint)
                                     'face 'harness-hint-face 'wrap-prefix "  ")
                         "\n"))))
     (if (or (harness-ui-patch-review--r-tip review)
             (change-review-set-threads (harness-ui-patch-review--r-set review)))
         (concat "\n" (harness-ui-patch-review--threads-section review compact))
       ""))))

;;;;; The surfaces

(defun harness-ui-patch-review--view (review redraw)
  "Make the current buffer a view of REVIEW's set, drawn again by REDRAW.
The library's commands then find the set, its threads and comments at
point, and its buttons -- the filter, where a comment was made -- draw
the buffer again; a change of the set draws it too
\(`change-review-changed-functions').  Which threads show starts as
`harness-ui-patch-review-closed-threads' says."
  (setq-local change-review-ui--set (harness-ui-patch-review--r-set review)
              change-review-ui--redraw-function redraw)
  (unless change-review-ui--filter
    (setq-local change-review-ui--filter (if harness-ui-patch-review-closed-threads 'all 'open))))

(defun harness-ui-patch-review--unavailable (task)
  "Return the line that says the changes of TASK cannot be shown here."
  (concat (propertize "Changes" 'face 'harness-label-face) "   "
          (propertize (if (harness-ui-patch-review--reviewing-p task)
                          (harness-ui-patch-review--why-not task)
                        (format "The repository of %s is not on this machine"
                                (harness-ui-patch-review--title
                                 (harness-ui-patch-review--review-for task))))
                      'face 'harness-dim-face)
          "\n"))

(defun harness-ui-patch-review--redraw-surfaces (id)
  "Draw again what shows the changes of task ID: its report and its chats.
For the surfaces of a review the next draw makes again, as one dropped
for being stale (`harness-ui-patch-review--known') or one that failed
to draw."
  (let ((key (list 'report id)))
    (when (harness-ui-popout-buffer key)
      (harness-ui-popout-refresh key)))
  (when (fboundp 'harness-ui-review--task)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'harness-chat-mode)
                   (bound-and-true-p harness-ui-session-id)
                   (functionp harness-compose-redraw-function)
                   (equal id (plist-get (harness-ui-review--task harness-ui-session-id) :id)))
          (funcall harness-compose-redraw-function))))))

(defun harness-ui-patch-review--try-again (id)
  "Make the review of task ID again, from the branch and the harness, and draw it.
What a surface that could not draw the changes offers
\(`harness-ui-patch-review--draw-failed')."
  (when-let* ((review (gethash id harness-ui-patch-review--reviews)))
    ;; A review that failed to draw may be in any state: what cannot be
    ;; ended in order is dropped as it is.
    (condition-case nil
        (harness-ui-patch-review--forget review)
      (error (remhash id harness-ui-patch-review--reviews))))
  (harness-ui-patch-review--redraw-surfaces id))

(defun harness-ui-patch-review--draw-failed (task err)
  "Return the lines shown for the changes of TASK that ERR kept from drawing.
The error is told short: an error may carry the very review it was
about, the files of the branch and the task's whole hand-in with it, and
a surface that printed that would be unreadable.  The harness log has
the same short message; [Try again] makes the review again, which what
an older version of the harness left behind may need."
  (let ((id (plist-get task :id)))
    (harness-log 'warn "patch review: could not draw the changes of %s: %s"
                 id (harness-error-short-message err 600))
    (concat (propertize "Changes" 'face 'harness-label-face) "   "
            (propertize (format "could not be drawn: %s" (harness-error-short-message err 200))
                        'face 'harness-tool-error-face)
            "  "
            (propertize (buttonize "[Try again]"
                                   (lambda (_) (harness-ui-patch-review--try-again id))
                                   nil "Make the review of this task again, from the branch and the harness")
                        'mouse-face 'highlight)
            "\n")))

(defmacro harness-ui-patch-review--drawing-safely (task &rest body)
  "Run BODY, which draws the changes of TASK, and return what it returns.
An error is no reason for a surface to lose the rest of what it draws --
the report's [Verify] and [Send back] come after the changes -- so it
returns the lines that say it instead (`harness-ui-patch-review--draw-failed')."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (harness-ui-patch-review--draw-failed ,task err))))

(defun harness-ui-patch-review--panel (task)
  "Return the changes of TASK for its report, while TASK waits for review.
On `harness-ui-report-panel-functions', called in the report popout on
every draw.  Nil for a task with no branch of its own; for one whose
repository is not on this machine, a line saying so.  A report opened
afresh reads the branch afresh.  A review opened from a session's
history for a task no longer waiting for one shows too: its review
says so (`harness-ui-patch-review--r-show').  Changes that cannot be
drawn say so in a line, and the report goes on."
  (harness-ui-patch-review--drawing-safely task
    (let ((existing (and task (plist-get task :id)
                         (harness-ui-patch-review--known (plist-get task :id)))))
      (when (and harness-ui-patch-review--active
                 (derived-mode-p 'harness-ui-popout-mode)
                 (or (harness-ui-patch-review--reviewing-p task)
                     (and existing (harness-ui-patch-review--r-show existing)))
                 (not (harness-string-blank-p (plist-get task :branch))))
        (if (not (harness-ui-patch-review--repository task))
            (harness-ui-patch-review--unavailable task)
          (let* ((review (harness-ui-patch-review--review-for task))
                 (harness-ui-patch-review--drawing t)
                 (popout (current-buffer))
                 (fresh (not (eq (harness-ui-patch-review--r-popout review) popout))))
            (setf (harness-ui-patch-review--r-popout review) popout)
            (harness-ui-patch-review--ensure-loaded review fresh)
            ;; C-c C-d in the report: back to its Ediff, else the review.
            (unless (bound-and-true-p harness-ui-patch-review-mode)
              (harness-ui-patch-review-mode 1))
            ;; Beside an Ediff the report keeps to its share of the frame, even
            ;; when it was shown again meanwhile; with none, to no share.
            (if (harness-ui-patch-review--r-ediff review)
                (harness-ui-patch-review--limit-box (current-buffer))
              (when harness-ui-patch-review--box-limit
                (harness-ui-patch-review--unlimit-box (current-buffer))))
            ;; The commands on a thread find its set here.
            (harness-ui-patch-review--view
             review (lambda () (harness-ui-patch-review--refresh-popout review)))
            (harness-ui-patch-review--section review (harness-ui-patch-review--counts review))))))))

(defun harness-ui-patch-review--banner-panel (task)
  "Return the changes of TASK for the review banner of its session.
On `harness-ui-review-changes-functions', called in the chat buffer on
every draw of its tail while TASK waits for review: the tree and the
threads, so the work is looked over where it is handed in, without
opening the report.  Nil for a task with no branch of its own; for one
whose repository is not on this machine, a line saying so.  Changes
that cannot be drawn say so in a line, and the banner goes on."
  (harness-ui-patch-review--drawing-safely task
    (when (and harness-ui-patch-review--active
               (derived-mode-p 'harness-chat-mode)
               (harness-ui-patch-review--reviewing-p task)
               (not (harness-string-blank-p (plist-get task :branch))))
      (if (not (harness-ui-patch-review--repository task))
          (harness-ui-patch-review--unavailable task)
        (let ((review (harness-ui-patch-review--review-for task))
              (harness-ui-patch-review--drawing t))
          (cl-pushnew (current-buffer) (harness-ui-patch-review--r-banners review))
          (harness-ui-patch-review--ensure-loaded review)
          (harness-ui-patch-review--view
           review (lambda () (harness-ui-patch-review--redraw-chat (current-buffer))))
          (harness-ui-patch-review--section review (harness-ui-patch-review--counts review)))))))

;;;;; Keeping the reader's place in a chat

(defun harness-ui-patch-review--section-start ()
  "Return where the changes can start in this buffer.
In a chat that is the end of the transcript, the tail being where the
review banner draws them; else the start of the buffer."
  (if (and (derived-mode-p 'harness-chat-mode) (boundp 'harness-chat--transcript-end)
           (markerp harness-chat--transcript-end) (marker-position harness-chat--transcript-end))
      (marker-position harness-chat--transcript-end)
    (point-min)))

(defun harness-ui-patch-review--find-property (property value start)
  "Return where text with PROPERTY equal to VALUE first starts after START, or nil."
  (let ((pos start) found)
    (while (and (not found) pos (< pos (point-max)))
      (if (equal (get-text-property pos property) value)
          (setq found pos)
        (setq pos (next-single-property-change pos property nil (point-max)))))
    found))

(defun harness-ui-patch-review--run-start (pos property)
  "Return where the run of text with the PROPERTY that POS has starts."
  (let ((value (get-text-property pos property)))
    (while (and (> pos (point-min)) (equal value (get-text-property (1- pos) property)))
      (setq pos (previous-single-property-change pos property nil (point-min))))
    pos))

(defconst harness-ui-patch-review--anchor-properties
  '(change-review-comment change-review-thread harness-ui-patch-review-file
    harness-ui-patch-review-dir harness-ui-patch-review-threads)
  "What marks a place in the changes, the most particular first.")

(defun harness-ui-patch-review--anchor-at (pos)
  "Return where POS is in the changes, to find it again after a redraw, or nil.
It is (PROPERTY VALUE LINES COLUMN ID OFFSET): the comment, thread, file,
directory or heading of the threads the line of POS is on, how many
lines under its start POS is, and the column; and, for when what it
names is gone from the redraw (a thread closed under a filter that hides
closed ones), the id of the task whose changes these are and how many
lines POS is under their first line.  Nil when POS is not on a row of
the changes."
  (save-excursion
    (goto-char pos)
    (let* ((bol (line-beginning-position))
           (column (current-column))
           (id (get-text-property bol 'harness-ui-patch-review-task))
           (base (and id (harness-ui-patch-review--find-property
                          'harness-ui-patch-review-task id (harness-ui-patch-review--section-start)))))
      (when (and id base)
        (let ((offset (- (line-number-at-pos bol) (line-number-at-pos base))))
          (or (cl-loop for property in harness-ui-patch-review--anchor-properties
                       for value = (get-text-property bol property)
                       when value
                       return (list property value
                                    (- (line-number-at-pos bol)
                                       (line-number-at-pos (harness-ui-patch-review--run-start bol property)))
                                    column id offset))
              (list nil nil 0 column id offset)))))))

(defun harness-ui-patch-review--goto-anchor (anchor)
  "Put point where ANCHOR, from `harness-ui-patch-review--anchor-at', says.
On the very row, comment or thread when it is still drawn; else on the
same line under the first line of the changes, which is the next row
when one went (a thread closed), and the last line of them at the most.
Return the position, or nil when the changes are not drawn at all."
  (pcase-let ((`(,property ,value ,lines ,column ,id ,offset) anchor))
    (let ((found (and property
                      (harness-ui-patch-review--find-property
                       property value (harness-ui-patch-review--section-start)))))
      (if found
          (progn (goto-char found)
                 (forward-line lines)
                 (move-to-column column)
                 (point))
        (when-let* ((base (and id (harness-ui-patch-review--find-property
                                   'harness-ui-patch-review-task id
                                   (harness-ui-patch-review--section-start)))))
          (goto-char base)
          (forward-line offset)
          ;; Not past the changes: back to the last line that has them.
          (while (and (> (point) base)
                      (not (equal id (get-text-property (line-beginning-position)
                                                        'harness-ui-patch-review-task))))
            (forward-line -1))
          ;; In the middle of a thread: at its start, as the thread that
          ;; took the place of the one that went reads from its header.
          (when (get-text-property (line-beginning-position) 'change-review-thread)
            (goto-char (harness-ui-patch-review--run-start
                        (line-beginning-position) 'change-review-thread)))
          (point))))))

(defun harness-ui-patch-review--screen-line (window pos)
  "Return the screen line of WINDOW that POS is on, counted from 0 at its top."
  (let ((lines (count-screen-lines (window-start window) pos nil window)))
    (if (save-excursion (goto-char pos) (bolp)) lines (max 0 (1- lines)))))

(defun harness-ui-patch-review--redraw-chat (buffer)
  "Draw the tail of the chat BUFFER again, the reader keeping their place.
The tail is deleted and drawn again whole, which puts point in the box
and a window that showed the end back at the end: a reader on a row of
the changes would lose it at each key that approves a file.  So where
point was in the changes it is put back on the same row -- the file,
the directory, the comment or the thread -- at the same line of the
window."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (functionp harness-compose-redraw-function)
        (let* ((window (or (and (eq (window-buffer (selected-window)) buffer) (selected-window))
                           (car (get-buffer-window-list buffer nil t))))
               (pos (and window (if (eq window (selected-window)) (point) (window-point window))))
               (anchor (and pos (harness-ui-patch-review--anchor-at pos)))
               (line (and anchor (harness-ui-patch-review--screen-line window pos))))
          (funcall harness-compose-redraw-function)
          (when (and anchor (window-live-p window) (eq (window-buffer window) buffer))
            (when-let* ((found (save-excursion (harness-ui-patch-review--goto-anchor anchor))))
              (if (eq window (selected-window))
                  (goto-char found)
                (set-window-point window found))
              (with-selected-window window
                (recenter line)))))))))

;;;;; Moving between the files

(defun harness-ui-patch-review--row-start (id index &optional buffer)
  "Return where the row of the file at INDEX of task ID starts in BUFFER, or nil.
BUFFER is the current buffer by default."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (let ((pos (harness-ui-patch-review--section-start))
            found)
        (while (and (not found) pos (< pos (point-max)))
          (setq pos (harness-ui-patch-review--find-property
                     'harness-ui-patch-review-file index pos))
          (when pos
            (if (equal (get-text-property pos 'harness-ui-patch-review-task) id)
                (setq found pos)
              (setq pos (or (next-single-property-change pos 'harness-ui-patch-review-file nil (point-max))
                            (point-max))))))
        found))))

(defun harness-ui-patch-review--at-point ()
  "Return (REVIEW . INDEX) for the row of a report at point, or nil."
  (let* ((bol (line-beginning-position))
         (index (get-text-property bol 'harness-ui-patch-review-file))
         (review (harness-ui-patch-review--known
                  (get-text-property bol 'harness-ui-patch-review-task))))
    (and index review (cons review index))))

(defun harness-ui-patch-review--goto-row (review index &optional start)
  "Put point on the row of REVIEW's file at INDEX in the surface Ediff began in.
That is the buffer the Ediff was started from, else the report.  The
directories that hide the row unfold.  With START, the report's windows
show from that line on, as before; any other surface shows the row."
  (let ((buffer (let ((origin (harness-ui-patch-review--r-origin review)))
                  (if (buffer-live-p origin)
                      origin
                    (harness-ui-patch-review--r-popout review)))))
    (when (buffer-live-p buffer)
      (when (harness-ui-patch-review--reveal-file review index)
        (harness-ui-patch-review--refresh review t))
      (with-current-buffer buffer
        (when-let* ((pos (harness-ui-patch-review--row-start (harness-ui-patch-review--r-id review) index)))
          (goto-char pos)
          (dolist (window (get-buffer-window-list buffer nil t))
            (when (and start (eq buffer (harness-ui-patch-review--r-popout review)))
              (set-window-start window (save-excursion (goto-char (point-min))
                                                       (forward-line (1- start))
                                                       (point))
                                t))
            (set-window-point window pos)
            (unless (pos-visible-in-window-p pos window)
              (with-selected-window window
                (goto-char pos)
                (recenter))))
          pos)))))

(defun harness-ui-patch-review--remaining (review index step)
  "Return how many files REVIEW shows beyond INDEX, in the direction of STEP."
  (let* ((order (harness-ui-patch-review--order review))
         (here (cl-position index order)))
    (if here
        (if (> step 0) (length (nthcdr (1+ here) order)) here)
      0)))

(defun harness-ui-patch-review--step-point (step)
  "Move point STEP rows on among the changes of a report.
To the next file that is not approved while
`harness-ui-patch-review-skip-approved' is on."
  (pcase-let* ((`(,review . ,index) (or (harness-ui-patch-review--at-point) (user-error "No file on this line")))
               (target (harness-ui-patch-review--neighbor review index step)))
    (cond
     (target
      (let ((skipped (harness-ui-patch-review--between review index target)))
        (harness-ui-patch-review--goto-row review target)
        (when (and (> skipped 0) harness-ui-patch-review-skip-approved)
          (message "Skipped %s already approved; s stops skipping them"
                   (harness-ui-patch-review--plural skipped "file")))))
     ((> (harness-ui-patch-review--remaining review index step) 0)
      (message "The %s files %s are approved; s stops skipping them"
               (harness-ui-patch-review--remaining review index step)
               (if (< step 0) "before this one" "after this one")))
     (t (message (if (< step 0) "That is the first file" "That is the last file"))))))

(defun harness-ui-patch-review-next-file (&optional n)
  "Move to the next file of the changes, or the Nth next.
Files already approved are skipped while `harness-ui-patch-review-skip-approved'
is on (\\<harness-ui-patch-review--row-map>\\[harness-ui-patch-review-toggle-skip-approved] switches it)."
  (interactive "p")
  (dotimes (_ (abs (or n 1)))
    (harness-ui-patch-review--step-point (if (< (or n 1) 0) -1 1))))

(defun harness-ui-patch-review-previous-file (&optional n)
  "Move to the previous file of the changes, or the Nth previous.
Files already approved are skipped while `harness-ui-patch-review-skip-approved'
is on."
  (interactive "p")
  (dotimes (_ (abs (or n 1)))
    (harness-ui-patch-review--step-point (if (< (or n 1) 0) 1 -1))))

;;;; The feedback box beside Ediff

;; The report is a popout, a window at the bottom of the frame, and its
;; box is the feedback.  Ediff takes the rest of the frame; the report
;; stays, smaller, so the box can be seen while the files are compared,
;; and a comment made in Ediff shows in it as it is made.

(defun harness-ui-patch-review--box-fraction ()
  "Return the fraction of its frame's height the report in this buffer may take.
It is the popout's height limit while an Ediff shows beside it."
  harness-ui-patch-review-ediff-box-height)

(defun harness-ui-patch-review--limit-box (popout)
  "Keep the report POPOUT to the height an Ediff leaves it."
  (with-current-buffer popout
    (unless harness-ui-patch-review--box-limit
      (setq harness-ui-patch-review--box-limit (list harness-ui-popout--max-height)))
    (setq-local harness-ui-popout--max-height #'harness-ui-patch-review--box-fraction)))

(defun harness-ui-patch-review--unlimit-box (popout)
  "Give the report POPOUT its height limit and its windows' freedom back."
  (when (buffer-live-p popout)
    (with-current-buffer popout
      (when harness-ui-patch-review--box-limit
        (setq-local harness-ui-popout--max-height (car harness-ui-patch-review--box-limit))
        (setq harness-ui-patch-review--box-limit nil)))
    (dolist (window (get-buffer-window-list popout nil t))
      (set-window-parameter window 'no-delete-other-windows nil))))

(defun harness-ui-patch-review--scroll-box (window &optional place)
  "Scroll WINDOW, showing a report, so the end of its feedback box is in sight.
The box ends on the window's last line.  With PLACE, (START . END) as
offsets in the box, that is what WINDOW shows the end of instead, and
where its point goes: a comment just made is in sight, whatever follows
it."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (harness-compose-live-p)
        (let ((pos (if place
                       (min harness-compose-end (+ harness-compose-start (cdr place)))
                     harness-compose-end)))
          (set-window-point window pos)
          (with-selected-window window
            (save-excursion
              (goto-char pos)
              (recenter -1))))))))

(defun harness-ui-patch-review--fit-box (window)
  "Fit WINDOW, showing a report, to the part of the frame it takes beside Ediff."
  (let ((lines (max harness-ui-popout-min-height
                    (floor (* harness-ui-patch-review-ediff-box-height
                              (frame-height (window-frame window))))))
        (window-resize-pixelwise t))
    (ignore-errors (fit-window-to-buffer window lines harness-ui-popout-min-height))
    (harness-ui-patch-review--scroll-box window)))

(defun harness-ui-patch-review--box-window (popout &optional frames)
  "Return the window of the report POPOUT that is the box's, or nil.
It is looked for in the selected frame, or in FRAMES, which is the
ALL-FRAMES of `get-buffer-window-list': t for every frame.  That is the
side window the report shows in (`harness-ui-popout--display'), its own.
A window of any other kind that shows the same buffer is not: a window
configuration set back puts the buffer that comes first among the
others in every window it re-creates for one that was killed, and the
end of an Ediff within `save-window-excursion'
\(`harness-ui-patch-review--end-ediff') sets one back -- twice, under a
hook of `ediff-quit-hook' that restores the configuration saved before
Ediff.  The report is not in those windows to be read, and the box is
not to be taken for one."
  (cl-find-if (lambda (window) (window-parameter window 'window-side))
              (get-buffer-window-list popout nil frames)))

(defun harness-ui-patch-review--keep-box (review)
  "Keep REVIEW's report in the selected frame, for Ediff to leave be.
Its window is returned: the report's own at the bottom of the frame
\(`harness-ui-patch-review--box-window'), or one it is shown in now when
it was closed; either way it is not one Ediff takes
\(`no-delete-other-windows'), is limited to
`harness-ui-patch-review-ediff-box-height' of the frame, and shows the
end of the feedback box.  The box alone is kept: another window showing
the report is Ediff's like any other, and loses the mark if it has it
from earlier.  Nil when there is no report open with a box, or the
option is nil."
  (let ((popout (harness-ui-patch-review--r-popout review)))
    (when (and harness-ui-patch-review-ediff-box-height (buffer-live-p popout)
               (with-current-buffer popout (harness-compose-live-p)))
      (let ((window (or (harness-ui-patch-review--box-window popout)
                        (display-buffer-in-side-window popout harness-ui-popout-window-parameters))))
        (when (window-live-p window)
          (dolist (other (get-buffer-window-list popout nil (window-frame window)))
            (unless (eq other window)
              (set-window-parameter other 'no-delete-other-windows nil)))
          (harness-ui-patch-review--limit-box popout)
          (set-window-parameter window 'no-delete-other-windows t)
          (harness-ui-patch-review--fit-box window)
          window)))))

(defun harness-ui-patch-review--ediff-where ()
  "Return (SIDE . LINE) for where the reviewer is in this Ediff.
In the control panel that is the current difference
\(`harness-ui-patch-review--ediff-position'), in a version the line at point."
  (let ((state (harness-ui-patch-review--r-ediff (harness-ui-patch-review--current))))
    (if (eq (current-buffer) (plist-get state :control))
        (harness-ui-patch-review--ediff-position)
      (cons (if (eq (current-buffer) (plist-get state :a)) :old :new)
            (line-number-at-pos)))))

(defun harness-ui-patch-review-edit-feedback (&optional why)
  "Go to the report's feedback box, to write the words that go with the comments.
In an Ediff of a task's change, from the control panel or either
version.  The box is at the bottom of the frame, under Ediff; point goes
to its end.  Ediff stays as it is: \\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open] in the report goes back to it,
and \\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit] there sends the feedback, with the drafts of the threads.
WHY, a sentence, is said first in the echo area when something else brought
the reviewer here, a key that edits a draft where there is none."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (popout (harness-ui-patch-review--feedback-box review))
         (window (or (harness-ui-patch-review--keep-box review)
                     (user-error "The box is not shown beside Ediff: see `harness-ui-patch-review-ediff-box-height'"))))
    (select-window window)
    (goto-char (buffer-local-value 'harness-compose-end popout))
    (message "%sThe feedback: %s goes back to Ediff, %s sends it with the %s"
             (if why (concat why " ") "")
             (substitute-command-keys "\\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open]")
             (substitute-command-keys "\\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit]")
             (harness-ui-patch-review--plural
              (length (change-review-drafts (harness-ui-patch-review--r-set review))) "draft"))))

(defun harness-ui-patch-review--ediff-threads (review file)
  "Return the threads about FILE of REVIEW at the reviewer's place in Ediff.
In the control panel that is the current difference, in a version the
line at point; the threads placed on that line there."
  (let ((where (harness-ui-patch-review--ediff-where)))
    (when where
      (cl-remove-if-not
       (lambda (thread)
         (let ((placement (harness-ui-patch-review--placement review thread)))
           (and placement (eql (plist-get placement :line) (cdr where))
                (eq (plist-get placement :side) (if (eq (car where) :old) 'old 'new)))))
       (harness-ui-patch-review--file-threads review file)))))

(defun harness-ui-patch-review--ediff-thread ()
  "Return (REVIEW . THREAD) for the thread at the reviewer's place in Ediff.
Signal when there is none."
  (let* ((review (harness-ui-patch-review--current))
         (file (or (and (integerp harness-ui-patch-review--index)
                        (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (threads (harness-ui-patch-review--ediff-threads review file)))
    (cons review (or (car threads)
                     (user-error "No thread here; c starts one")))))

(defun harness-ui-patch-review-reply ()
  "Reply to the thread at the current difference, or at point, in Ediff.
As a draft, in the thread: it goes with the feedback."
  (interactive)
  (pcase-let ((`(,review . ,thread) (harness-ui-patch-review--ediff-thread)))
    (change-review-ui-reply-to-thread (harness-ui-patch-review--r-set review) thread)))

(defun harness-ui-patch-review--selected-version ()
  "Return the buffer of this Ediff's version with comment text selected, or nil.
The selection is the mouse's (`change-review-ui-mouse-select')."
  (let ((state (harness-ui-patch-review--r-ediff (harness-ui-patch-review--current))))
    (cl-find-if (lambda (buffer)
                  (and (buffer-live-p buffer)
                       (with-current-buffer buffer (change-review-ui--overlay-selection))))
                (list (plist-get state :b) (plist-get state :a)))))

(defun harness-ui-patch-review-quote-reply ()
  "Reply with a quote, from the control panel of an Ediff of a task's change.
With text of a comment selected in either version, a reply to that comment
with the text quoted, as \\<harness-ui-patch-review-lines-mode-map>\\[change-review-ui-quote-reply] does in the version.  Without, the
reply r makes, to the thread at the current difference, that starts with
its last comment quoted, as a mail's reply does, point under it.  Either
way a draft in the thread, which goes with the feedback."
  (interactive)
  (if-let* ((version (harness-ui-patch-review--selected-version)))
      (with-current-buffer version
        (call-interactively #'change-review-ui-quote-reply))
    (pcase-let ((`(,review . ,thread) (harness-ui-patch-review--ediff-thread)))
      (change-review-ui-reply-to-thread
       (harness-ui-patch-review--r-set review) thread
       (change-review-ui-quote-string
        (change-review-comment-body (change-review-thread-last-comment thread)))))))

(defun harness-ui-patch-review--region-ref (review)
  "Return the reference to the region selected in this version of a file of REVIEW.
A plist that says what a reply in a thread is about (`harness-thread-block'):
the file, the side the version is on -- `old' for the merge base's, `new'
for the branch's -- the first and last line of the region in it, the
revision the review is at, and the lines themselves."
  (let* ((index harness-ui-patch-review--index)
         (file (or (and (integerp index) (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (state (harness-ui-patch-review--r-ediff review))
         (side (if (eq (current-buffer) (plist-get state :a)) "old" "new"))
         (beg (region-beginning))
         (end (region-end))
         (first (line-number-at-pos beg t))
         ;; A region that ends at the start of a line stops on the line before.
         (last (line-number-at-pos (if (and (> end beg) (eq (char-before end) ?\n)) (1- end) end) t))
         (text (buffer-substring-no-properties beg end)))
    (when (string-blank-p text) (user-error "The selection is blank: select the lines to reply to"))
    (append (list :kind "diff" :file (change-review-file-path file) :side side :line first)
            (and (> last first) (list :end last))
            (and (harness-ui-patch-review--r-tip review) (list :revision (harness-ui-patch-review--r-tip review)))
            (list :text (string-trim-right text "\n+")))))

(defun harness-ui-patch-review--show-ref (review ref)
  "Show the lines REF, a reference of a reply in a thread, is of in REVIEW's Ediff."
  (let ((line (plist-get ref :line)))
    (if (integerp line)
        (harness-ui-patch-review--show-line
         review (cons (if (equal (format "%s" (plist-get ref :side)) "old") :old :new) line))
      (user-error "That reply is to no lines"))))

(defun harness-ui-patch-review-thread-reply ()
  "Start a reply in a thread to the lines selected in this version of a file.
The thread records where it is from: the file, the side -- the merge base's
or the branch's -- the lines and the revision, with the lines themselves.
It starts in the box of the feedback, as a card, and the words written
under it are the reply: sent with the feedback it is a comment in a thread
of the review, on those lines, which the agent answers.  Point goes to the
box.  The file has a comment of yours now, so it is not approved: a file
that was is no longer (`harness-ui-patch-review--withdraw-approval'), and
leaving it in Ediff does not approve it.  Without a region, or with text of
a comment selected with the mouse, this is the library's quote reply
\(\\[change-review-ui-quote-reply])."
  (interactive)
  (if (or (not (use-region-p)) (change-review-ui--overlay-selection))
      (call-interactively #'change-review-ui-quote-reply)
    (let* ((review (harness-ui-patch-review--current))
           (ref (harness-ui-patch-review--region-ref review))
           (popout (harness-ui-patch-review--feedback-box review)))
      (deactivate-mark)
      (with-current-buffer popout
        (setq-local harness-compose-thread-open-function
                    (lambda (_data ref) (harness-ui-patch-review--show-ref review ref)))
        (goto-char harness-compose-end)
        (harness-compose-add-thread (list ref)))
      ;; A file with a comment of the reviewer's is not an approved one.
      (let ((file (and (integerp harness-ui-patch-review--index)
                       (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))))
        (harness-ui-patch-review-edit-feedback
         (concat "A reply in a thread is waiting for your words."
                 (and (harness-ui-patch-review--withdraw-approval review file t)
                      (format " %s is no longer approved." (change-review-file-path file)))))))))

(defun harness-ui-patch-review-toggle-thread ()
  "Close the thread at the current difference, or at point, or open it again."
  (interactive)
  (pcase-let ((`(,review . ,thread) (harness-ui-patch-review--ediff-thread)))
    (change-review-ui-toggle-thread (harness-ui-patch-review--r-set review) thread)))

(defun harness-ui-patch-review-toggle-reviewed ()
  "Mark the thread at the current difference reviewed, or make it wait again.
In the control panel that is the thread at the current difference, in a
version the one under the line at point.  It is for a thread the agent
closed: you looked at what it answered, and it no longer waits for you.
Of several threads there, one that waits comes first."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (set (harness-ui-patch-review--r-set review))
         (file (or (and (integerp harness-ui-patch-review--index)
                        (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (threads (or (harness-ui-patch-review--ediff-threads review file)
                      (user-error "No thread here; c starts one"))))
    (change-review-ui-toggle-thread-reviewed
     set (or (cl-find-if (lambda (thread) (change-review-thread-unreviewed-p set thread)) threads)
             (car threads)))))

(defun harness-ui-patch-review--difference-ranges ()
  "Return the lines the current difference of this Ediff spans, per side.
A plist of `:old' and `:new', each (FIRST . LAST) lines of that version, nil
for a side the difference has no lines on, a deletion's branch side."
  (let ((n ediff-current-difference))
    (when (and (integerp n) (>= n 0) (< n ediff-number-of-differences))
      (let ((range (lambda (type buffer)
                     (let ((beg (ediff-get-diff-posn type 'beg n))
                           (end (ediff-get-diff-posn type 'end n)))
                       (when (< beg end)
                         (with-current-buffer buffer
                           (cons (line-number-at-pos beg t) (line-number-at-pos (1- end) t))))))))
        (list :old (funcall range 'A ediff-buffer-A)
              :new (funcall range 'B ediff-buffer-B))))))

(defun harness-ui-patch-review--difference-threads (review file)
  "Return the threads about FILE of REVIEW placed in the current difference.
All of them, on any line it spans, in either version: those the
difference shows."
  (let ((ranges (harness-ui-patch-review--difference-ranges))
        (set (harness-ui-patch-review--r-set review)))
    (cl-remove-if-not
     (lambda (thread)
       (let* ((placement (change-review-placement set thread))
              (line (plist-get placement :line))
              (range (plist-get ranges (if (eq (plist-get placement :side) 'old) :old :new))))
         (and (integerp line) range (<= (car range) line (cdr range)))))
     (harness-ui-patch-review--file-threads review file))))

(defun harness-ui-patch-review-cycle-fold ()
  "Fold the threads of the current difference: one line, conversation, all.
In the control panel of an Ediff of a task's change.  A closed thread
is one line at first; this shows its conversation, then all of it where
the window had no room for all of it, then one line again, for every
thread the difference shows, the first deciding.  In a version, TAB does
this for the threads under the line at point, and clicking the triangle
or the words of a thread does it for that thread."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (file (or (and (integerp harness-ui-patch-review--index)
                        (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (threads (harness-ui-patch-review--difference-threads review file)))
    (unless threads
      (user-error "No thread at this difference; TAB in a version folds the one under its line"))
    (change-review-ui-cycle-folds (harness-ui-patch-review--r-set review) threads)))

(defun harness-ui-patch-review-edit-comment ()
  "Edit a draft of yours under point in Ediff; else go to the feedback box.
In a version, a draft in the threads under the line at point; in the
control panel, in the threads at the current difference.  The only draft
there is edited at once; of several, which one is asked, the newest the
default.  Without a draft there, \\[harness-ui-patch-review-edit-feedback]'s: the box.
The [Edit] button of a draft edits that one, wherever point is."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (set (harness-ui-patch-review--r-set review))
         (file (and (integerp harness-ui-patch-review--index)
                    (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review))))
         (drafts (and file (change-review-ui-draft-candidates
                            (harness-ui-patch-review--ediff-threads review file)))))
    (if (null drafts)
        (harness-ui-patch-review-edit-feedback "No draft of yours here.")
      (pcase-let ((`(,thread . ,comment) (change-review-ui-choose-draft set drafts "Edit")))
        (change-review-ui-edit-comment set thread comment)))))

(defun harness-ui-patch-review--ediff-threads-here ()
  "Return (SET . THREADS) for the reviewer's place in this Ediff.
SET is the review's change set, THREADS the threads about the file at the
current difference, in the control panel, or at the line at point, in a
version (`harness-ui-patch-review--ediff-threads'); none, maybe."
  (let* ((review (harness-ui-patch-review--current))
         (file (and (integerp harness-ui-patch-review--index)
                    (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))))
    (cons (harness-ui-patch-review--r-set review)
          (and file (harness-ui-patch-review--ediff-threads review file)))))

(defun harness-ui-patch-review-delete-comment ()
  "Delete a draft of yours under point in Ediff, after asking.
Found as \\[harness-ui-patch-review-edit-comment] finds one: in a version, a draft in the threads
under the line at point; in the control panel, in the threads at the
current difference.  The only draft there is asked about at once; of
several, which one is asked, the newest the default.  With no draft there
it says so, and does not go to the feedback box.  The [Delete] button of
a draft deletes that one, wherever point is.  The first draft of a thread
that has more is deleted with the thread (`change-review-ui-delete-comment')."
  (interactive)
  (pcase-let* ((`(,set . ,threads) (harness-ui-patch-review--ediff-threads-here))
               (drafts (change-review-ui-draft-candidates threads)))
    (unless drafts
      (user-error "No draft of yours here"))
    (pcase-let ((`(,thread . ,comment) (change-review-ui-choose-draft set drafts "Delete")))
      (change-review-ui-delete-comment set thread comment))))

(defun harness-ui-patch-review-delete-thread ()
  "Delete a thread that is nothing but drafts, under point in Ediff, after asking.
In a version, one of the threads under the line at point; in the control
panel, one of the threads at the current difference.  The only one there
is asked about at once; of several, which one is asked, the newest the
default.  A thread with a comment that was sent is not deleted.  The
[Delete thread] button in the header of a thread of drafts deletes that
thread, wherever point is."
  (interactive)
  (pcase-let* ((`(,set . ,threads) (harness-ui-patch-review--ediff-threads-here))
               (drafts (cl-remove-if-not #'change-review-thread-draft-p threads)))
    (unless drafts
      (user-error (if threads
                      "No thread of drafts here: every one has a comment that was sent"
                    "No thread here")))
    (change-review-ui-delete-thread set (change-review-ui-choose-thread set drafts "Delete"))))

;;;; The tree beside Ediff

;; While Ediff compares a file, the changes show on the left of the frame
;; as a file tree shows beside an editor: the directories and the files
;; with their marks, the file Ediff compares marked and highlighted, and
;; under them the threads, in a buffer of their own.  RET or a click on a
;; file compares it in place of the one under way; TAB folds a directory.
;; The window is kept as the report's box is, for Ediff to leave be
;; (`no-delete-other-windows'), and goes when Ediff ends.  It is the
;; tree's own side window and no other window that shows the buffer
;; (`harness-ui-patch-review--tree-window'): going on to the next file ends
;; the Ediff under way within `save-window-excursion', and a restored window
;; configuration has windows again for the killed buffers, which may show
;; the tree; kept by Ediff, each would be one more tree beside the versions.

(defvar harness-ui-patch-review-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'harness-ui-patch-review-ediff-quit)
    (define-key map (kbd "g") #'harness-ui-patch-review-redraw-tree)
    (define-key map (kbd "C-c C-d") #'harness-ui-patch-review-open)
    map)
  "Keys of the tree beside Ediff, beside those of the rows of the changes.")

(define-derived-mode harness-ui-patch-review-tree-mode special-mode "Review-Files"
  "The changed files of a task's review, as a tree beside Ediff.
\\<harness-ui-patch-review--row-map>
\\[harness-ui-patch-review-ediff] or a click on a file compares it in place of the
one under way.
\\[harness-ui-patch-review-toggle-directory] on a directory folds it, or unfolds it.
\\[harness-ui-patch-review-next-file] and \\[harness-ui-patch-review-previous-file] move between the files; \\[harness-ui-patch-review-approve] approves one
\(a directory: its files).
\\[harness-ui-patch-review-toggle-skip-approved] switches skipping the approved files, \\[harness-ui-patch-review-toggle-auto-approve] approving the
files you went through.
\\[harness-ui-patch-review-threads] goes to the threads under the files.
\\<harness-ui-patch-review-tree-mode-map>\\[harness-ui-patch-review-ediff-quit] ends Ediff and gives the frame back."
  ;; The tree is a narrow window: its lines wrap, not truncate.
  (setq-local truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              header-line-format '(:eval (harness-ui-patch-review--tree-header))))

(defun harness-ui-patch-review--tree-header ()
  "Return the header line of the tree beside Ediff: the task's title."
  (concat " " (propertize (if harness-ui-patch-review--review
                              (harness-ui-patch-review--title harness-ui-patch-review--review)
                            "Changes")
                          'face 'harness-label-face)))

(defun harness-ui-patch-review--tree-buffer (review)
  "Return the buffer of the tree beside Ediff for REVIEW, made if need be.
It is a view of the review's set, so a change to the threads draws it
again."
  (let ((buffer (harness-ui-patch-review--r-tree-buffer review)))
    (if (buffer-live-p buffer)
        buffer
      (setq buffer (generate-new-buffer
                    (format "*Review files: %s*"
                            (harness-truncate-end (harness-ui-patch-review--title review) 40))))
      (with-current-buffer buffer
        (harness-ui-patch-review-tree-mode)
        (setq-local harness-ui-patch-review--review review)
        (harness-ui-patch-review--view
         review (lambda () (harness-ui-patch-review--draw-tree review))))
      (setf (harness-ui-patch-review--r-tree-buffer review) buffer))))

(defun harness-ui-patch-review--draw-tree (review)
  "Draw the tree beside Ediff of REVIEW again, when it is open.
Point stays on the row it was on, the window where it was; when the
reader is elsewhere, in Ediff, the row of the file under comparison is in
sight."
  (let ((buffer (harness-ui-patch-review--r-tree-buffer review)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((inhibit-read-only t)
               (harness-ui-patch-review--drawing t)
               (windows (get-buffer-window-list buffer nil t))
               (window (car windows))
               (selected (and window (eq window (selected-window))))
               (pos (and window (if selected (point) (window-point window))))
               (anchor (and selected pos (harness-ui-patch-review--anchor-at pos)))
               (line (and anchor (harness-ui-patch-review--screen-line window pos))))
          (erase-buffer)
          (insert (harness-ui-patch-review--section
                   review (harness-ui-patch-review--counts review) t))
          (set-buffer-modified-p nil)
          (let ((target (or (and anchor (save-excursion (harness-ui-patch-review--goto-anchor anchor)))
                            (when-let* ((index (plist-get (harness-ui-patch-review--r-ediff review) :index)))
                              (harness-ui-patch-review--row-start
                               (harness-ui-patch-review--r-id review) index))
                            (point-min))))
            (goto-char target)
            (dolist (w windows)
              (set-window-point w target)
              (with-selected-window w
                (cond (line (recenter line))
                      ((not (pos-visible-in-window-p target w)) (recenter)))))))))))

(defun harness-ui-patch-review-redraw-tree ()
  "Draw the tree beside Ediff again."
  (interactive)
  (harness-ui-patch-review--draw-tree
   (or harness-ui-patch-review--review (user-error "No review here"))))

(defun harness-ui-patch-review--tree-window (review)
  "Return the window that shows the tree beside Ediff of REVIEW, or nil.
It is looked for in the selected frame.  That is the side window the tree
is shown in (`harness-ui-patch-review--keep-tree'), its own.  A window of
any other kind that shows the same buffer is not: a window configuration
set back puts the buffer that comes first among the others in every
window it re-creates for one that was killed, and the end of the Ediff
under way, to go on to the next file, sets one back within
`save-window-excursion' (`harness-ui-patch-review--end-ediff') -- twice,
under a hook of `ediff-quit-hook' that restores the configuration saved
before Ediff.  The tree is not in those windows to be read; taken for the
tree's, each would be kept by Ediff, and every file after it would have
the tree once more."
  (let ((buffer (harness-ui-patch-review--r-tree-buffer review)))
    (and (buffer-live-p buffer)
         (cl-find-if (lambda (window) (window-parameter window 'window-side))
                     (get-buffer-window-list buffer nil (selected-frame))))))

(defun harness-ui-patch-review--keep-tree (review)
  "Show the tree beside Ediff of REVIEW on the left of the selected frame.
Its window is returned: the side window it has
\(`harness-ui-patch-review--tree-window'), else a new one made for it
`harness-ui-patch-review-ediff-tree-width' wide; either way it is one
Ediff leaves be (`no-delete-other-windows').  The tree alone is kept:
another window showing it is Ediff's like any other, and loses the mark
and the dedication if it has them from earlier, so that Ediff's layout
takes it.  Nil when the option `harness-ui-patch-review-ediff-tree' is
off."
  (when harness-ui-patch-review-ediff-tree
    (let* ((buffer (harness-ui-patch-review--tree-buffer review))
           (window (or (harness-ui-patch-review--tree-window review)
                       (display-buffer-in-side-window
                        buffer `((side . left) (slot . -1)
                                 (window-width . ,(harness-ui-patch-review--tree-width))
                                 (preserve-size . (t . nil)))))))
      (when (window-live-p window)
        (dolist (other (get-buffer-window-list buffer nil (window-frame window)))
          (unless (eq other window)
            (set-window-parameter other 'no-delete-other-windows nil)
            (set-window-dedicated-p other nil)))
        (set-window-parameter window 'no-delete-other-windows t)
        (set-window-dedicated-p window t)
        (harness-ui-patch-review--draw-tree review)
        window))))

(defun harness-ui-patch-review--kill-tree (review)
  "Take the tree beside Ediff of REVIEW away: its window and its buffer."
  (let ((buffer (harness-ui-patch-review--r-tree-buffer review)))
    (setf (harness-ui-patch-review--r-tree-buffer review) nil)
    (when (buffer-live-p buffer)
      (dolist (window (get-buffer-window-list buffer nil t))
        (let ((ignore-window-parameters t))
          (ignore-errors (delete-window window))))
      (kill-buffer buffer))))

(defun harness-ui-patch-review-toggle-ediff-tree ()
  "Show the tree of the changed files beside Ediff, or hide it.
In the control panel of an Ediff of a task's change, or in either
version.  It is `harness-ui-patch-review-ediff-tree', for every Ediff."
  (interactive)
  (let ((review (harness-ui-patch-review--current)))
    (setq harness-ui-patch-review-ediff-tree (not harness-ui-patch-review-ediff-tree))
    (if harness-ui-patch-review-ediff-tree
        (harness-ui-patch-review--keep-tree review)
      (harness-ui-patch-review--kill-tree review))
    (harness-ui-patch-review--refresh-everywhere)
    (message "The files %s beside Ediff"
             (if harness-ui-patch-review-ediff-tree "show in a tree" "no longer show in a tree"))))

;;;; Ediff

(defun harness-ui-patch-review--incomparable (file)
  "Return why Ediff cannot compare FILE, or nil when it can."
  (let ((path (change-review-file-path file))
        (old (change-review-file-old-blob file))
        (new (change-review-file-new-blob file)))
    (cond ((harness-ui-patch-review--submodule-p file)
           (format "%s is a submodule: its commit went from %s to %s"
                   path (harness-ui-patch-review--short old) (harness-ui-patch-review--short new)))
          ((change-review-file-binary file) (format "%s is binary: Ediff compares text" path))
          ((and old (equal old new))
           (if (change-review-file-old-path file)
               (format "%s was renamed from %s, its content the same" path (change-review-file-old-path file))
             (format "%s only changed its mode, %s → %s" path
                     (change-review-file-old-mode file) (change-review-file-new-mode file)))))))

(defun harness-ui-patch-review--note-origin (review)
  "Note the buffer an Ediff of REVIEW is started from, when it is a banner.
That is where point goes back to when Ediff ends; from the report, the
tree beside Ediff or anywhere else it is the report.  Not while an Ediff
is under way: it began where it began."
  (unless (harness-ui-patch-review--r-ediff review)
    (setf (harness-ui-patch-review--r-origin review)
          (and (memq (current-buffer) (harness-ui-patch-review--r-banners review))
               (current-buffer)))))

(defun harness-ui-patch-review-ediff (&optional review index goto)
  "Compare the file of the row at point in Ediff, before the change and after.
For the default diff that is the merge base and the branch; the report
chooses another (\\[harness-ui-patch-review-select-diff]).
On the changes in a task's report, in its session's review banner and in
the tree beside Ediff.  In Ediff, c comments on the current difference,
into the report's box, N and P go on to the next or previous file, and q
comes back to where Ediff began.  REVIEW and INDEX name the file instead
of the row at point.  On the row of an earlier comment the version Ediff
shows has that comment's line in sight; GOTO, \(SIDE . LINE), names a
line the same way."
  (interactive)
  (pcase-let* ((`(,review . ,index) (if review (cons review index)
                                      (or (harness-ui-patch-review--at-point) (user-error "No file on this line"))))
               (file (or (nth index (harness-ui-patch-review--r-files review)) (user-error "No such file")))
               (why (harness-ui-patch-review--incomparable file)))
    (harness-ui-patch-review--note-origin review)
    (if (not why)
        (harness-ui-patch-review--compare review index goto)
      (harness-ui-patch-review--mark-seen review file)
      (harness-ui-patch-review--refresh review)
      (message "%s" why)
      nil)))

(defun harness-ui-patch-review-mouse-ediff (event)
  "Compare the file clicked on in EVENT in Ediff."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-patch-review-ediff))

(defun harness-ui-patch-review--compare (review index &optional goto)
  "Read the two versions of REVIEW's file at INDEX, then compare them in Ediff.
GOTO, (SIDE . LINE), is a line to have in sight in the version of SIDE.
Return a promise of the review."
  (let ((file (nth index (harness-ui-patch-review--r-files review))))
    (message "Reading %s…" (change-review-file-path file))
    (harness-then
     (harness-all (list (harness-ui-patch-review--blob review (change-review-file-old-blob file))
                        (harness-ui-patch-review--blob review (change-review-file-new-blob file))))
     (lambda (texts)
       ;; An error here, the frame refusing the layout say, reaches no one
       ;; but the log, as git's answer comes from a process: say it.
       (condition-case err
           (harness-ui-patch-review--start-ediff review index (nth 0 texts) (nth 1 texts) goto)
         (error
          (harness-log 'warn "patch review: could not start Ediff: %S" err)
          (message "Could not start Ediff for %s: %s"
                   (change-review-file-path file) (error-message-string err))
          (harness-ui-patch-review--kill-tree review)
          (unless (buffer-live-p (plist-get (harness-ui-patch-review--r-ediff review) :control))
            (setf (harness-ui-patch-review--r-ediff review) nil))))
       review)
     (lambda (err)
       (message "Could not read %s: %s" (change-review-file-path file) (harness-error-message err))
       nil))))

(defvar harness-ui-patch-review-lines-mode-map (make-sparse-keymap)
  "Keys in the two versions Ediff compares: c comments on the line at point.
C-c > starts a reply in a thread to the lines selected
\(`harness-ui-patch-review-thread-reply').  The others of the library's
threads under a line -- r, x, m, o, RET -- are its.")

;; Filled at top level, not in the `defvar', so that loading this file
;; again, as a reload does, gives the keymap an Emacs that runs on has the
;; keys the new version binds.
(let ((map harness-ui-patch-review-lines-mode-map))
  (set-keymap-parent map change-review-ui-lines-mode-map)
  (define-key map (kbd "c") #'harness-ui-patch-review-comment-line)
  (define-key map (kbd "C-c >") #'harness-ui-patch-review-thread-reply)
  (define-key map (kbd "a") #'harness-ui-patch-review-approve-ediff)
  (define-key map (kbd "e") #'harness-ui-patch-review-edit-comment)
  (define-key map (kbd "k") #'harness-ui-patch-review-delete-comment)
  (define-key map (kbd "K") #'harness-ui-patch-review-delete-thread)
  (define-key map (kbd "T") #'harness-ui-patch-review-threads)
  (define-key map (kbd "s") #'harness-ui-patch-review-toggle-skip-approved)
  (define-key map (kbd "u") #'harness-ui-patch-review-toggle-auto-approve)
  (define-key map (kbd "t") #'harness-ui-patch-review-toggle-ediff-tree))

(define-minor-mode harness-ui-patch-review-lines-mode
  "Keys to review one of the two versions Ediff compares.
\\<harness-ui-patch-review-lines-mode-map>
\\[harness-ui-patch-review-comment-line] comments on the line at point, as a thread of
its own.
\\[change-review-ui-reply] replies to the thread under it.
\\[harness-ui-patch-review-thread-reply] with lines selected starts a thread on them: a card in the
feedback box, the words under it the comment.
\\[change-review-ui-toggle-status] closes it or opens it again.
\\[change-review-ui-toggle-reviewed] marks it reviewed, when the agent closed it.
\\[change-review-ui-cycle-fold] folds it: one line, its conversation, all of it.
\\[change-review-ui-return] opens it if it is one line, else shows where its comments were made.
\\[change-review-ui-show-source] shows the code the comment under the line was written on, as it was then.
\\[harness-ui-patch-review-approve-ediff] approves the file.
\\[harness-ui-patch-review-edit-comment] edits a draft of yours there, or goes to the feedback box.
\\[harness-ui-patch-review-delete-comment] deletes a draft of yours there, \\[harness-ui-patch-review-delete-thread] a thread of drafts.
\\[harness-ui-patch-review-threads] goes to the threads, beside the files.
\\[harness-ui-patch-review-toggle-skip-approved] switches skipping the approved files,
\\[harness-ui-patch-review-toggle-auto-approve] approving the files you went through,
\\[harness-ui-patch-review-toggle-ediff-tree] the tree of the files beside Ediff.

The mouse selects text of the comments, which are no text of the buffer
\(`change-review-ui-mouse-select'): \\[change-review-ui-quote-reply] replies to a comment with
what is selected of it quoted, or, with nothing selected, with the last
comment of the thread under the line quoted."
  :lighter nil :keymap harness-ui-patch-review-lines-mode-map :group 'harness-ui-patch-review)

;;;;; The threads in the versions

(defun harness-ui-patch-review--decorate (review file buffer side placed)
  "Draw the threads about FILE of REVIEW in BUFFER, the version on SIDE.
SIDE is `old' or `new'.  Each thread shows under its line, drawn as the
library's views draw it, in the version it is placed in (the merge
base's for a comment on a removed line); a thread on the file as a
whole, or whose line is gone, at the top of the branch's version.
PLACED says where each thread is, an alist of its id to its place
\(`harness-ui-patch-review--place-from-texts'), for those the report has
not placed yet.  No line is wider than the window shows, and a thread is
no taller than it has room for (`change-review-ui-current-size'): the
window's size at this drawing is kept, for a window that changes it
\(`harness-ui-patch-review--side-resized').  A closed thread is a line,
which TAB or a click opens to its conversation, as the library's fold
says (`change-review-ui-thread-fold')."
  (with-current-buffer buffer
    (let* ((inhibit-read-only t)
           (set (harness-ui-patch-review--r-set review))
           (size (change-review-ui-current-size))
           (width (car size)))
      (setq harness-ui-patch-review--drawn-size size)
      (change-review-ui-clear-overlays)
      (save-excursion
        (dolist (thread (harness-ui-patch-review--file-threads review file))
          (let* ((location (change-review-thread-location thread))
                 (placement (or (gethash (change-review-thread-id thread)
                                         (harness-ui-patch-review--r-placements review))
                                (cdr (assoc (change-review-thread-id thread) placed))
                                (change-review-placement set thread)))
                 (line (and (change-review-location-line location) (plist-get placement :line)))
                 (on (or (plist-get placement :side) (change-review-location-side location) 'new))
                 (args (list :view 'diff :placement placement :width width :indent "  "
                             :details change-review-ui--details
                             :fold (change-review-ui-thread-fold set thread)
                             :max-lines (cdr size))))
            (cond
             ((and line (eq on side))
              (goto-char (point-min))
              (forward-line (1- line))
              (apply #'change-review-ui-add-thread-overlay set thread (line-end-position) args))
             ((and (eq side 'new) (null line))
              (apply #'change-review-ui-add-thread-overlay set thread (point-min) :before t args)))))))))

(defun harness-ui-patch-review--show-line (review goto)
  "Put the Ediff of REVIEW at GOTO, (SIDE . LINE): that line in sight there."
  (pcase-let* ((state (harness-ui-patch-review--r-ediff review))
               (`(,side . ,line) goto)
               (buffer (plist-get state (if (eq side :old) :a :b)))
               (window (and (buffer-live-p buffer) (get-buffer-window buffer))))
    (when (and window (integerp line) (> line 0))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line (1- line))
        (set-window-point window (point)))
      (with-selected-window window (recenter)))))

(defun harness-ui-patch-review--commit-name (name commit)
  "Return COMMIT, shortened, after NAME, what it was asked for as.
Just the short COMMIT when NAME is the start of it."
  (let ((short (harness-ui-patch-review--short commit)))
    (if (or (not (stringp name)) (string-empty-p name)
            (and (stringp commit) (string-prefix-p name commit)))
        short
      (format "%s %s" name short))))

(defun harness-ui-patch-review--side-name (review side)
  "Return what REVIEW's Ediff calls a file's version on SIDE, `old' or `new'.
It is the commit the version is read at, with the name the diff shown
has for it: the merge base for the default diff, the version for the
diff since the last review, the revision typed for another."
  (if (eq side 'old)
      (if (eq (harness-ui-patch-review--kind review) 'base)
          (format "merge base %s" (harness-ui-patch-review--short (harness-ui-patch-review--r-merge-base review)))
        (harness-ui-patch-review--commit-name (harness-ui-patch-review--old-name review)
                                              (harness-ui-patch-review--r-merge-base review)))
    (harness-ui-patch-review--commit-name
     (let ((name (harness-ui-patch-review--new-name review)))
       (and (stringp name) (harness-truncate-end name 40)))
     (harness-ui-patch-review--r-tip review))))

(defun harness-ui-patch-review--old-phrase (review)
  "Return what to call the old version of a file in REVIEW's Ediff in a sentence.
\"the merge base\" for the default diff; for another the name it has."
  (if (eq (harness-ui-patch-review--kind review) 'base)
      "the merge base"
    (or (harness-ui-patch-review--old-name review) "the version before")))

(defun harness-ui-patch-review--redraw-side (buffer)
  "Draw the threads of the version BUFFER again, when its window's room changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (functionp change-review-ui--redraw-function)
                 (not (equal harness-ui-patch-review--drawn-size (change-review-ui-current-size))))
        (funcall change-review-ui--redraw-function)))))

(defun harness-ui-patch-review--side-resized (&optional _window)
  "Draw the threads of this version again soon, if its window has another room.
On `window-size-change-functions', buffer-locally in a version Ediff
compares: the window is new, or changed its size.  Redisplay runs it, so
all it does is set a timer, which finds out whether the room changed
\(`harness-ui-patch-review--redraw-side') once the size has settled."
  (harness-debounce (list 'harness-ui-patch-review-side (current-buffer)) 0.1
                    #'harness-ui-patch-review--redraw-side (current-buffer)))

(defun harness-ui-patch-review--redraw-sides (review)
  "Draw the threads in the two versions of REVIEW's Ediff to their room, now."
  (let ((ediff (harness-ui-patch-review--r-ediff review)))
    (dolist (buffer (list (plist-get ediff :a) (plist-get ediff :b)))
      (harness-ui-patch-review--redraw-side buffer))))

(defun harness-ui-patch-review--side-buffer (review file side text &optional placed)
  "Return a buffer of TEXT, FILE's version on SIDE, `old' or `new', for Ediff.
REVIEW names it after the commit it is from.  It is in the major mode
of FILE, without the mode's hooks: a language server, say, has no
business there.  It is read-only, and its own keys comment on a line.
It has REVIEW and its file's index, for the keys, and under the lines
the threads about the file are on, those threads (PLACED says where
they are, as `harness-ui-patch-review--place-from-texts' gives it)."
  (let* ((old (eq side 'old))
         (path (if old (or (change-review-file-old-path file) (change-review-file-path file))
                 (change-review-file-path file)))
         (buffer (generate-new-buffer
                  (format "%s (%s)" path (harness-ui-patch-review--side-name review side)))))
    (with-current-buffer buffer
      (insert text)
      (let ((buffer-file-name (expand-file-name path (harness-ui-patch-review--r-dir review))))
        (condition-case err
            (delay-mode-hooks (set-auto-mode))
          (error (harness-log 'warn "patch review: no mode for %s: %S" path err))))
      (ignore-errors (font-lock-mode 1))
      (setq-local harness-ui-patch-review--review review
                  harness-ui-patch-review--index
                  (cl-position file (harness-ui-patch-review--r-files review) :test #'eq)
                  change-review-ui--set (harness-ui-patch-review--r-set review)
                  ;; The links of a comment to files are the branch's.
                  default-directory (harness-ui-patch-review--link-directory review)
                  ;; The threads draw again when the set changes.
                  change-review-ui--redraw-function
                  (lambda () (harness-ui-patch-review--decorate review file buffer side nil)))
      ;; The threads are drawn to the room the window has: when it gets
      ;; another -- Ediff lays the frame out, a split is toggled, the box
      ;; grows -- they are drawn again.
      (add-hook 'window-size-change-functions #'harness-ui-patch-review--side-resized nil t)
      (harness-ui-patch-review-lines-mode 1)
      (harness-ui-patch-review--decorate review file buffer side placed)
      (set-buffer-modified-p nil)
      (setq buffer-read-only t)
      (goto-char (point-min)))
    buffer))

(defun harness-ui-patch-review--help-button (label command key)
  "Return LABEL followed by KEY, a button running COMMAND, for Ediff's panel."
  (concat (propertize label 'face 'button 'mouse-face 'highlight
                      'help-echo (format "%s (%s)" label key)
                      'keymap (harness-ui-mouse-keymap command))
          " " (harness-ui-kbd key)))

(defun harness-ui-patch-review--ediff-progress ()
  "Return where this comparison is, as a prefix for the brief help.
It is \"File i of M · N viewed · \", or an empty string when the
panel does not know its review yet: Ediff composes the brief help while
setting the panel up, before the review's own keys and file are
installed, so `harness-ui-patch-review--ediff-redraw-help' draws it
again once they are."
  (let* ((review harness-ui-patch-review--review)
         (index harness-ui-patch-review--index)
         (files (and review (harness-ui-patch-review--r-files review))))
    (if (or (null files) (not (integerp index)) (< index 0) (>= index (length files)))
        ""
      (let ((threads (length (harness-ui-patch-review--file-threads review (nth index files))))
            (approved (cl-count-if (lambda (file) (harness-ui-patch-review--approved-p review file)) files)))
        (format "File %d of %d · %s%s"
                (1+ index) (length files)
                (if (harness-ui-patch-review--r-snapshot review)
                    ;; Not the branch as it is: not reviewed here either.
                    (format "as it was at %s · " (harness-ui-patch-review--short (harness-ui-patch-review--r-tip review)))
                  (format "%d viewed · %s"
                          (cl-count-if (lambda (file) (harness-ui-patch-review--seen-p review file)) files)
                          (if (> approved 0) (format "%d approved · " approved) "")))
                (if (> threads 0)
                    (format "%s · " (harness-ui-patch-review--plural threads "thread"))
                  ""))))))

(defun harness-ui-patch-review--ediff-redraw-help ()
  "Draw this Ediff control panel's brief help again, with its place in the files.
Ediff composes it once while setting the panel up, before
`harness-ui-patch-review--ediff-startup' has installed the review and
its file, so on its own the panel would not say where the reviewer is."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ediff-set-help-message)
    (insert ediff-help-message)
    (unless (ediff-multiframe-setup-p) (ediff-indent-help-message))
    (ediff-set-help-overlays)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (skip-chars-forward ediff-whitespace)
    (harness-ui-patch-review--fit-control)))

(defun harness-ui-patch-review--fit-control ()
  "Give this Ediff control panel the height its help takes, when it shows.
Ediff sizes the panel once, to the help it composes before the review's
own keys and file are installed; the help drawn again is longer, with
where the reviewer is and the settings that can be switched, and would
be cut off at the bottom of the window."
  (when-let* ((window (get-buffer-window (current-buffer))))
    (let ((window-resize-pixelwise t)
          (window-min-height 2))
      (ignore-errors
        (fit-window-to-buffer
         window (ceiling (/ (window-total-height (frame-root-window)) 2.0)) 2)))))

(defun harness-ui-patch-review--pack (groups width)
  "Join GROUPS of buttons into lines of WIDTH columns at most.
GROUPS is a list of lists of strings.  As many groups go on a line as
fit, three spaces apart, so that a line is cut between groups; a group
too wide for a line of its own is cut between its buttons, never through
one."
  (let (lines line)
    (cl-flet ((add (piece)
                (if (and line (> (+ (string-width line) 3 (string-width piece)) (- width 2)))
                    (progn (push line lines) (setq line piece))
                  (setq line (if line (concat line "   " piece) piece)))))
      (dolist (group groups)
        (let ((joined (mapconcat #'identity group "   ")))
          (if (<= (string-width joined) (- width 2))
              (add joined)
            (mapc #'add group)))))
    (when line (push line lines))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun harness-ui-patch-review--setting-button (label on command key)
  "Return the button of a setting for Ediff's panel: LABEL, with a check when ON.
It runs COMMAND, which switches the setting, KEY being its key."
  (harness-ui-patch-review--help-button (format "[%s %s]" (if on "✓" "✗") label) command key))

(defun harness-ui-patch-review--ediff-help ()
  "Return the brief help of the Ediff control panel of a review.
It opens with where the reviewer is: which file of how many, and how
many were compared already (`harness-ui-patch-review--ediff-progress').
Then the buttons for what the file allows, for going on, and for the
settings that can be switched here: skipping the files already approved,
approving those gone through without a comment, the tree beside Ediff."
  (let* ((here (list (concat (harness-ui-patch-review--ediff-progress)
                             (harness-ui-patch-review--help-button "[Comment]" #'harness-ui-patch-review-comment "c"))
                     (harness-ui-patch-review--help-button "[Reply]" #'harness-ui-patch-review-reply "r")
                     (harness-ui-patch-review--help-button "[Threads]" #'harness-ui-patch-review-threads "T")
                     (harness-ui-patch-review--help-button "[Edit draft/box]" #'harness-ui-patch-review-edit-comment "e")
                     (harness-ui-patch-review--help-button "[Delete draft]" #'harness-ui-patch-review-delete-comment "k")
                     (harness-ui-patch-review--help-button "[Delete thread]" #'harness-ui-patch-review-delete-thread "K")
                     (harness-ui-patch-review--help-button "[Approve]" #'harness-ui-patch-review-approve-ediff "a")))
         (elsewhere (list (harness-ui-patch-review--help-button "[Fold thread]" #'harness-ui-patch-review-cycle-fold "TAB")
                          (harness-ui-patch-review--help-button "[Next file]" #'harness-ui-patch-review-ediff-next-file "N")
                          (harness-ui-patch-review--help-button "[Previous file]" #'harness-ui-patch-review-ediff-previous-file "P")
                          (harness-ui-patch-review--help-button "[Back to the report]" #'harness-ui-patch-review-ediff-quit "q")
                          (propertize "? Ediff's keys" 'face 'harness-dim-face)))
         (settings (list (harness-ui-patch-review--setting-button
                          "Skip approved" harness-ui-patch-review-skip-approved
                          #'harness-ui-patch-review-toggle-skip-approved "s")
                         (harness-ui-patch-review--setting-button
                          "Auto-approve" harness-ui-patch-review-auto-approve
                          #'harness-ui-patch-review-toggle-auto-approve "u")
                         (harness-ui-patch-review--setting-button
                          "Files" harness-ui-patch-review-ediff-tree
                          #'harness-ui-patch-review-toggle-ediff-tree "t")))
         (window (get-buffer-window (current-buffer)))
         (width (if window (window-width window) (frame-width))))
    ;; In one line when the panel is wide enough, else in as many as it
    ;; takes, cut between groups of buttons rather than through one.
    (harness-ui-patch-review--pack (list here elsewhere settings) width)))

(defun harness-ui-patch-review--main-window ()
  "Return the window Ediff goes in: the selected one, when it may be.
Not a side window, a dedicated one or the minibuffer's: then the largest
window that is none of those, else the frame's first."
  (let* ((usable (lambda (window)
                   (not (or (window-minibuffer-p window)
                            (window-parameter window 'window-side)
                            (window-dedicated-p window)))))
         (windows (cl-remove-if-not usable (window-list nil 'nomini))))
    (cond ((funcall usable (selected-window)) (selected-window))
          (windows (car (sort windows (lambda (a b) (> (* (window-total-width a) (window-total-height a))
                                                       (* (window-total-width b) (window-total-height b)))))))
          (t (frame-first-window)))))

(defun harness-ui-patch-review--start-ediff (review index old new &optional goto)
  "Compare OLD and NEW, the texts of REVIEW's file at INDEX, in Ediff.
From the report, Ediff takes its frame, whose windows are kept to give
back when it ends.  From an Ediff of the review -- N and P -- it takes
that one's place, with the same windows to give back.  The earlier
threads about the file show in its versions, placed by these texts.  With
GOTO, (SIDE . LINE), that line is in sight in the version of SIDE."
  (require 'ediff)
  (let* ((file (nth index (harness-ui-patch-review--r-files review)))
         (placed (harness-ui-patch-review--place-from-texts review file old new))
         (before (harness-ui-patch-review--r-ediff review))
         (going (buffer-live-p (plist-get before :control)))
         (windows (and going (plist-get before :windows)))
         (start (and going (plist-get before :start)))
         (made (and going (plist-get before :made-popout))))
    (if going
        (progn
          ;; In its frame: this runs once git has answered, when another
          ;; frame may be the selected one.
          (when-let* ((window (get-buffer-window (plist-get before :control) t)))
            (select-window window))
          (harness-ui-patch-review--end-ediff review t))
      ;; The box beside Ediff is the report's: from the review banner of
      ;; the task's session the report is not open yet.
      (setq made (harness-ui-patch-review--ensure-box review))
      ;; In any frame: this runs once git has answered, when the frame
      ;; selected need not be the report's.
      (let* ((popout (harness-ui-patch-review--r-popout review))
             (report (and (buffer-live-p popout)
                          (or (harness-ui-patch-review--box-window popout t)
                              (get-buffer-window popout t))))
             ;; Else the window of the review banner Ediff was started from.
             (window (or report
                         (let ((origin (harness-ui-patch-review--r-origin review)))
                           (and (buffer-live-p origin) (get-buffer-window origin t))))))
        (when window
          (select-window window)
          (when report
            (setq start (with-current-buffer popout (line-number-at-pos (window-start window))))))))
    (let* ((windows (or windows (current-window-configuration)))
           (main (harness-ui-patch-review--main-window))
           ;; The report's window stays for its feedback box, smaller.
           (box (harness-ui-patch-review--keep-box review))
           ;; The files stay in a tree on the left.
           (tree (harness-ui-patch-review--keep-tree review)))
      (select-window main)
      ;; The other side windows go too: Ediff lays the frame out its own
      ;; way, and q gives it back as it was.
      (condition-case nil
          (let ((ignore-window-parameters (not (or box tree))))
            (delete-other-windows main))
        (error (let ((ignore-window-parameters t))
                 (delete-other-windows main))))
      (set-window-dedicated-p main nil)
      ;; The versions show the places the report does, once it has read how
      ;; the files changed (`harness-ui-patch-review--decorate'); until
      ;; then, those the texts at hand tell.
      (let ((a (harness-ui-patch-review--side-buffer review file 'old old placed))
            (b (harness-ui-patch-review--side-buffer review file 'new new placed)))
        (setf (harness-ui-patch-review--r-ediff review)
              (list :index index :a a :b b :windows windows :start start :box box
                    :made-popout made))
        ;; The tree marks the file under comparison.
        (harness-ui-patch-review--draw-tree review)
        (condition-case err
            (progn
              (let ((ediff-window-setup-function (or harness-ui-patch-review-ediff-window-setup
                                                     ediff-window-setup-function))
                    (ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help))
                (ediff-buffers a b (list (lambda () (harness-ui-patch-review--ediff-startup review index)))))
              ;; Ediff laid the rest of the frame out: its panel has the room its
              ;; help takes, the threads are drawn to the windows they are in, and
              ;; the box ends the report in its window.
              (when-let* ((control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
                (with-current-buffer control (harness-ui-patch-review--fit-control)))
              (harness-ui-patch-review--redraw-sides review)
              (harness-ui-patch-review--scroll-box box)
              (when goto (harness-ui-patch-review--show-line review goto)))
          (error
           (harness-ui-patch-review--ediff-ended review index)
           (message "Ediff could not compare %s: %s"
                    (change-review-file-path file) (error-message-string err))))))))

(defun harness-ui-patch-review--ediff-startup (review index)
  "Make this Ediff control panel compare REVIEW's file at INDEX.
It gets the review's keys and help, and gives the report back as it ends."
  (setq harness-ui-patch-review--review review
        harness-ui-patch-review--index index)
  (setq-local ediff-brief-help-message-function #'harness-ui-patch-review--ediff-help)
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map ediff-mode-map)
    (define-key map "c" #'harness-ui-patch-review-comment)
    (define-key map "r" #'harness-ui-patch-review-reply)
    (define-key map (kbd "C-c >") #'harness-ui-patch-review-quote-reply)
    (define-key map "x" #'harness-ui-patch-review-toggle-thread)
    ;; Instead of Ediff's wide display, which a review has no use for.
    (define-key map "m" #'harness-ui-patch-review-toggle-reviewed)
    (define-key map "T" #'harness-ui-patch-review-threads)
    (define-key map (kbd "TAB") #'harness-ui-patch-review-cycle-fold)
    (define-key map "e" #'harness-ui-patch-review-edit-comment)
    (define-key map "k" #'harness-ui-patch-review-delete-comment)
    (define-key map "K" #'harness-ui-patch-review-delete-thread)
    (define-key map "a" #'harness-ui-patch-review-approve-ediff)
    (define-key map "s" #'harness-ui-patch-review-toggle-skip-approved)
    (define-key map "u" #'harness-ui-patch-review-toggle-auto-approve)
    (define-key map "t" #'harness-ui-patch-review-toggle-ediff-tree)
    (define-key map "n" #'harness-ui-patch-review-next-difference)
    (define-key map "]" #'harness-ui-patch-review-next-difference)
    (define-key map "N" #'harness-ui-patch-review-ediff-next-file)
    (define-key map "P" #'harness-ui-patch-review-ediff-previous-file)
    (define-key map "q" #'harness-ui-patch-review-ediff-quit)
    ;; The panel's map, for whatever adds to it after: evil's keys, say.
    (setq-local ediff-mode-map map)
    (use-local-map map)
    ;; Evil put the panel's map before its states' (evil-collection makes
    ;; it overriding); the map that inherits from it takes its place.
    (when (and (bound-and-true-p evil-local-mode) (fboundp 'evil-normalize-keymaps))
      (evil-normalize-keymaps)))
  (setf (harness-ui-patch-review--r-ediff review)
        (plist-put (harness-ui-patch-review--r-ediff review) :control (current-buffer)))
  (add-hook 'ediff-after-quit-hook-internal
            (lambda () (harness-ui-patch-review--ediff-ended review index))
            nil t)
  ;; Whether the reviewer went through the file: they were at its last difference.
  (add-hook 'ediff-select-hook #'harness-ui-patch-review--note-difference nil t)
  (if (> ediff-number-of-differences 0)
      (ediff-next-difference)
    ;; Nothing to go through.
    (harness-ui-patch-review--note-reached review))
  ;; Ediff drew the brief help while setting the panel up, before the
  ;; review's own keys and file were installed: draw it again, so it opens
  ;; with where in the files the reviewer is.
  (harness-ui-patch-review--ediff-redraw-help))

(defun harness-ui-patch-review--restore-windows (windows)
  "Give the frame of WINDOWS, a window configuration, its windows back.
A window whose buffer was killed meanwhile -- the report's, when the
task was decided -- is not given back: Emacs 31 lets the restoring say
so (`window-restore-killed-buffer-windows'), an older one shows another
buffer there.  Nothing happens when the frame went."
  (let ((window-restore-killed-buffer-windows
         (lambda (_frame entries _kind)
           (dolist (entry entries)
             (when (window-live-p (car entry))
               ;; A side window too: the report's is one.
               (let ((ignore-window-parameters t))
                 (ignore-errors (delete-window (car entry)))))))))
    (ignore-errors (set-window-configuration windows))))

(defun harness-ui-patch-review--note-reached (review)
  "Note that the reviewer of REVIEW went through the file under comparison."
  (setf (harness-ui-patch-review--r-ediff review)
        (plist-put (harness-ui-patch-review--r-ediff review) :reached t)))

(defun harness-ui-patch-review--note-difference ()
  "Note that the reviewer is at the last difference of this Ediff, once they are.
On `ediff-select-hook', in the control panel of a review's Ediff: the
file counts as gone through, for approving it as the reviewer leaves it
\(`harness-ui-patch-review--auto-approve')."
  (when (and harness-ui-patch-review--review
             (integerp ediff-current-difference)
             (>= ediff-current-difference (1- ediff-number-of-differences)))
    (harness-ui-patch-review--note-reached harness-ui-patch-review--review)))

(defun harness-ui-patch-review--ensure-box (review)
  "Open the report of REVIEW's task out of sight, when it is not open.
The feedback box beside Ediff is the report's.  From the review banner of
the task's session there is no report open yet; none to open for a task
that is not in review, which has no box.  Return non-nil when it opened
the report, which closes as the Ediff ends."
  (when (and harness-ui-patch-review-ediff-box-height
             (not (buffer-live-p (harness-ui-patch-review--r-popout review)))
             (harness-ui-patch-review--reviewing-p (harness-ui-patch-review--r-task review)))
    (let ((harness-ui-patch-review--opening-box t))
      (ignore-errors (harness-ui-patch-review--feedback-box review)))
    ;; Made here: it closes as the Ediff ends, what was typed in its box kept.
    (buffer-live-p (harness-ui-patch-review--r-popout review))))

(defun harness-ui-patch-review--ediff-ended (review index)
  "Tidy up after the Ediff of REVIEW's file at INDEX.
Its two versions go and the file is seen, approved too when the reviewer
went through it and has no comment on it, a reply waiting in the report's
box included, unless they took its approval off meanwhile
\(`harness-ui-patch-review--auto-approve').  Unless another
comparison takes its place, the frame gets its windows back, the report
among them, drawn again, with point on the next file to review."
  (let* ((state (harness-ui-patch-review--r-ediff review))
         (files (harness-ui-patch-review--r-files review))
         (file (nth index files)))
    (setf (harness-ui-patch-review--r-ediff review) nil)
    (dolist (buffer (list (plist-get state :a) (plist-get state :b)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (harness-ui-patch-review--mark-seen review file)
    (harness-ui-patch-review--auto-approve review file (plist-get state :reached)
                                           (plist-get state :unapproved))
    (unless (plist-get state :quiet)
      (when-let* ((windows (plist-get state :windows)))
        (harness-ui-patch-review--restore-windows windows))
      (harness-ui-patch-review--kill-tree review)
      ;; The report has the height it had again, and its windows are free; one
      ;; opened for the box alone closes, what was typed in it kept.
      (harness-ui-patch-review--unlimit-box (harness-ui-patch-review--r-popout review))
      (when (plist-get state :made-popout)
        (harness-ui-popout-close (list 'report (harness-ui-patch-review--r-id review))))
      (cond
       ((harness-ui-patch-review--r-gone review)
        (harness-ui-patch-review--forget review))
       ;; The files of an earlier commit are no rows of the report.
       ((harness-ui-patch-review--r-snapshot review))
       (t
        (harness-ui-patch-review--refresh review t)
        (harness-ui-patch-review--goto-row review (harness-ui-patch-review--landing review index)
                                           (plist-get state :start))
        (setf (harness-ui-patch-review--r-origin review) nil))))))

(defun harness-ui-patch-review--really-quit ()
  "Quit the Ediff of this control panel without a question.
Its two versions are the review's, which kills them itself."
  (let ((this-command 'ediff-quit)
        (ediff-keep-variants t))
    (ediff-really-quit nil)))

(defun harness-ui-patch-review--end-ediff (review &optional quiet)
  "End the Ediff of REVIEW under way, if there is one.
The frame gets back the windows it had before, unless QUIET: then the
windows stay as they are, for another comparison to take, or because
Ediff is out of sight."
  (let ((control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (when (buffer-live-p control)
      (setf (harness-ui-patch-review--r-ediff review)
            (plist-put (harness-ui-patch-review--r-ediff review) :quiet quiet))
      (let ((quit (lambda () (with-current-buffer control (harness-ui-patch-review--really-quit)))))
        (if quiet
            ;; Ediff shows its two versions again as it quits.
            (save-window-excursion (funcall quit))
          (funcall quit))))))

(defun harness-ui-patch-review--comparable (review index step)
  "Return the index of the file Ediff compares STEP files on from INDEX.
Among REVIEW's files, in the order they show, but for those Ediff cannot
compare and the approved ones while `harness-ui-patch-review-skip-approved'
is on; nil when there is none that way."
  (let ((files (harness-ui-patch-review--r-files review)))
    (harness-ui-patch-review--neighbor
     review index step
     (lambda (candidate) (not (harness-ui-patch-review--incomparable (nth candidate files)))))))

(defun harness-ui-patch-review-next-difference (&optional arg)
  "Move to the next difference in this Ediff, ARG times.
At the last difference it first says the next difference is the next
file, and how many approved files that skips while
`harness-ui-patch-review-skip-approved' is on; pressing n again goes on to
it, in Ediff.  So the reviewer need not know before the last difference
that another file follows."
  (interactive "p")
  (let ((last (1- ediff-number-of-differences)))
    (cond
     ((<= ediff-number-of-differences 0)
      (harness-ui-patch-review-ediff-next-file))
     ((and harness-ui-patch-review--next-file-offer
           (eq last-command this-command))
      (setq harness-ui-patch-review--next-file-offer nil)
      (harness-ui-patch-review-ediff-next-file))
     ((>= ediff-current-difference last)
      (let* ((review (harness-ui-patch-review--current))
             (target (harness-ui-patch-review--comparable review harness-ui-patch-review--index 1)))
        (if target
            (progn (setq harness-ui-patch-review--next-file-offer t)
                   (message "Last difference; n again goes to the next file%s"
                            (harness-ui-patch-review--skipping-text review harness-ui-patch-review--index target)))
          (setq harness-ui-patch-review--next-file-offer nil)
          (message "Last difference of the last file to review; q goes back to the report"))))
     (t
      (setq harness-ui-patch-review--next-file-offer nil)
      (ediff-next-difference arg)))))

(defun harness-ui-patch-review--skipped-count (review from to)
  "Return how many approved files going from FROM to TO skips.
FROM and TO are indices of REVIEW's files.  Nothing is skipped, so 0,
while `harness-ui-patch-review-skip-approved' is off."
  (if harness-ui-patch-review-skip-approved
      (harness-ui-patch-review--between review from to)
    0))

(defun harness-ui-patch-review--skipping-text (review from to)
  "Return \", skipping 2 approved files\" for going from FROM to TO, or \"\" for none.
FROM and TO are indices of REVIEW's files.  It ends the sentence that says
where the next n goes, so the reviewer sees the approved files are stepped
over before they are."
  (let ((skipped (harness-ui-patch-review--skipped-count review from to)))
    (if (> skipped 0)
        (format ", skipping %s" (harness-ui-patch-review--plural skipped "approved file"))
      "")))

(defun harness-ui-patch-review--ediff-step (step)
  "Compare the file STEP files on in Ediff, in place of this one.
The next file to review: one that is not approved while
`harness-ui-patch-review-skip-approved' is on.  The approved files stepped
over are said once the next file is up: Ediff's own messages, and
\"Reading…\", would cover it before."
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (target (harness-ui-patch-review--comparable review index step)))
    (cond
     (target
      (let ((skipped (harness-ui-patch-review--skipped-count review index target))
            (shown (harness-ui-patch-review--compare review target)))
        (when (> skipped 0)
          (harness-then shown
                        (lambda (_)
                          (when (eql target (plist-get (harness-ui-patch-review--r-ediff review) :index))
                            (message "Skipped %s already approved; s stops skipping them"
                                     (harness-ui-patch-review--plural skipped "file"))))))
        shown))
     ((> (harness-ui-patch-review--remaining review index step) 0)
      (message "No file left to review that way, the %s after this one approved; q goes back to the report"
               (if (> step 0) "ones" "ones before")))
     (t (message "That is the %s file; q goes back to the report" (if (> step 0) "last" "first"))))))

(defun harness-ui-patch-review-ediff-quit ()
  "Back to the task's report, the windows as they were, without asking.
From the control panel of the Ediff, either version, or the tree beside it."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (control (plist-get (harness-ui-patch-review--r-ediff review) :control)))
    (unless (buffer-live-p control) (user-error "No Ediff under way"))
    (with-current-buffer control (harness-ui-patch-review--really-quit))))

(defun harness-ui-patch-review-ediff-next-file ()
  "On to the next file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--ediff-step 1))

(defun harness-ui-patch-review-ediff-previous-file ()
  "On to the previous file of the task's changes, in Ediff."
  (interactive)
  (harness-ui-patch-review--ediff-step -1))

(defun harness-ui-patch-review--ediff-position ()
  "Return (SIDE . LINE) for the current difference of this Ediff, or nil.
LINE is the difference's last line: on the branch, SIDE :new, unless
the difference only deletes, then in the version before it (the merge
base's, by default), SIDE :old."
  (let ((n ediff-current-difference))
    (when (and (integerp n) (>= n 0) (< n ediff-number-of-differences))
      (let ((b-start (ediff-get-diff-posn 'B 'beg n))
            (b-end (ediff-get-diff-posn 'B 'end n)))
        (if (< b-start b-end)
            (cons :new (with-current-buffer ediff-buffer-B (line-number-at-pos (1- b-end) t)))
          (let ((a-end (ediff-get-diff-posn 'A 'end n)))
            (cons :old (with-current-buffer ediff-buffer-A
                         (line-number-at-pos (max (point-min) (1- a-end)) t)))))))))

(defun harness-ui-patch-review--comment-prompt ()
  "Return the prompt for a comment on the current difference of this Ediff."
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
         (where (harness-ui-patch-review--ediff-position)))
    (format "Comment on %s%s:" (change-review-file-path file)
            (pcase where
              ('nil " as a whole")
              (`(:new . ,line) (format ", line %d" line))
              (`(:old . ,line) (format ", line %d of %s" line (harness-ui-patch-review--old-phrase review)))))))

(defun harness-ui-patch-review-comment (&optional text)
  "Comment on the current difference with TEXT.
In the Ediff of a task's change.  Called from the panel it reads the
comment in a buffer of its own, so it may run to several lines: C-c C-c
comments, C-c C-k gives up (`string-edit').  The comment starts a
thread, under the difference's last line -- the branch's, or the merge
base's for a difference that only deletes -- a draft that goes with the
feedback.  Without a current difference it is a comment on the file as
a whole."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (file (nth harness-ui-patch-review--index (harness-ui-patch-review--r-files review)))
         (where (harness-ui-patch-review--ediff-position)))
    (if text
        (harness-ui-patch-review--comment-added review file where text)
      (harness-ui-patch-review--read-comment
       (harness-ui-patch-review--comment-prompt)
       (lambda (written)
         (harness-ui-patch-review--comment-added review file where written))))))

(defun harness-ui-patch-review--read-comment (prompt callback)
  "Read a comment with PROMPT, then call CALLBACK with what was written.
It is read in a buffer of its own, so it may run to several lines:
C-c C-c saves it as a draft, C-c C-k gives up (`string-edit')."
  (change-review-ui-read prompt "" callback))

(defun harness-ui-patch-review-comment-line (&optional text)
  "Comment on the line at point in the version Ediff shows.
In either version of a file compared in Ediff: the branch's line gets a
comment under it quoted from the diff, the merge base's too.  With TEXT
it is the comment; called from the buffer it reads the comment in one of
its own, which may run to several lines."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (file (or (and (integerp index)
                        (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (state (harness-ui-patch-review--r-ediff review))
         (side (if (eq (current-buffer) (plist-get state :a)) :old :new))
         (line (line-number-at-pos))
         (where (cons side line)))
    (if text
        (harness-ui-patch-review--comment-added review file where text)
      (harness-ui-patch-review--read-comment
       (format "Comment on %s, line %d%s: "
               (change-review-file-path file) line
               (if (eq side :old) (format " of %s" (harness-ui-patch-review--old-phrase review)) ""))
       (lambda (written)
         (harness-ui-patch-review--comment-added review file where written))))))

(defun harness-ui-patch-review-approve-ediff ()
  "Approve the file compared in this Ediff, or stop approving it.
It need not be reviewed again unless the branch changes it.  A file you
stop approving stays so as you leave Ediff, whatever auto-approve says."
  (interactive)
  (let* ((review (harness-ui-patch-review--current))
         (index harness-ui-patch-review--index)
         (file (or (and (integerp index)
                        (nth index (harness-ui-patch-review--r-files review)))
                   (user-error "No file here")))
         (approved (not (harness-ui-patch-review--approved-p review file))))
    (when (harness-ui-patch-review--r-snapshot review)
      (user-error "This is the file as it was at %s; approve it in the branch as it is"
                  (harness-ui-patch-review--short (harness-ui-patch-review--r-tip review))))
    (harness-ui-patch-review--approve review file approved)
    (harness-ui-patch-review--refresh-approvals review)
    (message "%s %s" (if approved "Approved" "No longer approved")
             (change-review-file-path file))))

(defun harness-ui-patch-review--location (file where)
  "Return the location of a comment on WHERE of FILE.
WHERE is (SIDE . LINE), SIDE `:new' for a line of the branch's version
and `:old' for one of the version before it, the merge base's by default;
nil for the file as a whole.
The location keeps the lines of the diff around it."
  (if where
      (change-review-diff-location file (car where) (cdr where))
    (change-review-make-location :file (change-review-file-path file)
                                 :old-file (change-review-file-old-path file)
                                 :patch (change-review-file-patch-id file))))

(defun harness-ui-patch-review--comment-added (review file where text)
  "Start a thread in REVIEW's set with TEXT, a comment on WHERE of FILE.
It is a draft: it goes with the feedback that sends the task back.  Say
so in the echo area.  A blank TEXT is no comment, and says so."
  (if (string-blank-p text)
      (message "No comment")
    (let ((location (harness-ui-patch-review--location file where)))
      ;; Written against the commit the diff -- the excerpt -- was read at.
      (change-review-comment (harness-ui-patch-review--r-set review) (string-trim text)
                             :location location :revision (harness-ui-patch-review--r-tip review))
      (message "Draft on %s: it goes with the feedback; T lists the threads, r replies"
               (change-review-location-label location t)))))

;;;; Following the tasks

(defun harness-ui-patch-review--ended (review)
  "REVIEW's task is done, or deleted: drop the review.
An Ediff of it on show stays until q gives the windows back."
  (if (harness-ui-patch-review--ediff-shows-p review)
      (setf (harness-ui-patch-review--r-gone review) t)
    (harness-ui-patch-review--forget review)))

(defun harness-ui-patch-review--surface-live-p (review)
  "Non-nil when a surface that shows REVIEW's changes is open.
The report, the review banner of the task's session, or the tree beside
Ediff."
  (or (buffer-live-p (harness-ui-patch-review--r-popout review))
      (cl-some #'buffer-live-p (harness-ui-patch-review--r-banners review))
      (buffer-live-p (harness-ui-patch-review--r-tree-buffer review))))

(defun harness-ui-patch-review--on-event (event args)
  "Follow the tasks whose changes are reviewed: EVENT about a task, with ARGS."
  (pcase event
    ((or "task/changed" "task/review")
     (when-let* ((task (car args))
                 (review (harness-ui-patch-review--known (plist-get task :id))))
       (let* ((before (harness-ui-patch-review--r-task review))
              (sent (and before (> (length (plist-get task :feedback))
                                   (length (plist-get before :feedback))))))
         (setf (harness-ui-patch-review--r-task review) task)
         (setf (change-review-set-title (harness-ui-patch-review--r-set review))
               (harness-ui-patch-review--title review))
         ;; The feedback went -- from the box beside Ediff, say: the review
         ;; is over, and the frame is the reviewer's again.
         (when sent
           ;; The Ediffs of earlier commits' code lie over the review's own.
           (dolist (snapshot (harness-ui-patch-review--snapshot-list review))
             (when (harness-ui-patch-review--r-ediff snapshot)
               (harness-ui-patch-review--end-ediff snapshot)))
           (when (harness-ui-patch-review--r-ediff review)
             (harness-ui-patch-review--end-ediff review))))
       ;; Back for review, maybe with more commits: the report open on it
       ;; reads the branch again, and the version the harness recorded.
       (when (and (equal event "task/review") (harness-ui-patch-review--surface-live-p review))
         (harness-ui-patch-review--sync-and-load review))))
    ("task/done"
     (when-let* ((review (harness-ui-patch-review--known (plist-get (car args) :id))))
       (harness-ui-patch-review--ended review)))
    ("task/deleted"
     (when-let* ((review (harness-ui-patch-review--known (car args))))
       (harness-ui-patch-review--ended review)))
    ;; What the harness did to the threads of a review: an agent's comment,
    ;; the drafts sent, or the user's own operation come back.
    ("patch-review/changed"
     (when-let* ((review (harness-ui-patch-review--known (car args)))
                 (op (cadr args)))
       (condition-case err
           (change-review-apply (harness-ui-patch-review--r-set review) op)
         (change-review-error
          (harness-log 'warn "patch review: could not perform %S: %s" op (error-message-string err))))))))

;;;; Opening the review from a session

(defun harness-ui-patch-review--task-here ()
  "Return the task this buffer shows, or nil.
That is the report popout's task, the session's task, or the task at
point of the board."
  (or (and (fboundp 'harness-ui-report-task)
           (harness-ui-report-task))
      (and (bound-and-true-p harness-ui-session-id)
           (fboundp 'harness-ui-review--task)
           (harness-ui-review--task harness-ui-session-id))
      (and (derived-mode-p 'harness-ui-tasks-mode)
           (fboundp 'harness-ui-tasks--task)
           (harness-ui-tasks--task t))))

(defun harness-ui-patch-review--open-task (task)
  "Show TASK's report, with its changes, in a popout."
  (unless (and task (plist-get task :id))
    (user-error "No task here to review"))
  (let ((review (harness-ui-patch-review--review-for task)))
    ;; A task no longer waiting for review -- done, or sent back and at
    ;; work -- is still the reviewer's to look at from its session's
    ;; history: the changes show, without the review banner.
    (unless (harness-ui-patch-review--reviewing-p task)
      (setf (harness-ui-patch-review--r-show review) t))
    (harness-ui-report-popout task)))

(defun harness-ui-patch-review--ediff-window (task)
  "Return the window of the Ediff of TASK's changes that shows, or nil.
An Ediff of the code as an earlier commit had it is one."
  (when-let* ((review (harness-ui-patch-review--known (plist-get task :id))))
    (cl-some (lambda (view)
               (let ((control (plist-get (harness-ui-patch-review--r-ediff view) :control)))
                 (and (buffer-live-p control) (get-buffer-window control t))))
             (cons review (harness-ui-patch-review--snapshot-list review)))))

(defun harness-ui-patch-review--choose-diff-for (task)
  "Ask which diff to open TASK's changes at, and keep the answer for its review.
The three the report offers and any revisions
\(`harness-ui-patch-review-select-diff'), asked before the report opens.
A report that is open already reads the diff chosen."
  (let* ((review (harness-ui-patch-review--review-for task))
         (selector (harness-ui-patch-review--selector-of
                    (harness-ui-patch-review--read-selector review))))
    (setf (harness-ui-patch-review--r-selector review) selector
          (harness-ui-patch-review--r-selection-error review) nil)
    (when (buffer-live-p (harness-ui-patch-review--r-popout review))
      (harness-ui-patch-review--load review))))

(defun harness-ui-patch-review-open (&optional choose)
  "Show the changes of the task this buffer shows, in a popout.
From its session's history, from its board card, or from its report:
works after the task left review too, for the task the session is the
task's.  A session's task not looked up yet is asked for, and its review
opens when it arrives.  In the report beside an Ediff of its changes
\(`harness-ui-patch-review-edit-feedback'), it goes back to Ediff.  With
a prefix argument CHOOSE, which diff to show is asked first: the task's
branch against main, since the last review, or revisions
\(`harness-ui-patch-review-select-diff'); the report keeps its choice."
  (interactive "P")
  (if-let* ((task (harness-ui-patch-review--task-here)))
      (if-let* ((window (harness-ui-patch-review--ediff-window task)))
          ;; An Ediff of it shows beside the report: back to it.
          (progn (select-window window)
                 (message "Back in Ediff"))
        (when choose (harness-ui-patch-review--choose-diff-for task))
        (harness-ui-patch-review--open-task task))
    (if (and (bound-and-true-p harness-ui-session-id)
             (fboundp 'harness-ui-review--task))
        (progn
          (harness-ui-call "_harness/task/for-session"
                           (list :session-id harness-ui-session-id)
                           (lambda (found)
                             (if (and found (plist-get found :id))
                                 (progn
                                   (when choose (harness-ui-patch-review--choose-diff-for found))
                                   (harness-ui-patch-review--open-task found))
                               (message "This session is no task's, so it has no changes to review"))))
          (message "Looking up this session's task…"))
      (user-error "No task here to review"))))

(defvar harness-ui-patch-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d") #'harness-ui-patch-review-open)
    map)
  "Keys that show a task's changes from its session or board.")

(define-minor-mode harness-ui-patch-review-mode
  "Keys to open the changes of the task this buffer shows.
\\<harness-ui-patch-review-mode-map>\\[harness-ui-patch-review-open] opens its report with the changes, in a popout, from
a task's session history or a board card, whether it waits for review
or has left it."
  :lighter nil :keymap harness-ui-patch-review-mode-map :group 'harness-ui-patch-review)

(put 'harness-ui-patch-review-mode 'harness-menu-group
     '("Changes"
       ["Review the changes"
        ("C-c C-d" "Review the changes" harness-ui-patch-review-open)]
       ["Settings"
        (". s" "Skip the files already approved" harness-ui-patch-review-toggle-skip-approved)
        (". u" "Approve the files gone through without a comment" harness-ui-patch-review-toggle-auto-approve)
        (". t" "Files as a tree or a flat list" harness-ui-patch-review-toggle-file-tree)]))

(defun harness-ui-patch-review--setup-chat ()
  "Offer the review's key in this chat buffer."
  (harness-ui-patch-review-mode 1))

(defun harness-ui-patch-review--setup-existing-buffers ()
  "Offer the review's key in chats and boards that are open already.
A chat whose task waits for review draws its banner again, with the
changes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-chat-mode 'harness-ui-tasks-mode)
        (harness-ui-patch-review-mode 1))
      (when (and (derived-mode-p 'harness-chat-mode)
                 (bound-and-true-p harness-ui-session-id)
                 (fboundp 'harness-ui-review--task)
                 (harness-ui-patch-review--reviewing-p
                  (harness-ui-review--task harness-ui-session-id))
                 (functionp harness-compose-redraw-function))
        (funcall harness-compose-redraw-function)))))

;;;; Showing a thread

(defun harness-ui-patch-review--thread-position (id)
  "Return where the thread ID starts in this buffer, or nil."
  (harness-ui-patch-review--find-property
   'change-review-thread id (harness-ui-patch-review--section-start)))

(defun harness-ui-patch-review--goto-thread (buffer id)
  "Put point on the thread ID drawn in BUFFER, in the windows showing it too.
Return non-nil when it is there.  A thread the filter of BUFFER hides
shows: the filter becomes all, which draws BUFFER again."
  (with-current-buffer buffer
    (let ((pos (harness-ui-patch-review--thread-position id)))
      (when (and (null pos) change-review-ui--redraw-function)
        (change-review-ui-set-filter 'all)
        (setq pos (harness-ui-patch-review--thread-position id)))
      (when pos
        (goto-char pos)
        (dolist (window (get-buffer-window-list buffer nil t))
          (set-window-point window pos)
          (with-selected-window window (recenter 1)))
        (pulse-momentary-highlight-one-line pos)
        t))))

(defun harness-ui-patch-review--report-shows-p (review)
  "Return non-nil when the report of REVIEW's task draws its changes.
That is what `harness-ui-patch-review--panel' decides: the task waits for
review, or its review was opened from its session's history; it has a
branch of its own, and the repository is a directory of this machine."
  (let ((task (harness-ui-patch-review--r-task review)))
    (and (or (harness-ui-patch-review--reviewing-p task)
             (harness-ui-patch-review--r-show review))
         (not (harness-string-blank-p (plist-get task :branch)))
         (harness-ui-patch-review--repository task)
         t)))

(defun harness-ui-patch-review--when-settled (review function &optional tries)
  "Call FUNCTION once REVIEW has read its branch and placed its threads.
A report opened afresh reads the branch again and draws once more when it
has, which would take point from where it was put, so FUNCTION waits for
that: ten seconds at the most, TRIES counting the checks made."
  (let ((tries (or tries 0)))
    (if (or (>= tries 50)
            (and (not (harness-ui-patch-review--r-loading review))
                 (not (harness-ui-patch-review--r-placing review))))
        (funcall function)
      (run-with-timer 0.2 nil #'harness-ui-patch-review--when-settled review function (1+ tries)))))

(defun harness-ui-patch-review--reveal-thread (review id)
  "Show the thread ID of REVIEW, whose threads the UI has.
In the task's report, with the changes, when it draws them
\(`harness-ui-patch-review--report-shows-p'), point on the thread once
the report has settled; else in the library's threads view, whose
comments link to the files as the branch has them."
  (let ((task (harness-ui-patch-review--r-task review)))
    ;; A task no longer waiting for review is shown from its history.
    (unless (harness-ui-patch-review--reviewing-p task)
      (setf (harness-ui-patch-review--r-show review) t))
    (if (harness-ui-patch-review--report-shows-p review)
        (let ((popout (progn (harness-ui-patch-review--open-task task)
                             (harness-ui-popout-buffer (list 'report (plist-get task :id))))))
          (harness-ui-patch-review--when-settled
           review
           (lambda ()
             (unless (and (buffer-live-p popout) (harness-ui-patch-review--goto-thread popout id))
               (message "The thread %s is not in the report" id)))))
      (let ((buffer (change-review-open-threads (harness-ui-patch-review--r-set review) 'all)))
        (with-current-buffer buffer
          (setq default-directory (harness-ui-patch-review--link-directory review)))
        (unless (harness-ui-patch-review--goto-thread buffer id)
          (message "The thread %s is not in the review" id))))))

(defun harness-ui-patch-review--show-thread (task thread-id)
  "Show THREAD-ID of the review of TASK, a task record, once its threads are here.
THREAD-ID is a thread's id or the start of one that is unique."
  (let ((review (harness-ui-patch-review--review-for task)))
    (harness-then
     (harness-ui-patch-review--sync review)
     (lambda (_)
       (condition-case err
           (if-let* ((thread (change-review-find-thread (harness-ui-patch-review--r-set review)
                                                        thread-id)))
               (harness-ui-patch-review--reveal-thread review (change-review-thread-id thread))
             (message "The review of %s has no thread %s" (harness-ui-patch-review--title review) thread-id)
             (harness-ui-patch-review--open-task task))
         (error (message "%s" (error-message-string err))))))))

(defun harness-ui-patch-review-show-thread (task-id thread-id)
  "Show the thread THREAD-ID of the review of the task TASK-ID.
The review opens in the task's report, with point on the thread: the
closed threads shown too, when the thread is one.  The task and its
threads come from the harness, so this does not wait for them; what
cannot be shown is said in the echo area."
  (harness-ui-call "_harness/task/get" (list :id task-id)
                   (lambda (task)
                     (if (and (consp task) (plist-get task :id))
                         (condition-case err
                             (harness-ui-patch-review--show-thread task thread-id)
                           (error (message "%s" (error-message-string err))))
                       (message "No task %s" task-id)))
                   (lambda (err)
                     (message "Could not read the task %s: %s" task-id (harness-error-message err)))))

(defun harness-ui-patch-review--follow-thread (result)
  "Open the thread a link names: RESULT is what the harness resolved it to.
On `harness-ui-linking-handlers'.  Without the task or the thread the
session is shown, if the answer has one."
  (let ((task (plist-get result :task))
        (thread (plist-get result :thread))
        (session (plist-get result :session)))
    (cond ((and task thread) (harness-ui-patch-review-show-thread task thread))
          (session (message "The link names no thread of a review: its session opens")
                   (harness-ui-visit-session session))
          (t (user-error "The harness named no thread for this link")))))

(defun harness-ui-patch-review--link-context ()
  "Return the session of the task whose review this buffer shows, or nil.
On `harness-ui-linking-context-functions': the links in a thread's
comments are written in the session that works on the task."
  (when-let* ((review (or (and (bound-and-true-p change-review-ui--set)
                               (harness-ui-patch-review--set-p change-review-ui--set)
                               (harness-ui-patch-review--set-review change-review-ui--set))
                          (harness-ui-patch-review--review-here)))
              (session (plist-get (harness-ui-patch-review--r-task review) :session)))
    (and (stringp session) (not (string-empty-p session)) session)))

(defun harness-ui-patch-review--register-links ()
  "Have ui-linking open a link to a thread here, and tell it whose text this is."
  (setf (alist-get "thread" harness-ui-linking-handlers nil nil #'equal)
        #'harness-ui-patch-review--follow-thread)
  (add-hook 'harness-ui-linking-context-functions #'harness-ui-patch-review--link-context))

(defun harness-ui-patch-review--unregister-links ()
  "Take what `harness-ui-patch-review--register-links' added away again."
  (when (eq (cdr (assoc "thread" harness-ui-linking-handlers)) #'harness-ui-patch-review--follow-thread)
    (setq harness-ui-linking-handlers (assoc-delete-all "thread" harness-ui-linking-handlers)))
  (remove-hook 'harness-ui-linking-context-functions #'harness-ui-patch-review--link-context))

;;;; Module

(defun harness-ui-patch-review--redraw-dropped ()
  "Draw again what showed the reviews dropped for being stale.
A reload drops the reviews an older layout of the structs made as the
file loads (`harness-ui-patch-review--drop-stale-reviews'), when little
of the module is there to draw: the report and the banner that showed
one hold what it drew until now, and are drawn again here, which makes
the review again."
  (let ((ids (prog1 harness-ui-patch-review--dropped
               (setq harness-ui-patch-review--dropped nil))))
    (dolist (id ids)
      (condition-case err
          (harness-ui-patch-review--redraw-surfaces id)
        (error (harness-log 'warn "patch review: could not draw %s again: %s"
                            id (harness-error-short-message err)))))))

(defun harness-ui-patch-review--init ()
  "Show the changes of a task in review in its report."
  (harness-ui-patch-review--drop-stale-reviews)
  (setq harness-ui-patch-review--active t)
  ;; Before the review banner: the changes are read, then the work is
  ;; verified or sent back.
  (add-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel -10)
  (add-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  ;; A comment the reviewer writes on an approved file takes the approval off.
  (add-hook 'change-review-changed-functions #'harness-ui-patch-review--on-comment)
  (with-eval-after-load 'harness-ui-review
    (add-hook 'harness-ui-review-pending-functions #'harness-ui-patch-review--pending-p)
    (add-hook 'harness-ui-review-changes-functions #'harness-ui-patch-review--banner-panel))
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-patch-review--setup-chat))
  ;; A link to a thread of a review opens here, once ui-linking is there.
  (with-eval-after-load 'harness-ui-linking
    (harness-ui-patch-review--register-links))
  (when (fboundp 'harness-chat-mode)
    (harness-ui-patch-review--setup-existing-buffers))
  (harness-ui-patch-review--redraw-dropped))

(defun harness-ui-patch-review--shutdown ()
  "Take the changes out of the reports again, ending the Ediffs of them."
  (setq harness-ui-patch-review--active nil)
  (remove-hook 'harness-ui-report-panel-functions #'harness-ui-patch-review--panel)
  (remove-hook 'harness-ui-event-functions #'harness-ui-patch-review--on-event)
  (remove-hook 'change-review-changed-functions #'harness-ui-patch-review--on-comment)
  (remove-hook 'harness-ui-review-pending-functions #'harness-ui-patch-review--pending-p)
  (remove-hook 'harness-ui-review-changes-functions #'harness-ui-patch-review--banner-panel)
  (remove-hook 'harness-chat-mode-hook #'harness-ui-patch-review--setup-chat)
  (when (boundp 'harness-ui-linking-handlers)
    (harness-ui-patch-review--unregister-links))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (bound-and-true-p harness-ui-patch-review-mode)
                 (derived-mode-p 'harness-chat-mode 'harness-ui-tasks-mode 'harness-ui-popout-mode))
        (harness-ui-patch-review-mode -1))))
  (let (popouts banners)
    (maphash (lambda (_id review)
               (push (harness-ui-patch-review--r-popout review) popouts)
               (setq banners (append (harness-ui-patch-review--r-banners review) banners))
               (harness-ui-patch-review--forget review))
             (copy-hash-table harness-ui-patch-review--reviews))
    (dolist (popout popouts)
      (when (buffer-live-p popout)
        (with-current-buffer popout
          (kill-local-variable 'change-review-ui--redraw-function))
        (harness-ui-popout-refresh (buffer-local-value 'harness-ui-popout-key popout))))
    ;; The review banners lose the changes with the next draw of their tail.
    (dolist (banner banners)
      (when (buffer-live-p banner)
        (with-current-buffer banner
          (kill-local-variable 'change-review-ui--redraw-function)
          (when (functionp harness-compose-redraw-function)
            (funcall harness-compose-redraw-function)))))))

;; Not `patch-review', the harness process's half, in `:requires': with
;; `harness-process' on, the default, this Emacs loads the UI modules
;; only, where `patch-review' is no module at all, and a module that
;; requires one that is not there fails to start -- the changes then
;; never show in the report.  The loader brings the half along with this
;; one (`harness--module-other-half') and this module reaches it over
;; ACP, so it needs no more.
(harness-define-module 'ui-patch-review
  :doc "A task's changes where its work is handed in and in its report: a file tree with the threads of comments below it, Ediff file by file with the tree beside it and the feedback box under it, approvals that skip the files done; the UI of the review."
  :requires '(ui ui-report ui-review)
  :init #'harness-ui-patch-review--init
  :shutdown #'harness-ui-patch-review--shutdown)

(provide 'harness-ui-patch-review)
;;; harness-ui-patch-review.el ends here
