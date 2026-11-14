# The speech floor's pictures

The workspace's speech floor where a person meets it: the real workspace
page, with its thread rail, its conversation, the speech band and the
composer under it, on a desktop and on a phone.  Each picture is the page
the app draws, from a real floor record; the playback behind it is the
scripted engine the tests hand it, not a sound anyone heard (see below).

## Flutter

```sh
cd harness_client
HARNESS_SHOTS=/tmp/shots flutter test test/workspace_speech_screenshots_test.dart
```

The cases drive `WorkspaceScreen` itself, not the band alone, so every
picture shows where the floor sits in the page and how much room it takes
from the conversation.

| Picture | What it shows |
| --- | --- |
| [desktop-solo.png](desktop-solo.png) | A desktop with a solo: the band between the chat and the field, `Kitchen renovation 4s 2 waiting` with `Skip` and `Hold`, two waiting threads with their words and their own `Solo`, and `Solo · Kitchen renovation` with `Leave` -- every action on the band's one right-hand edge. |
| [desktop-populated.png](desktop-populated.png) | The same page with a queue and nothing held back: two waiting threads, each with its own `Solo` under the speaker's `Hold`, and no solo line. |
| [desktop-held.png](desktop-held.png) | The floor held: an amber dot and `Held · Kitchen renovation 4s 1 waiting`, with `Skip` and `Resume`. |
| [desktop-crowded.png](desktop-crowded.png) | Five waiting threads behind a long-named speaker: the speaker's name and every row ellipsize, and the rows stay compact -- the six `Solo` buttons still hold the one column under `Hold`. |
| [desktop-narrow.png](desktop-narrow.png) | The same floor at 900 points wide: the rail and the conversation narrow, and `Skip`/`Hold`/`Solo` keep the same right-hand column. |
| [desktop-scale-150.png](desktop-scale-150.png) | The same page at 150% text: the rows grow and nothing clips. |
| [phone-solo.png](phone-solo.png) | A phone's strip: `Kitchen renovation`, `Solo`, `2 waiting` and `Skip` on one line, above the composer. |
| [phone-held.png](phone-held.png) | The phone's strip on a held floor. |
| [phone-sheet.png](phone-sheet.png) | The phone's queue sheet: the speaker with `Skip` and `Hold`, `2 waiting`, and each thread with its own `Solo`. |

## Emacs

| Picture | What it shows |
| --- | --- |
| [speech-waiting.png](speech-waiting.png) | The left side panel of a live development harness, on a floor the harness itself held: `Speech · 2 waiting`, `Speaking · Kitchen renovation` with `Hold` and `Skip`, and both waiting threads with `Solo`, drawn from the harness's own answer to `workspace/speech`. |

The Emacs panel's other states are held to their exact words by
`lisp/ui/harness-ui-workspace-speech-test.el` rather than by a picture:
the solo line and `Leave solo`, the held line with its position and
`Resume`, the recent entries, and every tooltip.  No second live capture
was taken, because the sandbox this task ran in has no display of its
own.

## Where it sits, and what it costs

The band is not a card laid over the chat.  It is the last row of the
chat column, between the conversation and the message field, with the
composer's own fill and one hairline above it, so it reads as part of the
page.  On a phone it is a one-line strip in the same place, with the
queue behind a tap.

The room it takes is the room its rows need: a speaker line and one line
per waiting thread, no heading of its own, no fixed height, and nothing
at all when the floor has nothing to say.  With two threads waiting it is
about 120 points of a 900-point desktop; with five, about 200 -- which is
why the crowded picture is there.

Every row's actions end on one edge, the band's: `Skip` and `Hold` on the
speaker's line, a waiting thread's `Solo`, and the solo line's `Leave`.
The column is the widest row's buttons, so `Solo` sits under `Hold` and
not under `Skip`, at 100% and at 150% text alike; a name too long to fit
beside it ellipsizes rather than pushing the column.

## What the pictures do not show

No audio was played.  The Emacs speaker and the Flutter player were
exercised with the harness's real floor and a scripted speech engine: the
queue, the claim, the advance, the hold and the interruption are the real
code paths, but the sound is not.  Nothing here is from a phone, a
microphone or a real TTS device; see
[the design](../../design/workspace-speech-queue.md) for what each client
promises and what it cannot.
