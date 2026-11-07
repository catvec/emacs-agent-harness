# Memory storage: SQLite is the source of truth

The memory module (see [the module page](modules/memory.md)) keeps its
memories in `memory.db` in the state directory. There is no
`memories.json` and nothing else they are written to: the database is
the only copy. This page says why, and what it costs.

## Why not JSON

An earlier version of the module kept the memories in `memories.json`
and used `memory.db` as a cache of them: an FTS5 table over the texts,
rebuilt whenever the file's revision counter moved. That is two stores
of the same data and a rule to keep them in step:

- every change wrote the whole file, so a change of one memory rewrote
  every memory, and a crash between the file and the index left the two
  disagreeing until the next search noticed the revision;
- the index had to be rebuilt to answer a search after a restart or a
  restored backup, and the rebuild was the only thing that made a
  half-written file harmless;
- the file was the truth for search but not for the index's vectors, so
  a redaction had to change both, each its own way, and could leave the
  old text in the unused one.

None of that is true of a database that holds the data itself. A change
is one SQLite transaction over the row, its full-text entry (an FTS5
external-content table, kept in step by triggers) and its vectors.
There is no revision, no rebuild, and no way for the stores to
disagree. The FTS5 table is made again from the rows if it is dropped,
and a memory that has no current vector is embedded again when a
semantic search needs it.

## What is stored

`memory.db` holds:

- `memories`, one row per memory: `id`, `scope`, `project`, `kind`,
  `text`, `created`, `updated`, `source`. This is the truth.
- `memories_fts`, an FTS5 external-content table over `memories.text`,
  with triggers for insert, update and delete.
- `vectors`, the int8 quantized embeddings by memory id and text hash,
  for `semantic` search. A deleted memory's vectors are deleted with a
  trigger; a changed one is embedded again by its hash.
- `memories_scope`, an index on scope and project for the page.

The in-memory list the tools and the prompt read is a cache for
reading: every change is written first and the list is read back from
the database in the same call. A block of several changes (`replaces`,
a consolidation, a redaction) is one transaction, so it is applied
whole or not at all.

## Searching without FTS5

FTS5 is an option of SQLite, not of SQLite itself. Where it is missing,
the database still holds the memories and writes work; search filters
the in-memory list in Elisp with the same query syntax. Without SQLite
at all there is nowhere to keep a memory, and a write says so rather
than pretending to save one.

## Redaction

A redaction writes the changed rows, rebuilds the full-text index from
them, merges its segments, VACUUMs the database and empties its log, so
the old text is not left in a page. With one store there is one place
to purge; the JSON version had to purge the file too, and the file was
the copy nothing rebuilt.

## What was rejected

- **Keep the JSON, add an index.** The cache, the revision and the
  two-store divergence are exactly the problem.
- **An append-only JSONL log as the truth, with the database as a
  cache.** Better than a rewritten file, but still two stores, still a
  rebuild after restore, and deleting a memory becomes a tombstone the
  search has to filter.
- **A schema version in a `meta` table.** Not needed while the feature
  is in development: there is no earlier database to migrate. The
  `memories` table is never dropped; the derived tables are rebuilt
  when missing.

## Costs

- The store is no longer hand-editable as text. The memory page, the
  tools and `sqlite3 memory.db` are the ways to it.
- A memory cannot be diffed or copied with the rest of a repository.
  Nothing in the design wants to: memories are per user and per
  checkout, not part of the code.
- SQLite is required, as it already is for usage and the session search
  index. An Emacs without it cannot keep memories.

## Where it lives

The implementation is in `lisp/modules/harness-memory.el`; the schema
and the read/write helpers are in the "Keeping them" and "Full-text
search" sections, and the page that edits the memories is
`lisp/ui/harness-ui-memory.el`.
