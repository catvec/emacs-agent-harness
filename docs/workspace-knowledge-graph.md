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
```

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
`Preferences`), with the same provenance.  The user's own edits outrank
anything the agent writes; the client never deletes a page or a block,
and never touches `logseq/` inside the graph.

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
large graph does not make a turn wait on every file.  There is no index
and no vector: that is stage 1 of the longer design, and it sits behind
the same answers.

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

## What is not here yet

- The Logseq CLI client and DB graphs (stage 0 of the design), with its
  writer queue, retries, lock recovery and graph schema.
- The SQLite index, FTS and embeddings (stage 1); search currently
  reads the graph.
- The scribe, curator and dream (stages 3 and 4): captures are raw, and
  the agent writes durable knowledge itself.
- Deleting a block from the workspace: forgetting is the user's in
  Logseq.  A `knowledge_forget` needs the provenance check and the
  user's confirmation, and is not in this slice.

## Verification

- `lisp/modules/harness-logseq-test.el` covers the graph format: page names and
  namespaces, journal paths, bullets and properties, search ranking and
  workspace/journal filters, snippets, backlinks, property updates and
  the missing graph.
- `lisp/modules/harness-workspace-test.el` covers the workspace side: the thread
  page, journal captures, search and recall, the `knowledge_*` tools
  and their episode-only filter, the memory tools left with their own
  names and behavior, and the ACP aliases the Flutter app uses.
- `lisp/ui/harness-ui-workspace-test.el` asserts the header copy
  (`Knowledge · ready`) and the `knowledge/status` request.
- A live dev frame shows the workspace header over a temp graph; the
  screenshot is part of the hand-in.
