# The workspace's knowledge graph

Design note, November 2026.  The workspace keeps its knowledge in the
user's Logseq graph.  The harness's memories (`memory_save`,
`memory_search`, …) keep the small behavioral notes and are not the
workspace's knowledge store.  This note records that decision, the
shape it takes in the first slice, and what is deliberately not there.

## The two systems, and why they were one

The harness already has a memory module: short, durable notes about how
the user wants work done, a convention of the codebase, a fact that
matters in a later session.  It is built for a task session, injected
into every prompt, and searched by words and meaning.

Workspace mode also needs to remember, but at a different level: a
thread is a line of work with a goal, decisions, open loops, the
projects and people it touches, and the days it spans.  A bag of short
notes cannot say that the countertop was a *proposal* that a *decision*
superseded, that the decision belongs to the kitchen thread and the
contractor, and that the contractor's page still calls the quote open.
That is a knowledge base: pages, links, properties and provenance, with
the user editing the same store in Logseq.

The first workspace slice used a local SQLite note store behind the
`memory/*` method names, as a stand-in for the graph.  That had three
consequences:

1. The workspace looked like it used the memory module, and its agent
   was told to `memory_search` and `memory_write` for knowledge the
   memory module never held.
2. Both modules registered the same bus methods and tool names
   (`memory/search`, `memory/get`, `memory_search`), and whichever file
   loaded last silently owned the name.  A dev harness, which enables
   every module, had one of the two implementations for all clients.
3. Nothing the workspace learned was visible in the user's knowledge
   base.  The stand-in was a second store with no links and no editor.

## The decision

- **The workspace's knowledge lives in a Logseq graph.**  The graph is
  the source of truth, and the user can open, edit and delete anything
  in it.
- **The workspace's own surface is named `knowledge`, not `memory`.**
  Bus methods are `knowledge/search`, `knowledge/write`,
  `knowledge/page`, `knowledge/pages`, `knowledge/notes`,
  `knowledge/recall`, `knowledge/status`, `knowledge/thread-page` and
  `knowledge/thread-touch`; tools are `knowledge_search`,
  `knowledge_write`, `knowledge_read` and `knowledge_status`.  No
  workspace code calls or defines a `memory/*` method.
- **The harness's memory module keeps its names and its purpose.**  The
  workspace prompt says what each one is for: knowledge goes to the
  graph, `memory_save` is only for small behavioral notes about how the
  user wants work done.
- **The knowledge tools belong to workspace episodes.**  An
  `agent/tools` filter offers them to a session whose `:ext` names a
  workspace, and removes them everywhere else.  The memory tools stay
  available in both.

## The graph

The first slice reads and writes a Logseq **markdown** graph, the layout
the repository's Logseq skill describes and `LOGSEQ_HOME` names:

```
<graph>/
├── pages/Threads/Kitchen renovation.md
├── pages/Projects/harness.md
├── pages/Preferences.md
└── journals/2026-11-07.md
```

A graph directory is resolved in this order: the workspace's `:graph`,
`harness-logseq-directory`, `$LOGSEQ_HOME`, `~/logseq`.  A workspace
created before the change gets the configured graph; `workspace/update
:graph` points it elsewhere.

The Emacs graph explorer reads this graph through `knowledge/graph`,
`knowledge/graph/node` and `knowledge/graph/page`; [the routing
note](workspace-topic-routing.md#the-explorer) is their design.

Why a markdown graph rather than the Logseq CLI and its DB graph of the
longer design: the CLI is not installed on this machine, the user's
actual graph is markdown, and the same methods can later be implemented
over the CLI without touching the workspace.  The client's methods
(`logseq/status`, `logseq/page`, `logseq/page-add`,
`logseq/block-add`, `logseq/property-set`, `logseq/search`,
`logseq/backlinks`) are the contract a DB-graph client has to keep.

### What a thread is

A thread is a page named `Threads/<title>`.  Its identity is a
property-only bullet at the top of the page:

```markdown
-
  id:: 5f0c…
  workspace:: Home
  workspace-id:: w-1a2b
  thread-id:: th-9c8d
  thread-title:: Kitchen renovation
  workspace-status:: active
  project:: /home/user/workspace
  created:: 2026-11-07
  learned-at:: 2026-11-07 14:20
  summary:: The tile is matte; the Stone Co sample is still open.
  next-action:: Wait for the Stone Co sample
```

`summary` and `next-action` are the thread's state, and neither costs a
model call.  The workspace keeps `summary` as the start of the thread's
last answer -- a copy, cut at 400 characters, so a brief can say where
the thread stands -- and writes it to the page when the thread changes
(`knowledge/thread-touch`).  `next-action` is the thread's, set by a
client through `workspace/thread/update`; no pass guesses it.

The page name is made once, from the title, and the thread id is what
finds it again: a thread renamed later keeps its page, and its
`thread-title` property follows the title.  Two threads that would want
the same page get ` (2)`, ` (3)` rather than sharing one.  The
properties are on a bullet, not at the top of the file, so the page is
still an outline of bullets, as the Logseq skill requires.

### What a turn is

The conversation is the timeline, not the graph.  What the graph keeps
from a turn is one **capture** in the day's journal:

```markdown
- user: Remember that the grout is warm grey.
  id:: 8d1e…
  workspace:: Home
  workspace-id:: w-1a2b
  role:: user
  thread:: [[Threads/Kitchen renovation]]
  source-session:: s-…
  source-node:: n-…
  learned-at:: 2026-11-07 14:20
```

A user or plan message is captured as it arrives; an assistant reply is
captured when its turn ends, so what is written is the final answer, not
the first streaming chunk.  A capture is capped, and the full text stays
in the session and the timeline.  The thread's page gets the link, so
Logseq's own backlinks show every day the thread was worked on.

A durable note is a **knowledge write** and goes on the thread's page
(or a page the agent names, such as `Projects/harness` or
`Preferences`), with the same provenance and `role:: note`.  A note on
its own thread's page does not link that page: the page is the note's
home, and a link to itself would only be a self-reference.  A note on
another page links the thread it belongs to.  The user's own edits
outrank anything the agent writes; the client never deletes a page or a
block, except a duplicate the dream removes, and never touches
`logseq/` inside the graph.

### The shape of a block

A message or a note keeps the lines it was written with.  The first
line is the bullet, and each later line is an indented continuation, as
the Logseq skill describes:

```markdown
- The tile is matte.

  The grout is warm grey.
  ```elisp
  (- 1)
  ```
  > a quote
  workspace:: Home
```

A blank line is a paragraph break inside the block, and a fenced code
block is text even where a line of it looks like a bullet or a
property.  The parser counts a block's end to the last block indented
under it, so removing a parent takes its children with it.  Properties
stay lowercase and dashed, pages are namespaced (`Threads/`,
`Projects/`, `Dreams/`), and a link names a page that exists.

## Who writes a note

The agent, in its turn.  It has the conversation in front of it, it
knows what the turn decided, and it writes what matters with
`knowledge_write` before it answers:

```json
{"text": "The grout is warm grey.", "page": "Projects/Kitchen"}
```

The block goes on the thread's page, or on a page the agent names, with
the provenance above and `role:: note`.  Asked twice, it is written
once: the write path compares the statement with the target page's own
blocks, whitespace and case aside, and answers with the block already
there.  A value the secrets module knows is masked on the way in, so a
declared credential never reaches the graph.  A turn
that decides nothing writes nothing, which is most turns.

There is no second pass over the turn.  The decision, the alternatives
and the bounds a later consolidation would respect are [their own
note](design/no-per-turn-scribe.md).  An earlier slice ran a *scribe*:
a simple-tier model that read every finished turn and its page and
answered `NOTE:`/`NEXT:`/`SUMMARY:` lines.  It was removed, because

- the agent had just done that work, with more context than the scribe
  had, so the pass repeated a job that was already finished;
- it cost a model call per turn, in the background, whether or not the
  turn settled anything;
- it wrote a summary and a next action on every turn, so trivia
  accumulated on the page and the state drifted away from what the
  person had decided;
- the page it read grew with every note it wrote, so each turn's prompt
  was larger than the last.

What it leaves behind is the machinery, not the pass: the thread keeps
`summary` and `next-action` as ordinary fields, and the page shows them.

A note is written by one of three writers, and each one knows what it
is for:

| Writer | When | What |
|---|---|---|
| the agent | in its turn, when the turn settled something | decisions, facts, commitments, open loops, through `knowledge_write` |
| the user | whenever they edit the page in Logseq | anything; their blocks outrank the agent's and are never rewritten |
| the dream | once a night, with no model | the page's identity and state, a duplicate note removed, a `Dreams/<date>` report |

## The dream

The dream is the graph's own maintenance pass.  It asks no model: it
reads every thread page of the workspace and

- writes the thread's identity and state again: title, project, status,
  summary and next action;
- keeps the first of a note this workspace wrote more than once and
  removes the others (the user's blocks and captures are left alone);
- writes what it did on a `Dreams/<date>` page, one bullet per thread,
  under a `Dream over Home` bullet.

`knowledge/dream` takes `:dry-run` (report what would change, write
nothing) and `:report` (write the report page; the default is
`harness-workspace-knowledge-dream-report`).  It returns
`(:workspace :date :dry-run :pages :removed :report-page)`.

With `harness-workspace-knowledge-dream` `auto` (the default), the
module wakes at `harness-workspace-knowledge-dream-hour` (3 by default),
dreams every workspace the harness knows that has not been dreamed that
day, and records the date in `workspace-dreams.eld` under the state
directory, so a restart does not repeat it.  A dream that fails is
logged and tried again the next night.  The review UI for its operations
is stage 4 of the implementation design; the pass and its report page
are here.

### Why consolidation is bounded, and where

A whole-thread pass is the one place a model would be useful: once the
day's threads are on the pages, it could merge two that turned out to
be one, retire a note a later decision superseded, or write the
paragraph a person would want to read.  It is not what this slice does, and the
bound it respects is worth stating, because the per-turn version broke
it:

- **Once a night, not once a turn.**  The cost is per workspace per
  day, whatever the number of turns, and a night with no change costs
  no call because the pass asks no model at all today.
- **Per thread page, not the whole graph at once.**  A page is what one
  topic said; the pass reads a page, not the graph, so its work does
  not grow with the size of the workspace.
- **It can be turned off, and its result is a page a person reviews.**
  `harness-workspace-knowledge-dream` is `nil` or `auto`, `:dry-run`
  reports without writing, and what it did is a `Dreams/<date>` page
  in the graph the user already reads.

If a model is added to a later dream, it belongs there, inside those
bounds, and it is a change of its own: it does not bring back a pass
over every turn.

### Finding it again

`knowledge/search` reads the graph and ranks blocks by the words they
match, then recency.  With a workspace, it returns that workspace's
blocks by their `workspace-id`; `:all` searches the whole graph,
including the user's own notes.  A thread search keeps to that thread's
page and its journal captures.  A result is the same shape the SQLite
stand-in returned (`:id`, `:page`, `:thread`, `:role`, `:text`,
`:snippet`, `:ts`), so the brief, the Emacs UI and the Flutter client
did not change shape.

The brief gets the thread's own page, its recent turns, and the graph's
matching blocks, and it names the graph path.  Its closing instruction
sends the agent to `knowledge_search` for anything missing and to
`knowledge_write` for what is worth keeping.

Search reads the newest pages and journals first and stops at
`harness-logseq-search-pages` and `harness-logseq-journal-pages`, so a
large graph does not make a turn wait on every file.

`knowledge/search` also takes `:semantic`; with
`harness-workspace-knowledge-embedding-model` set, the word matches and
the workspace's newest blocks are embedded by `provider/embed`, and the
blocks nearest the query in meaning come first, each with a small boost
for the words it matched.  A tool asks for it with `mode: semantic`.  If
no embedding model is set, the mode says what is missing rather than
guessing.  The vectors are kept in memory and dropped when
`harness-workspace-knowledge-embedding-cache` fills; the graph is not
changed.  There is still no index: a later stage puts one in front of
the same answers without changing the contract.

## Name collision and the clients

Renaming the workspace's tools and methods was necessary, but the
Flutter `Workspace` client already asked for `memory/notes`,
`memory/search` and `memory/status` with a `:workspace`.  Rather than
change and rebuild the app for a rename, ACP grows
`harness-acp-extra-method-aliases`: an alias names a target method and a
guard on the call's params.  `workspace-knowledge` registers

```
memory/notes  -> knowledge/notes   when the params name a workspace
memory/search -> knowledge/search  when the params name a workspace
memory/status -> knowledge/status  when the params name a workspace
```

The alias is offered in the extension catalogue so `can()` sees it, it
calls the target's argument mapping, and it applies only when the
guard does.  A call without `:workspace` still reaches the harness's
own memory tools, which is what the Emacs memory page makes.  The Emacs
workspace UI moved to `_harness/knowledge/status` and the
`workspace/knowledge-changed` event directly.

## Alternatives considered

- **Keep the SQLite store and sync it to Logseq.**  Two sources of
  truth, a synchronizer to get wrong, and the user's edits would lose
  to the cache.  Rejected: the graph has to be the authority.
- **Implement the Logseq CLI and DB graph first.**  The CLI is not
  installed, the user's graph is markdown, and the CLI's lock and
  retry semantics are a task of their own.  The markdown client proves
  the workspace's side of the contract now; the CLI client can replace
  the file access later behind the same `logseq/*` methods.
- **Remove the memory tools from the workspace completely.**  The user
  still has behavioral preferences ("short answers", "no bullet lists
  in reviews"), and the repository's memory module is the right place
  for those.  Removing them would push a behavioral note into a
  knowledge page where nothing reads it back into a task session.
  Rejected: the workspace prompt states the split instead.
- **Write every message to the thread's page.**  The page would become
  a transcript and stop being a knowledge page; the journal is Logseq's
  place for the day's captures, and it already links back to the
  thread.  Rejected.
- **Keep the `memory_search` name and let the workspace module win.**
  That is the bug this work removes: a plain session would get the
  workspace's two-argument method, and the memory page's search would
  error or return the wrong corpus.
- **Keep the per-turn scribe and gate it** (only after a "remember" cue,
  every fourth turn, or when a thread parks).  A gate answers *when* to
  duplicate the work, and the work is still duplicated: the agent wrote
  the note in the turn, or chose not to.  A "remember" cue reaches the
  agent long before it reaches a gate, and a turn worth keeping is often
  the one no rule predicted.  Rejected: the turn is the agent's, and so
  is what it leaves behind.
- **Ask the dream's model to write the notes instead.**  The same call
  with less context: by the next night the turn is a capture in a
  journal the dream does not read.  Rejected: nothing to consolidate on
  a page the agent did not write.

## What is not here yet

- The Logseq CLI client and DB graphs (stage 0 of the design), with its
  writer queue, retries, lock recovery and graph schema.
- The index (stage 1) and its persistent vectors: search reads the
  graph, and the semantic mode reranks the word matches and the newest
  blocks with vectors kept only in memory.
- The dream's review UI and its operation classes (stage 4): the pass,
  its nightly schedule, its dry run and its report page are here; a
  review of its operations before they apply is not.
- Deleting a block from the workspace by hand: forgetting is the user's
  in Logseq.  A `knowledge_forget` needs the provenance check and the
  user's confirmation, and is not in this slice.

## Verification

- `lisp/modules/harness-logseq-test.el` covers the graph format: page names and
  namespaces, journal paths, bullets and properties, search ranking and
  workspace/journal filters, snippets, backlinks, property updates and
  the missing graph.
- `lisp/modules/harness-workspace-test.el` covers the workspace side: the thread
  page, journal captures, search and recall, the `knowledge_*` tools
  and their episode-only filter, the memory tools left with their own
  names and behavior, the ACP aliases the Flutter app uses, that a turn
  costs one model call and leaves no note of its own, and the dream
  removing a duplicate note and refreshing a page.
- `lisp/ui/harness-ui-workspace-test.el` asserts the header copy
  (`Knowledge · ready`) and the `knowledge/status` request, the graph
  explorer's exact copy, its tooltips, keys and refusals, and the
  thread's name over a message routed back into another thread.
- A live dev frame shows the workspace chat and the graph explorer over
  a temp graph; the screenshots are part of the hand-in.
- `scripts/notes-demo.sh` runs three turns of one workspace with no
  scripted second pass and prints, per turn, the requests made while it
  ran and after it ended, then the thread's page.  It is the check a
  person can run to see that the note comes from the turn that decided
  it: two turns settle nothing and leave the page empty, the third
  writes one note with its provenance, and the count after every turn is
  zero.
