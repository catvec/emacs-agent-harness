# Review navigation from an MCP client

An agent can already read a review's threads and answer them (`review_threads`,
`lisp/modules/harness-tools-review.el`), and can list and read the user's
buffers (`emacs_buffers`, `emacs_buffer`).  It could not open the review
itself: to say "show me the Ediff of the diff of `a.el` at that thread" the
agent needed the user to click through the report, and a user typing with
speech-to-text cannot easily click through a file tree.  This adds three
bounded MCP tools that open the harness's own pages and the review's own
views for them:

- `review_open` -- a task's changes, Ediff on a selected diff/file/thread,
  or the threads view;
- `harness_views` -- the fixed list of harness pages the connected Emacs can
  open, whether the optional plugin each belongs to is enabled, and the
  target each needs;
- `harness_open` -- one of those pages: sessions, one session, the task
  board, a task's report, pending requests, the conversation tree, access,
  worktrees, settings, the server page, usage or the task slots.

The tools are declared in `lisp/modules/harness-tools-emacs.el` and
`lisp/modules/harness-tools-review.el`; the requests they send cross the MCP
boundary the harness already has with a lent Emacs
(`lisp/harness-emacs-endpoint.el`), and the UI entry points they reach are in
`lisp/ui/harness-ui.el` and `lisp/ui/harness-ui-patch-review.el`.
`lisp/ui/harness-ui-navigation-test.el`, the `harness-ui-patch-review-tool-open-*`
tests in `lisp/ui/harness-ui-patch-review-test.el`, and the endpoint tests in
`lisp/harness-emacs-endpoint-test.el` cover them.

## The one decision that shapes it: a vocabulary, never a command

The harness lends its Emacs to an agent through a fixed list of requests
(`harness-emacs-endpoint--methods`), and that list is deliberately not a
command runner: no request takes Lisp or a command name, because a model's
text would then run in the Emacs the user is typing in.  Navigation keeps
that rule.

`harness_views` and `harness_open` name one of twelve views in a `defconst`
(`harness-ui-tool--views`); `review_open` names one of three review surfaces
and a target.  A view is opened by calling the click handler's own function
directly, never `call-interactively`: no view may read its target from the
minibuffer, take a prefix argument, load a module, connect to a host, or
start a paid model call.  What the vocabulary does not name cannot be
opened, whatever the agent writes.

The catalogue is also the *availability* question.  `harness_views` reports
a view as available only while the module that owns it is running now
(`harness-module-ready-p`, plus a real function binding that is not an
autoload).  A function left behind by a disabled module is not a view:
`harness_open` refuses it with "Harness view unavailable" rather than
calling stale code.  Each page is gated by the module that owns it, and
the report and pending pages also need `ui-popout`.

`harness_views` is read-only and joins the inspection tools
(`harness-perms--inspection-tools`); `harness_open` and `review_open` are
`meta` calls and are decided like any other tool, because opening a window
in the user's Emacs is a visible change, even though it changes no data.

## What a target means

`review_open` resolves its task first: an exact task id, a unique id prefix,
or its exact name compared without case
(`harness-tools-resolve-task`).  A voice request names a task by its title,
not by the id `task/submit` returned; an ambiguous prefix is refused rather
than guessed.  Without `task` the tool means the calling session's own task,
so a task's agent can open its own review.

The diff is `base` (the branch against its merge base), `since-review` (the
last reviewed tip against the branch), or any git revision range the UI's
own selector understands (`main..task/fix`, `HEAD~2...HEAD`).  `file` is an
exact changed path in that diff; a rename's old name resolves to its new
one.  `thread` is a thread id or unique prefix from `review_threads`; it is
unfolded, expanded whole, and revealed even while the filter would hide a
closed thread.  Ediff also takes `line` and `side` (`old` or `new`); without
a file it starts at the named thread's file, else the first comparable file.

An unknown file, thread, revision or view is an error, never a quiet
fallback to a different diff: the interactive selector may retain the
diff it showed before, and a tool must not report success for it.  The
receipt names the actual commits, files and thread ids that were shown.

## The answer is the view, not the request

Opening a review reads git asynchronously and asks the harness for the
task and its patch-review data.  The MCP request therefore may not answer
when the call is *queued*: `harness-mcp-serve` now may return a promise,
and `harness-emacs-endpoint-answer` waits for it before sending one MCP
answer (or one JSON-RPC error).  A tool result says `opened` only when a
matching view buffer is live and displayed; `loading` means the wait is
still going.  `review_open` asks the Emacs with a 30-second deadline,
above the endpoint's own 25-second navigation deadline, so the tool never
times out while the view is still about to open.

Three races had to be closed for that answer to stay true:

- **Superseded navigation.**  A second request for the same task bumps a
  per-task token with a 25-second deadline; every stage after an
  asynchronous wait re-checks it, so a slow, older request cannot open its
  view after a newer one has replaced it.
- **A changed diff.**  Before Ediff displays fetched blobs, the file list,
  the merge base, the tip and the selected diff are compared with what was
  read when navigation started; a mismatch rejects the request rather than
  comparing the wrong versions.
- **A module stopped meanwhile.**  Availability is re-checked after each
  asynchronous stage, and a view that is no longer running refuses the
  request instead of calling its stale function.

The pending view also asks the harness for the session
(`_harness/session/get`) before deciding there is nothing to show: the UI's
cached pending list can lag a request that arrived after the last refresh,
and "No pending requests" would then be false.

## Alternatives that were not taken

- **A generic "run this command/key" tool.**  It would be the simplest way
  to expose every page and plugin, and it is exactly the arbitrary
  execution the endpoint's fixed vocabulary exists to prevent: a model
  could run `shell-command`, change settings or answer a permission
  request.  The fixed vocabulary costs one entry per page and buys the
  property that the tool can do only what it names.
- **`call-interactively` with a command name.**  Commands prompt for their
  own targets and honor prefix arguments; a tool call has neither a user
  at the prompt nor a prefix argument to give.  Calling the internal
  function with an explicit target is the whole point.
- **Opening a page by URL or by buffer name.**  The harness has no stable
  address for a view, and buffer names are not a contract: they carry
  project names and change with the data.  The catalogue names a page by
  what it is, not where it currently lives.
- **Auto-allowing the navigation tools.**  They open windows and start
  Ediff in the user's Emacs; that is visible work, so it goes through
  permissions with every other such tool.  Only `harness_views`, which
  reads, is auto-allowed.
- **Answering review comments from the opening tool.**  Approvals, feedback
  and thread replies stay with the user and `review_threads`' `<thread>`
  blocks.  A navigation tool that could close a thread would mix "show me"
  with "decide for me".

## What is not exposed, and why

The audit of the other harness pages found several that could be opened
harmlessly and a few that should not be, and only the harmless pages of
the main navigation are in the catalogue:

- **Pages that start work when opened.**  The insights page loads a model
  narrative, the provider check asks a provider, and version/update
  reaches the network.  Opening a page is not a place to spend money or
  wait on a remote host.
- **Pages about secrets and access.**  The secret-sources page lists
  what is masked but is close enough to credentials that it stays out;
  the remote-control page approves clients, which changes access rather
  than showing it.
- **Controls that are not pages.**  Settings changes, permission answers,
  approvals, feedback and merges have their own tools or the user's own
  keys; a navigation tool must not become a second way to decide them.
- **Secondary pages left out of the first catalogue.**  The
  model-complexity guide, the harness log and similar views do not need
  an agent to navigate to them today; each is reachable by adding another
  bounded entry to the catalogue, with the module it belongs to, when a
  use asks for it.

## Limits

Only the pages enumerated in `harness-ui-tool--views` are reachable.  A
plugin outside the harness that adds a page of its own is not in the
catalogue; it would need its own bounded entry point, added to the
catalogue with the module it requires, before an agent could open it.
`review_open` requires the task's review UI module (`ui-patch-review`)
and a connected Emacs; a phone-only or headless harness returns an error
rather than pretending to open a page.  Nothing here changes a review
decision, a setting, a permission answer or a plugin's enabled state.
