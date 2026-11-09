# Who writes a workspace note

Design note, November 2026.  It records one decision in [workspace
mode](workspace-mode.md): the graph's notes are written by the agent,
in the turn that settled them, and nothing reads a finished turn again.
The graph itself — its pages, captures, properties and where it lives —
is [the knowledge graph page](workspace-knowledge-graph.md); this note
does not repeat it, and it changes one section of it.

## The problem

The first slice ended every workspace turn with a **scribe**: a
simple-tier model that read the finished turn *and the thread's page*
and answered `NOTE:` / `NEXT:` / `SUMMARY:` lines.  Those became note
blocks, and the summary and next action went on the thread and its
page.  It was built to keep the graph true without asking the agent to
remember anything, and it worked.  It also had four faults, and each
one gets worse with use:

1. **It duplicated work that was already done.**  The agent had just
   answered the turn with the whole conversation in context.  The
   scribe read the same turn again, with less: a user line and an
   assistant line, plus a page.
2. **It cost a call per turn.**  On every turn, in the background,
   whether or not the turn settled anything — which is most turns.
3. **It accumulated trivia.**  A turn that decided nothing still got a
   summary and, often, a note.  The page filled with restatements of
   what had been said, and the thread's `summary` drifted from what the
   person had actually settled.
4. **Its prompt grew without bound.**  The page it read was the page it
   wrote to.  Every note made the next turn's scribe prompt larger, so
   the per-turn cost grew with the length of the thread.

The last two compound: a page full of restatements is a bigger prompt
that produces more restatements.

## The decision

**The agent writes the graph, in its turn, with `knowledge_write`.**

- The workspace system prompt tells it to: write `knowledge_write` when
  the user asks to remember, when a decision is made, or when a
  commitment or an open loop is created; write one concise block; and
  write nothing on a turn that settled nothing.
- A turn with nothing worth keeping writes nothing.  That is the common
  case and the cheap one: no extra call, no block.
- A turn that settles something pays nothing extra either.  The write
  is a tool call inside a turn the agent was already answering, so it
  adds a tool result to that turn's context, not a provider call.

**Nothing reads a finished turn with a second model.**  The per-turn
pass, its four `defcustom`s, its two registry prompts, its model
resolution, its timer, its duplicate scan and the demo provider's
answer to it are removed from `harness-workspace-knowledge.el`.  A
module doc that has to say "when a turn ends, a model reads it" is the
sign the design went wrong; it now says who writes and why no one else
does.

**Topic routing is a separate job and stays separate.**  The router
decides *which thread* a message goes to.  It writes no note and asks
no model: it is an IDF ranking over the threads' own words, with an
optional embedding rerank.  Nothing in this change touches it, and the
design now says so explicitly, because "routing" and "what the turn
leaves behind" are the two things a reader will otherwise conflate.

**What stays as it was:**

- `knowledge_write` (the tool), `knowledge_search`, `knowledge_read`,
  `knowledge_status`, and the module's own write path;
- the day's journal captures of the turns (one block per message, with
  the thread link and provenance) — these are the transcript's presence
  in the graph, not model-written knowledge;
- the thread's `summary` and `next-action` fields, and
  `knowledge/thread-touch`, which writes them to the page when they
  change.  `summary` is the start of the thread's last answer, a copy
  the workspace keeps so a brief can say where the thread stands, and
  `next-action` is a field a client sets;
- the harness's `memory` module and its tools, which still hold the
  small behavioral notes.

## The two promises the write path gained

Removing the scribe exposed two things the docs had already claimed and
the write path did not do.  Both are deterministic — no model, no
judgement — so they cost a map over one page:

1. **A statement is written once.**  `knowledge_write` compares the
   new text with the target page's own blocks, as one line with
   whitespace runs and case set aside, and answers with the block
   already there instead of writing a second copy.  Asking the same
   thing twice is a tool call that writes nothing.
2. **A note holds no secret.**  The write path runs the text through
   `harness-secrets-mask-text` when the secrets module is loaded, so a
   value the redaction layer knows is replaced by its placeholder before
   the block reaches the graph.  A graph is read by a person and
   retrieved by a model; a credential must not be in it.

## Consolidation: bounded, and not required

A model over a whole thread is the one place a model could add
something the agent did not: merge two threads that turned out to be
one, retire a note a later decision superseded, write the paragraph a
person would want to read.  That is not in this change, and no
replacement mechanism is.  What is in the tree is the nightly **dream**,
which asks no model: it rewrites each thread page's identity and state,
keeps one copy of a note written twice, and writes a `Dreams/<date>`
report.

The bound a later, model-backed dream would have to respect is written
down, because the per-turn version broke it:

- **Once a night, not once a turn.**  Per workspace per day, whatever
  the number of turns.
- **Per thread page, not the whole graph at once.**  A page is what one
  topic said; the pass reads a page, so its work does not grow with the
  workspace.
- **Switchable, dry-runnable, and reported.**  `…-knowledge-dream` is
  `nil` or `auto`, `:dry-run` reports without writing, and the result is
  a page in the graph the user already reads.

If a model is added there, it belongs inside those bounds and is a
change of its own.  It does not bring back a pass over every turn.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Keep the scribe and gate it** (only after a "remember" cue, every fourth turn, when a thread parks) | A gate answers *when* to duplicate the work.  The work is still duplicated: the agent wrote the note in the turn, or chose not to.  A "remember" cue reaches the agent long before it reaches a gate, and the turn worth keeping is often the one no rule predicted. |
| **Keep the scribe, tune the prompt and cap the notes** | The caps already existed (`…-scribe-max-notes`, a 300-token answer).  The problem was never the size of one note; it was a call on every turn and a page that grew by reading itself. |
| **Let the dream's model write the notes instead** | The same call with less context: by the next night the turn is a capture in a journal the dream does not read.  There is nothing to consolidate on a page the agent did not write. |
| **No memory writes at all; the captures are the memory** | Then a decision is a line in a journal among hundreds, and nothing states it as the thread's state.  The graph is meant to be read, and a note is what makes it readable. |
| **Have the agent write on every turn** | It writes when it decided something, not on a schedule.  Telling it "always write something" is how a page fills with restatements again. |

## What this costs and what it saves

- **Saved:** one provider call per turn, its latency in the background,
  and its prompt — which grew with the page.
- **Cost:** the agent's write is a tool call inside a turn it was
  answering.  It adds one tool result to that turn's context; it does
  not add a request.
- **The graph gets smaller and more stable**, because a turn that
  settled nothing now leaves nothing on the page.
- **The graph is a little less complete**, and that is the trade: a
  turn the agent judged not worth keeping is not kept.  The captures in
  the journal still hold it, and the user can ask for a note.

## Verification

- `lisp/modules/harness-workspace-test.el`:
  `harness-workspace-a-turn-asks-no-second-model` counts provider
  requests across two turns and asserts two, that the page holds no
  note the agent did not write, and that a `next-action` a client set is
  not overwritten;
  `harness-workspace-a-note-is-written-once` asserts the second write
  of a statement returns the first block's id;
  `harness-workspace-a-note-holds-no-secret` asserts a masked value
  reaches the page as its placeholder.
- `scripts/notes-demo.sh` runs three turns of one workspace and prints,
  per turn, the requests made while it ran and after it ended, then the
  thread's page: two turns leave it empty, the third writes one note
  with its provenance, and the count after every turn is zero.
- `scripts/routing-demo.sh` is unchanged and still prints every score
  and choice, which is the check that routing did not move.
- `docs/modules/` is regenerated (`scripts/module-docs.sh --check`), and
  the full suite passes with no failed suites.

## What is not in this change

- A model-backed consolidation pass (see the bounds above).
- A `knowledge_forget` tool: forgetting is still the user's, in Logseq.
- Provenance in the ACP `knowledge/write` call: the tool call from an
  episode fills `source-session` and `source-node`; a client that calls
  the method directly does not send them.
