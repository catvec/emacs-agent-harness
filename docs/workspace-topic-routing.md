# Workspace topic routing and the graph explorer

Design note, November 2026.  This is the design of one change to
[workspace mode](workspace-mode.md): the router that decides which
thread a message belongs to, and the explorer that shows the Logseq
graph of the current thread.  The graph itself — its pages, captures,
properties and where it lives — is [the knowledge graph
page](workspace-knowledge-graph.md); this note does not repeat it.
The module contracts are in [the implementation
page](workspace-mode-implementation.md) and the modules are
[workspace](modules/workspace.md) and
[workspace-knowledge](modules/workspace-knowledge.md).

## The problem

Two faults.

1. **A topic switch did not start a thread.**  The first slice routed a
   message by an explicit thread, a `/new`, a thread's title, a topic
   cue, or the last thread.  The Emacs UI sends the thread the person
   has selected with every message, and the route read that as a
   binding: it always won.  `/new` was the only way to start a topic,
   and a message that plainly changed the subject stayed in the old
   thread.  What the design calls the router — the rules that decide a
   message's thread — was not there.
2. **The graph could not be read from workspace mode.**  The workspace
   writes its knowledge to the user's Logseq graph (the pages a person
   can open in Logseq, the journal captures of the turns, the links
   between them), but nothing in the harness showed what a thread's
   page held.  A person could open Logseq itself; the chat could not
   show the nodes that belong to the topic being discussed.

## What a message is routed by

`workspace/prompt` hands the message to `harness-workspace--route`,
which returns `(THREAD ACTION WHY)`, the action being `continue`,
`revive` or `new`.  The rules, in the order they are weighed:

| Rule | Signal | Answer |
|---|---|---|
| 1 | `:force-continue`, a leading `/continue`, or `:force-thread` (a client that binds a thread) | that thread; a parked one is revived |
| 2 | `:force-new` or a leading `/new` | a new thread |
| 3 | The message names another thread: its whole title, or two thirds of its own words (at least two) | that thread; revived when parked |
| 4 | A topic cue (`new topic`, `different topic`, `unrelated`, `switch topics`, `start over`, …) | a new thread |
| 5 | A client's *selected* thread that is not the one the last message went to | that thread; a cue or a name still wins over it |
| 6 | A soft cue (`what about`, `by the way`, `one more thing`, …) | the current thread when the message's words or meaning are its own, else the thread they name, else a new one (`cue`) |
| 7 | No current thread | a new thread (`first`) |
| 8 | A running turn, and a message of fewer than three content words or one the thread has already used | the current thread: it steers the turn |
| 9 | The current thread's score above `harness-workspace-router-threshold` | the current thread (`ranked`) |
| 10 | Another thread's score above the threshold and leading the current one's by `harness-workspace--router-margin` | that thread (`ranked`), revived when parked |
| 11 | A fresh subject: three content words of its own, none the thread has used, and no continuation word | a new thread (`fresh`) |
| 12 | The current thread holds none of the message's words | the thread that holds the most of them, revived when parked |
| 13 | Anything else | the current thread |

The selected thread (`:thread`) is therefore a **preference**, not a
binding.  Rule 5 lets a person who picked a thread in the sidebar write
into it without the router second-guessing them; rules 3, 4 and 6 still
let the message itself say otherwise.  A client that truly means to
bind the thread sends `:force-thread` instead.  That distinction is the
fix: the Emacs UI keeps sending `:thread`, and a topic cue or a fresh
subject now wins.

### The ranker

A thread is a small document.  It is made of **passages**: its title,
one summary passage (its summary and next action), and its last
`harness-workspace-router-recent` messages.  The title is the thread's
own name for itself, the summary is what the thread has concluded, and
the messages are what was said in it.  A passage is tokenized into
content words -- three letters or more, none of them a stop word -- and
counted.

The message is a **query** over those passages, scored the way a search
engine scores one (`harness-workspace--route-index`,
`harness-workspace--route-score`):

- each of the message's content words weighs by its **rarity** in the
  workspace: `log(1 + (N - df + 0.5) / (df + 0.5))`, where `N` is the
  number of passages and `df` the number that hold the word.  A word no
  thread has ever used weighs like one a single passage holds, so a
  message full of new words is not judged against a corpus that keeps
  growing;
- a word counts for the thread at the **field weight** of the passage
  that holds it best -- title 3, summary 2, message 1 -- and a word
  repeated in one passage grows sublinearly (`1 + log count`) and never
  past the field's weight;
- the thread's score is the share of the message's total weight the
  thread holds, over the title weight: `held / (3 x total)`, clamped to
  1.  A message whose words are all in the title scores 1.

That one number is what rules 9 to 12 read.  It is a share, so it does
not depend on how long a thread is: a long thread with one passing
mention of a word does not own the word the way a title does.  It is
also **local**: no provider, no model call, no index to go stale, and
the number can be recomputed from the timeline in front of the person.
A title's word outweighs a passing one because a person names a topic by
a word; a rare word outweighs a common one because `the` says nothing
and `grout` says a lot.

Another thread takes a message from the current one only when it leads
by `harness-workspace--router-margin` as well as by the threshold: a
message that fits both about as well stays where the person was
writing.  A message that fits no thread at all, and brings three words
of its own, is a new subject.

A message the current thread holds **nothing** of is not a continuation
of it, whatever words it borrows from the turn before it (`still`,
`also`, `then`).  It goes to the thread that holds the most of it, and a
message no thread holds at all starts one.  That is what keeps a
continuation word from pinning a message to a thread it has nothing to
do with: `the tile colour is still undecided` in a thread about a
wedding belongs to the tile thread.

### Meaning, when there is a model to ask

The ranker compares words, so a paraphrase (`what shade suits the
wall?` in a thread called "The tile is matte") shares nothing with the
thread and would start one.  When
`harness-workspace-knowledge-embedding-model` names a model and
`harness-workspace-router-semantic` is on (the default),
`knowledge/nearest` embeds the message and each thread's **digest** --
its title, its state, its summary and its newest message -- and returns
the cosines.  A thread's score is lifted by the share of what the words
left open:

    score' = score + 0.5 x cosine x (1 - score)

so meaning can place a thread the words did not, and cannot undo the
words of a clear match.  The vectors are the knowledge module's cache,
so a text already embedded -- a note searched yesterday -- is not embedded
again, and the digest is one small text per thread, not the thread.

The call is bounded: `harness-workspace-router-timeout` (2 seconds)
after which the words decide, and any failure is logged and the words
decide.  It is asked **where the words left room to be wrong**: rule
6's soft cue and rules 9 to 12.  A command, a named thread, a bound
thread and a topic cue never pay for it.  Without an embedding model
nothing is asked at all: no message costs a provider call to be placed.

### Watching it decide

`scripts/routing-demo.sh` runs the ranker over a real workspace, with no
model to place a message, and prints for every message the score of each
thread and the thread it chose.  It runs the same conversation twice:
with the words alone, and with an embedding model stubbed in, so the
difference meaning makes is visible side by side.

### What the automatic ones do

The products that run a long chat unattended were checked for the
question "when does context clear, and who decides?":

| Product | Who ends a conversation | What carries across |
|---|---|---|
| Hermes | **The person.**  `/new` at a natural boundary; the memory files are a *frozen snapshot* read at session start to protect the prompt cache | `MEMORY.md` / `USER.md`, re-read by the next session; `session_search` when history is needed |
| Claude Code | **The harness**, by a threshold: it compacts as the context nears the model's window | A summary of the dropped history, in the same session |
| OpenClaw | **A schedule, not a message.**  Daily notes are distilled into `MEMORY.md` by the *dreaming* sweep | Layered notes, hybrid keyword + vector recall, active memory |
| dots | **The goal.**  One persistent agent per goal keeps notes and writes decisions back into shared memory | Saved notes about preferences, decisions and ongoing work, separate from chat |

None of them asks a model "is this a new topic?" for each message.
Hermes leaves it to the person, Claude Code to a context threshold,
OpenClaw and dots to a background consolidation pass.  The shape here
is two of those: the **threshold** (an episode's context share, as in
Claude Code) and the **person** (`/new`, a named thread, a selected
thread, as in Hermes).  Consolidation is the nightly dream, and it asks
no model.  What is added is the **ranker**, for the one case those
leave to a person: a message that starts on its own with no cue and no
thread named, where somebody has to notice the subject changed.  It is
a search over the conversation's own words, so it costs nothing and its
answer is a score on the divider.

**Routing writes nothing.**  Which thread a message goes to, and what
the turn leaves in the graph, are two jobs and are kept apart.  The
router decides a thread and writes no note; the agent writes a note
with `knowledge_write`, in the turn it belongs to, when the turn
settled something worth keeping.  Nothing runs a model over a finished
turn: [the knowledge graph
note](workspace-knowledge-graph.md#who-writes-a-note) has that decision,
and [its own note](design/no-per-turn-scribe.md) has the alternatives
and why the earlier per-turn extraction was removed.

### Why not a model to decide

Asking a model "is this a new topic?" on every message is the obvious
design and it was the first one here: a simple-tier model, a compact
state, `CONTINUE`/`NEW`/`THREAD <n>`.  It was removed.  It costs a
provider call before the reply starts, on the critical path of every
message whose subject is not stated; its answer is not explainable (a
wrong split cannot be read off a score); it needs a model that can be
asked when the workspace's own provider is down, out of quota or slow,
which is exactly when a person is talking; and a test of routing then
has to script a provider rather than assert a number.  A ranking over
the conversation's own words is cheaper, legible and testable, and the
embedding rerank gives it the paraphrase reach a judge was for.  When a
message is misplaced, the ranker's reason (`ranked`, `fresh`, `cue`) is
on the divider beside it, and `harness-workspace-router-threshold` is
one number to turn.

Every decision carries its reason (`explicit`, `command`, `named`,
`cue`, `selected`, `first`, `ranked`, `fresh`) on the thread's brief in
the timeline, which `workspace/timeline` returns as `:why`; the divider
beside it says whether the episode is new, resumed or continued.  A
message a later turn routed back into another thread is named with that
thread before it (`Thread / Kitchen renovation`), so the switch back is
visible where it happened rather than looking like a message that
continued the thread before it.  A wrong route is therefore visible
where it happened.

## The graph, for reading

The storage design is [the knowledge graph
page](workspace-knowledge-graph.md).  The parts the router and the
explorer depend on:

- A thread is a page named `Threads/<title>`, with an identity bullet
  carrying `workspace-id`, `thread-id`, `thread-title`,
  `workspace-status` and `project`.  The name is made once and stored
  on the thread as `:page`; the id is what finds it after a rename.
- A page name is a Logseq page name.  `harness-logseq-page-name`
  collapses whitespace, drops the characters Logseq would rewrite
  (`[`, `]`, `#`, `|`, `:`, `*`, `?`, `/` inside a segment, …) and
  truncates.  The thread's page name is normalized when it is made, so
  a title that itself contains a link (`Ask [[Stone Co]] for a
  sample`) still gives a page the journal can link to
  (`Threads/Ask Stone Co for a sample`), rather than a nested,
  malformed `[[… [[…]] …]]`.
- A turn is not a block of the page: it is a **capture** in the day's
  journal, with `thread:: [[<the page>]]` and the session and node as
  provenance.  The captures that link a page are the page's
  **backlinks** — the conversation nodes related to the thread.
- A durable note (`knowledge_write`, or `knowledge/write`) is a block
  of the thread's page, with `workspace`, `workspace-id` and `thread`
  properties.  Other pages the agent names (`Projects/harness`,
  `Preferences`, `People/Ada`) are blocks of those pages.
- `logseq/status` says whether the graph can be read (`:available`),
  and why not when it cannot (`no-page-directory`).  A harness without
  a Logseq graph directory still chats; the explorer says the graph is
  unavailable.

## The explorer

The Emacs UI gets a read-only buffer, `*Workspace Graph*`, opened by
the `Graph` button in the workspace header or `C-c w l`.  It shows the
current thread's page, its nodes, and the nodes that link to it.  It
explores: `RET` on a node opens the node with its children, `RET` on a
linked page opens that page, `b` goes back, `g` reads the graph again,
`q` buries it.

The state layer answers, so any client (the Emacs buffer, the app, a
call) sees the same graph:

| Method | Answer |
|---|---|
| `knowledge/graph (workspace &optional opts)` | the page of the workspace's thread: `:workspace`, `:workspace-name`, `:status`, `:why`, `:page-name`, `:page` (title, name, properties, tags, links), `:blocks` (the page's content blocks, with tags, links and properties), `:links`, `:backlinks` (the blocks that link the page), `:count`, `:thread` (the title) and `:thread-id`.  `OPTS` may name `:thread`; the last thread is read by default. |
| `knowledge/graph/node (workspace node &optional opts)` | the node's `:block`, the same graph answer, and `:children` (the indented blocks under it).  `NODE` is a block id or its line.  An unknown node answers `:status "missing"` and `:why "no-node"`. |
| `knowledge/graph/page (workspace name &optional opts)` | any page by the name a block links to, with its blocks and backlinks; `:status "missing"` for a page the graph does not have. |

The thread view's **Nodes** are the page's content blocks: the
property-only identity bullet is not a node, it is the page.  The
conversation's captures appear under **Backlinks**, each with the
journal page it came from.  A page's nodes and backlinks are the same
answer's `:blocks` and `:backlinks`, so the buffer is a reading of the
state, not a second store.  Its `:links` are the other pages its
blocks link to: a node's `thread` property naming its own page is not a
link to it.

An unavailable graph is not an error: `knowledge/graph` reads the page
name it would have, answers `:status "unavailable"`, `:why` and no
blocks, and the buffer shows `No graph` with the reason.  It never
tries to create a page on a graph it cannot write.  A graph that is
ready but holds no page for the thread says `Logseq · not found` and
`No page`, so a missing page is not read as a missing graph.

### The copy, before implementation

| Where | Words |
|---|---|
| Buffer, mode | `*Workspace Graph*`, `Workspace Graph` |
| Header | `Graph · <workspace>`, `Thread · <title>`, `Node · <id>`, `Page · <name>`, `Logseq · ready`, `Logseq · unavailable`, `Logseq · error`, `Logseq · not found`, `Logseq · loading` |
| Header buttons | `Refresh` (Read the graph again), `Back` (The node or page before this one), `Workspace` (The workspace chat) |
| Sections | `Page`, `Nodes`, `Backlinks`, `Node`, `Children` |
| Labels | `Name`, `Nodes`, `Title`, `Tags`, `Properties`, `Links`, `Role`, `Time`, `Text`, `Page` |
| Roles | `You`, `Agent`, `Note`, `Block` |
| Empty | `No graph`, `No page`, `No node`, `No nodes`, `No backlinks` |
| Loading | `Loading…` |
| Footer | `g · refresh`, `RET · open`, `b · back`, `q · bury` |
| Tooltips | `The page in the graph`, `The node in the graph`, `Read the graph again`, `The node or page before this one`, `The workspace chat` |
| Workspace header | `Graph` (The Logseq nodes of this thread) |
| Workspace timeline | `Thread · <title>` above a message routed to another thread |
| Key | `C-c w l` |
| Refusals | `No node or page here`, `No earlier view`, `No workspace buffer`, `No workspace open` |

A reason the harness sends (`no-page-directory`, an error's message) is
shown as it is, in the dim face, under `No graph`; it is data, not
copy.  A request that fails is shown in the caution face above the
view.

## What a turn is given

Routing decides *where* a message goes; the graph is what the thread
knows.  When an episode starts, its brief is built from the thread's
record and the graph: `knowledge/recall` returns the blocks that match
the message and the thread's title, the thread's own page is quoted,
and the workspace's prompt tells the agent to `knowledge_search` for
anything the brief did not give it and `knowledge_write` what is worth
keeping.  A conversation that runs long keeps its context in the
graph, not in a growing transcript: the thread's page is the durable
context, the episode is the working set, and an episode that ends
leaves the page behind for the next one.

## Alternatives

- **A model to decide.**  It routes well and costs a call per message
  before the reply starts, and its answer cannot be read off a score.
  The ranker decides the clear cases locally; the embedding rerank,
  when a model is configured, is the only thing asked and only where
  the words left room to be wrong ([why](#why-not-a-model-to-decide)).
- **Embeddings everywhere.**  Embedding every thread and every message on
  every turn would put a provider call on the critical path of every
  message, whether or not it is ambiguous, and a stale vector would
  route wrongly.  The words decide; the embeddings lift a close call,
  and the vectors are cached by text.
- **BM25 with its length normalization.**  A true BM25 also weighs a
  passage's length.  Here the documents are a title, a summary and a
  handful of messages, so the field weights (title 3, summary 2,
  message 1) say what length normalization would, and a share of the
  message's weight is easier to explain than a saturation constant.
- **Treating the selected thread as a binding.**  It is what the first
  slice did, and it is why a topic switch never split.  A binding is
  still available (`:force-thread`) for a caller that means it; the UI
  does not.
- **Reading the graph into a second store.**  The graph is the source
  of truth; the explorer reads it on demand and caches nothing.  A
  copy would need a sync and a conflict rule, and a person editing a
  page in Logseq would see the harness disagree.
- **A page per message, or a journal-only view.**  Thread pages are
  what a person opens to read a topic; messages are captures on the
  day's journal that link the page.  A page per message would bury the
  thread; the explorer shows both the page's notes and its captures.
- **A Flutter page for the graph at once.**  The methods were the
  contract and the Emacs buffer the first client; the app's `Graph` page
  followed without a new server surface.
- **Folding (`TAB`).**  The nodes are a few lines each and the buffer
  is short; an overlay per node is machinery without a reader.  It can
  be added when a thread's page outgrows a screen.

## The shape of the change

- `lisp/modules/harness-workspace.el`: the routing rules, the ranker
  (`--route-index`, `--route-score`, `--route-by-score`), the meaning
  blend (`--router-meaning`), and the decision's reason on the brief.
- `lisp/modules/harness-workspace-knowledge.el`: `knowledge/nearest`,
  the cosine of a query and texts through the embedding cache, which
  the meaning blend reads; the three graph readers, the page-name
  normalization the captures need, and the thread title in the answer.
- `lisp/ui/harness-ui-workspace.el`: the `Graph` button, `C-c w l`,
  the `*Workspace Graph*` buffer, its views, keys, tooltips and the
  refusals.
- `lisp/modules/harness-workspace-test.el`: the routing cases (a
  selected thread does not bind, a cue splits, a named thread is
  revived, a fresh subject starts a thread, an older thread is
  returned to, a continuation stays, `/continue`, `:force-thread`, the
  ranker's own cases, and a paraphrase placed by meaning) and the
  graph explorer (thread, node, page, unavailable graph, the title in
  the answer).
- `lisp/ui/harness-ui-workspace-test.el`: the explorer's exact copy,
  tooltips, keys, readers and refusals; the workspace header's `Graph`
  button.
- this page, the module pages and the workspace pages; the router's
  prompts are gone from `docs/prompts.md` with the model they asked.

## Not in this change

Routines and voice stay staged in [the
design](workspace-mode-implementation.md#the-staged-plan).  The
explorer reads the graph; it does not edit it, and the user's editor
stays the place to change it.  Who writes a note, the nightly dream and
the semantic mode are in the knowledge note
([who writes](workspace-knowledge-graph.md#who-writes-a-note), [the
dream](workspace-knowledge-graph.md#the-dream)); both the Emacs buffer
and the app's `Graph` page read it.
