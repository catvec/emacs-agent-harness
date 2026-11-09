# Tool-result pictures, kept as the tool saw them

## The problem

A tool may hand the model a picture: `read_file` on an image returns its
file as the result's `:images`. The transcript keeps the *paths*, never
the bytes, and every request re-reads those files to make the
`tool_result` block ready for the provider.

A screenshot is written over the same path every time. When one is
taken after the model has already read that path, the next request
sends the new bytes in an *old* result. Two things break at once:

- the model is shown a picture it never got, under the result of an
  earlier call;
- the request differs from the one the provider cached at that result,
  so every token after it is read fresh. The prompt still reads 90%
  cached, and the last 10% is paid for again.

That is what the "Make harness architecture device-aware" task paid:
`scripts/dev.sh shot scripts/.dev/computers-page.png` overwrote a
screenshot twice, each overwrite was followed by a request that re-read
the old result, and the chat got two `Prompt cache miss · 90% cached ·
2 calls · 67.1k tokens re-sent` hints (transcript lines 1771 and 1979).
The same session's images were well under the 16-image history cap, so
the cap was not involved.

## The decision

Copy the picture once, when the result is recorded, and send the copy.
The node keeps both names:

```elisp
(:images ((:path "/abs/scripts/.dev/computers-page.png" :mime "image/png"
          :snapshot "/…/sessions/ID.images/<sha1>.png")))
```

- `:path` is the file the tool named: what the user opens, and what the
  chat's `:attachments` show.
- `:snapshot` is the copy `images/keep` made at record time, named by
  the SHA-1 of its bytes in `sessions/<session-id>.images/`. Two results
  of the same picture share one file; the name follows the content, so
  it never changes under a result.
- `session/messages` passes both through to the `tool_result` block; the
  agent reads `:snapshot` (`images/file`) and falls back to `:path` only
  when the copy cannot be read.
- The transcript still holds paths and never bytes, which is what kept
  the state directory manageable before.

The picture is kept for every model, not only one that reads images: a
session can switch to a vision model later, and the result should still
show the picture the tool returned then.

`harness-images-max-bytes` (16 MiB, above any image a provider takes)
caps a copy; a larger file, a gone file or one that cannot be written
leaves no `:snapshot`, and requests read the file exactly as before.

## Alternatives

- **Keep the bytes in the node.** Simplest, but the node log is appended
  JSON lines and the UI, search index and forks all read it; doubling
  every screenshot into it is the thing the transcript was designed to
  avoid.
- **Verify a hash of the file and send a "gone" note when it changed.**
  No bytes stored, but every screenshot overwrite still breaks the cache
  once, which is the reported problem; and the model loses the picture.
- **Keep request payloads for image-bearing sessions** (the replay
  mechanism). It would make the prefix byte-identical, but payloads of
  pictures are large, are written on every step, and the image cap would
  have to be re-applied to a payload that must stay as it was. The
  replay module deliberately refuses a payload with image bytes.
- **One content-addressed store for the whole harness, no cleanup.**
  Forks and renames would be simple, but nothing would ever remove a
  copy; the session is the natural owner, and deleting a session already
  deletes its node log.

## Shape of the change

| Where | What |
| --- | --- |
| `lisp/modules/harness-images.el` (new) | `images/keep`, `images/file`, the copy store, `harness-images-max-bytes`, removal on `session/deleted`; in `harness-core-modules` |
| `harness-agent.el` | `harness-agent--keep-result-images` runs before the result is recorded; `result-images`, `prepare-result` and `hosted-images` know `:snapshot` |
| `harness-session.el` | `harness-session--result-images` carries `:snapshot` into the request block |
| `harness-cache.el` | a good read clears the streak but not `:alerted-at`, so the documented cooldown holds across it |
| tests | `lisp/modules/harness-images-test.el`, the agent image suite's changed-file/spread/deletion/fallback cases, and the cache cooldown |

The cache-health change is small but belongs here: the device-aware
session alerted twice 65 seconds apart because a single good read erased
the record that held the cooldown. A session that keeps missing should
say so once in `harness-cache-health-cooldown`, which its docstring
already promised.

## Limits

- A user message that attaches a picture by `:path` (rather than by
  `:data`) is still read when the request is made; its file is usually a
  clip with a name of its own.
- Results recorded before this change have no copy; they keep reading
  their files until they leave the transcript.
- A fork copies its parent's nodes, copies and all; deleting the parent
  takes its pictures, and the fork then falls back to the named files.
- Copies live until the session is deleted. They are content-addressed,
  so repeated reads of the same screenshot cost one copy.
