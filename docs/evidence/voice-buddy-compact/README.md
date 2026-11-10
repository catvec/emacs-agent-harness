# The compact buddy's pictures

Screenshots of the circle and the two surfaces it appears on, from
`harness_client/test/workspace_screenshots_test.dart` on the committed tree.
Each one is the real widget drawing the real controller after a real backend
event; nothing here is a mocked-up state.

```sh
cd harness_client
HARNESS_SHOTS=/tmp/shots flutter test test/workspace_screenshots_test.dart
```

| Picture | What it shows |
| --- | --- |
| [circle-states.png](circle-states.png) | The same call in five reported states — `Listening`, `Hearing you`, `Speaking`, `Muted`, `Failed` — as the in-call bar draws it.  The ring, its dashes, its weight and the badge change; the word beside them says the same thing. |
| [away-card.png](away-card.png) | The away card on a desktop: circle, workspace, thread, the status and microphone words, `Mute`, `End`, `Details`.  `Start`, `Pause`, `Interrupt`, `Voice settings` and the numeric meter are behind `Details`. |
| [phone-bar.png](phone-bar.png) | The in-call bar on a phone, with the same circle at 28 px.  The workspace is in a call; the card is never drawn on a phone. |

What the pictures do **not** show: any platform window other than the app's
own, any Android or iOS Picture-in-Picture, overlay or Live Activity, and any
real microphone.  The capture paths in the test are the app's fakes.  See
[the design](../../design/voice-buddy-compact.md) for what each phone platform
actually supports and why none of those surfaces is built here.
