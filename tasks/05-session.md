# 05 — Session storage, project link and search

**Status:** completed

## Scope

Session storage, project link and search.

## Acceptance criteria

- [x] One JSONL file per session, appended line by line
- [x] Listing reads only the header, cached against mtime
- [x] SQLite content index with an asynchronous grep fallback
- [x] Working directory per session, defaulting to the project root

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
