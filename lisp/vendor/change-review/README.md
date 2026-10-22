# change-review

Threaded review of change sets and patch sets, in Emacs.

A change under review is a **change set** with **versions**: the first
hand-in of an agent's branch and the one after the review, `[PATCH v1]`
and `[PATCH v2]` of an emailed series. Reviewers talk about it in
**threads** of **comments**, each thread open or closed (closed is the
good ending: the point made, the change made). Every comment says who
wrote it, when, where in the code it was made if it was made anywhere in
particular, and against which revision of the code.

```
Review of Retry the upload                v2 of 2
Threads  [open 2]  closed 1   all 3

▾ src/foo.el                                          2 threads
  ● 3f9a1c · line 18 · 3 comments · open          [Reply] [Close] [Diff]
  ┃ 1/3  Noah Huppert (you) · 2026-10-19 21:57 (2h ago) · v1  ▸ where
  ┃      Why eighteen? The tests only ever use 17.
  ┃ 2/3  Claude (agent) · 2026-10-19 22:10 (1h ago) · 3f9a1c2  ↗ conversation
  ┃      Because the retry loop needs one more.
  ┃ 3/3  Noah Huppert (you) · draft · ↳ re 2/3
  ┃      Then say so in a comment.
```

change-review is developed inside the
[Emacs agent harness](https://git.sr.ht/~catvec/emacs-agent-harness)
repository for now, in `lisp/vendor/change-review`, laid out as its own
repository will be once it is split out. It needs nothing of the
harness, and nothing but Emacs 29.1 or later. The harness reviews the
work of its agents with it, through an adapter that lives on the
harness's side; any other source of changes can do the same, and
emailed patches work out of the box.

## Try it

Review a patch, or a series of them, with nothing else installed:

```
M-x change-review-open-patches RET /path/to/series.mbox RET
```

The file may hold a series sent with `git send-email` and saved from a
mail program, `git format-patch` files put one after the other, a
single patch mail, or the output of `git diff` or `diff -u`. The
patches show as a diff, with a thread of comments under each line a
comment is on. Press `c` on a line to comment on it (or on the region's
lines), `T` to list every thread, and `C-c C-c` to write the comments as
the replies to send, one mail for each patch with comments, in
`message-mode`. The comments are kept in `change-review-ui-directory`,
so opening the same patches again finds them; a later version of the
series, sent again, is another version of the same change set. When
the replies come back, `C-c C-i` in the view reads the comments out of
a reply mail (the region, or a mail saved in a file) and adds them as
threads, from whoever sent it.

From Lisp, build a set and open a view of it:

```elisp
(let ((set (change-review-make-set :id "demo" :title "A demo")))
  (change-review-add-version
   set (change-review-diff-version (my-diff-text) :id "3f9a1c2" :label "v1"))
  (change-review-comment
   set "Why eighteen?"
   :location (change-review-diff-location
              (car (change-review-version-files (change-review-latest-version set)))
              'new 18)
   :revision "3f9a1c2")
  (change-review-open-threads set))
```

## The views

One function draws a thread, `change-review-ui-thread-string`, whichever
view shows it, so a thread reads the same everywhere: a header with its
mark (open ● or closed ✓), its short id, where it is, how many comments
it has and its status (who closed it, and when), and buttons for what
can be done with it; then each comment under a bar that runs the
thread's length, with its place in the thread (`2/3`), its author (marked
"you" or "agent"), the time, the revision it was written against, a
mark when it is still a draft, the comment it answers when that is not
the one above (`↳ re 1/3`), a `▸ where` button that shows where it was
made, and for an agent's comment `↗ conversation`, then its text.
`change-review-ui-thread-line` draws the same thread as a row of a list.

**No line is wider than the room it has.** A thread is drawn to a width,
by default the columns of the window that shows the buffer, and a line
that would be wider says less until it fits: a closed thread says how
long ago instead of the date and drops who closed it unless it was
someone else, a comment's header gives up the date for how long ago, then
the revision, the words of its links, the time and the "(you)" and
"(agent)" marks, and the header of a thread the count of its comments and
at last its buttons. So a thread in a narrow window, a side-by-side
comparison say, does not wrap.

**The threads view**, `change-review-open-threads`, lists all the
threads of a set, grouped by file, with a filter on their status
(`change-review-ui-default-filter`). Point is on a comment, and the keys
act on it:

| Key | Does |
| --- | --- |
| `n` `p` / `N` `P` | Move between comments / between threads. |
| `RET` `TAB` | Show where the comment was made (file, line, revision, the lines of the diff around it), or hide that again. |
| `r` | Reply to the comment, as a draft. |
| `x` / `s` | Close the thread or open it again / set its status by name. |
| `d` | Show the thread in the diff view (`change-review-visit`). |
| `o` | Follow an agent's comment to the conversation it came from. |
| `e` `k` | Edit / delete a draft. |
| `c` | Comment on the change as a whole. |
| `f` `F` | Cycle / set the filter: open, closed, all. |
| `C-c C-c` `I` | Send the drafts / read the comments out of a reply. |
| `g` | Draw again. |

**The diff view**, `change-review-open-diff`, shows the files of a
version as the unified diff (it is a `diff-mode`, so its own keys work),
with the threads of each line under it, drawn by the same function. `c`
comments on the line at point, or the region's lines; `r`, `x`, `o`, `e`
and `RET` act on the thread under point as they do in the threads view;
`C-c C-n` and `C-c C-p` move between threads, `C-c C-t` lists them,
`C-c C-f` changes which show.

**Folding.** Under a line a thread can be folded, to keep the lines of
the file in sight. A closed thread is **one line** at first (unless
`change-review-ui-collapse-closed-in-diff` says not): a triangle `▸`, its
mark and short id, how long ago it was closed, and the first words of
what it says (of what was said, not of what it quotes: a comment that
opens with `> ` lines is summed up by those that follow). `TAB` on the
line it is under, a click on its triangle or on its words, or `RET`
opens it to its **conversation**, the triangle `▾`; a thread open to
begin with can be folded to one line the same way. A thread that is
longer than the window has room for (`change-review-ui-max-thread-lines`:
what the window shows, a number, or nil) is cut, with how many lines more
there are in a line of its own, `… 8 more lines`: `TAB` again, or a
click on it, shows **all** of it, and one more `TAB` folds it to a line.
Where several threads are under a line they are folded together, as the
first goes. What was folded is kept with the set, so a view drawn again
and another view of the same set show it so; a thread whose status
changes goes back to what a thread of its new status is at first.
Where there is no thread on the line, `TAB` is what it was.

**Your own views.** A side-by-side comparison, or any buffer that shows
the lines of a file, draws the threads under its lines with
`change-review-ui-add-thread-overlay` and takes the same keys by turning
on `change-review-ui-lines-mode` (or by using its map as the parent of
its own). The views follow the set: whatever changes it, they draw
again soon (`change-review-changed-functions`, `change-review-ui-refresh`).
A view that lets its threads be folded passes `:fold` with how the set
has the thread (`change-review-ui-thread-fold`) and `:max-lines` (what
`change-review-ui-current-max-lines` says), and a `:width` to fit
(`change-review-ui-current-width`); `change-review-ui-current-size` is
both, which a view that follows its window compares with the size it drew
at, to draw again when the window gives the threads another.
`change-review-ui-set-fold` and `change-review-ui-cycle-folds` fold a
thread from code.

The options of the views are `change-review-ui-time-format`,
`change-review-ui-relative-times`, `change-review-ui-width`,
`change-review-ui-default-filter`, `change-review-ui-collapse-closed-in-diff`,
`change-review-ui-max-thread-lines`,
`change-review-ui-read-function` (a comment is read in a `string-edit`
buffer by default; `C-c C-c` keeps it as a draft) and
`change-review-ui-directory`.

## The data

Everything is a `cl-defstruct`, and every struct turns into plain data
(plists, lists, strings, numbers) and back, so a set can be kept in a
file or sent anywhere.

| Struct | What it is |
| --- | --- |
| `change-review-set` | The change under review: `id`, `title`, `description`, its `versions` and `threads`, the `file` it keeps itself in. |
| `change-review-version` | One proposal of the change. Its `id` is its **source revision**: the commit it ends at, the message id of its first mail. Also `number`, `label` ("v2"), `time`, `author`, `title`, `description` (a cover letter, a report), `base`, `tip` and its `files`. |
| `change-review-file` | A file the version changes: `path`, `old-path`, `status` (A, D, M, R, C, T), its part of the unified diff in `patch`, the counts of lines added and deleted. |
| `change-review-thread` | A conversation: `id`, `status` (`open` or `closed`), its `comments`, and a `history` of who changed the status and when. |
| `change-review-comment` | One message of a thread: `id`, `thread`, `reply-to`, `author`, `body`, `time`, `location` (optional), `revision`, `sent`. |
| `change-review-location` | Where in the change: `file`, `line`, `end-line`, `side` (`new` or `old`), the lines of the diff around it (`excerpt`). A comment with none is on the change as a whole. |
| `change-review-author` | Who: `kind` (`user`, `agent`, `other`), `name`, `email`. An agent has its `session` and the `tool-call` that produced the comment too, which is a link to the point of the conversation it came from. |

A comment records its thread, itself, its optional location, its author
and the source revision it was written against. A comment whose `sent`
is nil is a **draft**: written, not delivered yet. A reviewer collects
drafts across the files of a version, then sends them all at once, as
a review is submitted.

## Operations

Everything that changes a set is an **operation**, a plist of plain
data, performed by `change-review-apply`:

| `:op` | Data | Does |
| --- | --- | --- |
| `add-comment` | `:comment` | Adds a comment; starts its thread if the set has none of that id. |
| `set-status` | `:thread`, `:status`, `:id`, `:time`, `:author`, `:revision` | Closes or opens a thread, and notes who did it in its history. |
| `add-version` | `:version` | Adds a version. |
| `mark-sent` | `:comments`, `:time`, `:meta` | Marks drafts as delivered. |
| `edit-comment` | `:comment`, `:body` | Replaces the text of a comment. |
| `delete-comment` | `:comment` | Deletes a draft. |

Performing an operation twice changes nothing the second time, because
it names what it adds by id. So a set can be kept by writing its
operations down, copied by sending them, and made to agree again by
sending them again. The functions that make the operations are
`change-review-comment`, `change-review-reply`,
`change-review-update-status` (`change-review-close`,
`change-review-reopen`), `change-review-add-version`,
`change-review-mark-sent`, `change-review-edit` and
`change-review-delete`; they hand the operation to
`change-review-dispatch` (below). Whatever changes a set by one calls
`change-review-changed-functions` with the set and the operation, which
is how the views stay current.

Queries: `change-review-threads` (by status), `change-review-threads-by-file`,
`change-review-thread-counts`, `change-review-drafts`,
`change-review-find-thread` (by id or the start of one),
`change-review-find-comment`, `change-review-latest-version`.

## Diffs

change-review-diff.el works from the text of a unified diff, with no git
and no process. `change-review-diff-parse` cuts a diff into the files it
changes, as `git diff`, `git format-patch`, `diff -u` and `diff -ru`
write them. A comment on a line keeps the part of the diff around the
line, its **excerpt** (`change-review-diff-location` makes the location
that holds it, `change-review-diff-context-lines` lines of context
before the change it ends), and that is what the comment was about when
the version it was made on is gone. A line commented on in one version is
somewhere in the next: `change-review-diff-relocate` looks for it in
the diff of a file of another version and says whether it is where it
was, `moved`, `changed` (edited), `gone` or not to be told;
`change-review-diff-place` does the same with the full text of the file
at hand, carrying the line through the ranges of a diff
(`change-review-diff-ranges`, `change-review-diff-map-line`) or finding
it by what it says (`change-review-diff-find-line`). The views show the
result ("line 44 (was 42)", "line 44 (changed since)").

## Emailed patches

change-review-mail.el is everything a review needs of email.

A series of patch mails is a version of a change set:
`change-review-mail-parse-message` reads one mail as `git format-patch`
or `git send-email` wrote it, or as a mail client saved it;
`change-review-mail-parse-mbox` reads several;
`change-review-mail-series` puts them together by the version in their
subjects (`[PATCH v2 1/3]`) and their threads;
`change-review-mail-make-set` makes a set of a text with the versions it
holds and `change-review-mail-import-patches` adds the versions of a
text to a set. A bare unified diff is one version too.

A reply to patches quotes the lines the answer is about with `> ` and
writes the answer under them, as mailing lists have for decades:

```
> diff --git a/src/foo.el b/src/foo.el
> @@ -15,4 +15,4 @@ (defun foo ()
>  (setq a15 15)
> -(setq a18 18)
> +(setq a18 'eighteen)

Why eighteen?
```

`change-review-mail-render-comments` writes comments that way, each line
of the diff quoted once with the comments under the lines they are about
(`:attribution` puts a line above, `:history` quotes the comments a reply
answers, `:markers` tags each comment, say with the thread it belongs
to); `change-review-mail-parse-reply` reads such a text back, also when
it comes from a mail client: attribution lines, signatures, elisions and
the quotes of earlier replies are told from the diff.
`change-review-mail-import-reply` adds what it reads to a set as
comments (a comment that answers one already in a thread is a reply in
it; importing a reply twice adds nothing), and
`change-review-mail-import-reply-message` does so for a whole mail, the
sender being the author and its date the time.
`change-review-mail-reply-message` writes a whole reply mail for the
drafts of a patch and `change-review-mail-compose` opens one for each in
`message-mode`; sending it marks its comments sent.

The same text format is what a host can use to deliver the drafts of a
review to something that reads text: any reader of a mailing list reads
it.

## Making it yours

A struct that includes `change-review-set` is a set of a kind of your
own, and the generic functions below decide what it does differently:

| Generic function | Decides |
| --- | --- |
| `change-review-dispatch` | Where an operation goes. By default: performed here, then saved. A set that lives elsewhere sends it there, and performs it here too, so that what the user did shows at once. |
| `change-review-save` | How a set is kept. By default: in its `file`, if it has one. |
| `change-review-current-author` | Who the user is. By default: `user-full-name` and `user-mail-address`. |
| `change-review-own-author-p` | Whether a comment is the user's own, which `(you)` marks, may be edited and is not followed. By default: the author is the current author. |
| `change-review-follow-author` | What following an agent author to its conversation does. |
| `change-review-file-text` | The text of a file the diff holds only a part of. |
| `change-review-placement` | Where a thread is now, in the newest version: by default relocated in the version's diff; a set that can read the files answers better. |
| `change-review-visit` | How a thread or a location is shown: by default in the diff view. |
| `change-review-send` | What sending the drafts does: for emailed patches, compose the replies. |

An adapter is therefore a few methods and the way the host's changes
become versions with files. The Emacs agent harness, for instance,
makes a task its set, each hand-in of the agent a version named by the
commit the branch ends at, keeps the threads in the harness (the
user's operations go there, the agent's come back as events and are
performed on the user's copy as they are), shows the files in Ediff with
the threads drawn under the lines by the library, places the threads
through git, and sends the drafts along with the feedback that sends the
task back. None of that is in this directory.

## Files

| File | Holds |
| --- | --- |
| `change-review.el` | The data, the operations, the generic functions, files. No drawing, no diff, no mail. |
| `change-review-diff.el` | Unified diffs: parsing, excerpts, finding a line in another version. |
| `change-review-mail.el` | Emailed patches and replies. |
| `change-review-ui.el` | The thread drawing, the threads view, the diff view, the commands. |

Each has a test file beside it (`*-test.el`).

## Tests

```
make test       # ERT, with nothing but this directory on the load path
make compile    # byte-compile, warnings as errors
```

## License

GNU General Public License, version 3 or later; see `LICENSE`.
