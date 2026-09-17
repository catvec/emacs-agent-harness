# 03 — Asynchronous HTTP/1.1 and SSE client

**Status:** completed

## Scope

Asynchronous HTTP/1.1 and SSE client.

## Acceptance criteria

- [x] make-network-process with :nowait t; no blocking anywhere
- [x] Chunked decoding and SSE framing survive arbitrary segmentation
- [x] utf-8-unix on the wire (utf-8 rewrites CRLF)
- [x] Local test server plus parser tests for fragmented input

## Notes

Behaviour and interfaces are described in DESIGN.md; this file only records
that the work is done and what "done" meant.
