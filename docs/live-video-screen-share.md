# Live camera and phone screen sharing

The Flutter client can put a camera or the phone's screen beside the
workspace call, send a still to the conversation, and — only when the
provider's own answer accepts it — carry a live video track.  This page
is the design record: what is real, what a provider must support, which
transport was chosen and why, the bounds, and what remains unverified.

The rule the whole feature follows: **the screen never says `live` for
bytes nobody is receiving.**  A provider that takes no track and no frame
gets a disabled control and a noun that says why.

## Theory of operation

```text
 camera / phone screen
        │  OS consent (Android MediaProjection, camera permission)
        ▼
 MediaCaptureSession  (one visual source, one track, bounded frames)
        │
        ├── WebRTC video track ──► a provider whose SDP answer accepted
        │                          a sendonly video m-line
        │                          (`Camera live`, `Screen live`)
        │
        ├── sampled still ───────► a realtime provider that documents image
        │   (≤ 1/s, 180 KiB)       input (`Camera frames · 1/s`), as a
        │                          provider-specific data-channel message
        │
        └── one press ───────────► the workspace session, as an ACP
            (`Frame to chat`)      `session/prompt` image content block
                                   (`Camera preview`, local preview only)
```

Four independent facts decide what a person sees:

1. **What the device can capture.**  Camera and screen on Android;
   camera on iOS (screen needs a broadcast extension this app does not
   have); camera and screen on macOS, Windows and Linux; nothing on the
   web build, whose `flutter_webrtc` frame capture is native-only.
2. **What this build can take from that source.**  `captureFrame` is
   native only, so the browser offers no capture control at all rather
   than a track that could never become a bounded frame.
3. **What the live provider accepts.**  Learned from the SDP answer:
   the answer's direction for the two sendonly video transceivers is
   `tracks`; a `media.frames` member in the answer object is `frames`.
   If the answer accepts a video m-line but the sender refuses the track,
   the camera is stopped and the bar says `No video · track refused`.
   OpenAI's Realtime API documents image input but no video tracks;
   GPT-Live-1 documents image **and** video as unsupported.  Neither is
   guessed from the host name alone.
4. **What the session takes.**  The harness answers `session/media` with
   the receiving method (`session/prompt`), the image block it accepts,
   the frame bounds and whether the session model reads images.  A
   harness old enough not to answer says so, and no frame control is
   offered.

The capture session is explicit and one-at-a-time: starting the screen
stops the camera, starting the camera stops the screen, and every path
out (End, Minimize, a new call, a permission taken back, the app going
to the background) stops the track and the preview.  Nothing resumes by
itself after the app comes back; a source is started only by a press.

`Frame to chat` is always a person's press.  It is never a timer over a
paid turn.  `Camera frames · 1/s` is the only sampling loop, and it runs
only while a provider has said it accepts sampled frames; it sends a
still, not a track, and does not ask the model for a response.

## Where it lives

| Piece | File |
| --- | --- |
| Source, state, bounds, frame encoding, lifecycle, delivery vocabulary | `harness_client/lib/src/media/media_capture.dart` |
| flutter_webrtc camera/screen capture, temp-frame deletion, Android foreground service seam | `harness_client/lib/src/media/media_capture_webrtc.dart` |
| Session capability model | `harness_client/lib/src/models/session_media.dart` |
| `session/media` server answer | `lisp/modules/harness-session.el` |
| ACP image block for a frame | `harness_client/lib/src/state/session_controller.dart` |
| WebRTC offer/answer, transceiver acceptance, frame messages, backpressure | `harness_client/lib/src/services/voice_webrtc.dart` |
| Backend seam (`attachCapture`, `detachCapture`, `sendCapturedFrame`) | `harness_client/lib/src/voice/voice_backend.dart`, `live_voice_backend.dart` |
| Controller state, sampling, preview, stop, pause | `harness_client/lib/src/voice/voice_controller.dart` |
| The bar, status, preview and exact copy | `harness_client/lib/src/ui/widgets/voice_media_bar.dart` |
| One-step stop in the in-call bar, and in the desktop buddy behind `Details` | `workspace_call_bar.dart`, `workspace_buddy.dart` |
| App-wide capture session and lifecycle hook | `app_controller.dart`, `app.dart` |
| Android MediaProjection foreground service | `android/app/src/main/kotlin/.../ScreenShareService.kt`, `MainActivity.kt` |

The old voice, workspace, VNC and pipeline paths are untouched except for
the seam: `VoiceBackend` gained media methods with no-op defaults, and
`VoiceController` gained a capture it may be given.  A scripted backend
that knows nothing of video keeps working.

### The compact away card

The away card was later cut down to a glance — circle, status word,
microphone word, `Mute`/`End` and a `Details` disclosure (see
[voice-buddy-compact.md](design/voice-buddy-compact.md)).  The live
source's stop is one of the controls behind `Details`, with `Pause`,
`Interrupt` and `Voice settings`; the glance itself keeps no media
control.  The in-call bar is unchanged in this respect and keeps its own
stop beside `Mute`, because that bar is at every width and is not the
glance.

## Receiving endpoints and protocols

There is **no video-track sink in the harness**.  `session/media` says so
explicitly (`:realtime nil`, `:realtime-reason "no-media-sink"`), and the
client never draws a continuous-video state for the workspace.  VNC is a
remote desktop view, not an input path for the phone's camera.

| Receiver | Protocol | What it gets | When it is real |
| --- | --- | --- | --- |
| Workspace session / its model | ACP `session/prompt` with a text block and one `image` block (`mimeType`, base64 `data`, `_harness.label`) | One still per press | Implemented; harness accepts image blocks, and `session/media` advertises vision and bounds |
| OpenAI Realtime (`gpt-realtime*`, `gpt-4o-realtime*`) | WebRTC data channel, `conversation.item.create` with one `input_image` part | Sampled stills, ≤ 1/s, no `response.create` | The message shape and model gate are tested; a live key/provider run is not |
| A generic WebRTC sidecar | The two sendonly video m-lines in the SDP offer; a JSON `frame` message (`protocol: 1`) on the data channel | A live track per source when the answer accepts it; optional stills when the answer says `media.frames` | Client negotiation is tested with fakes; no harness sidecar accepts video today |
| GPT-Live-1 | Audio only | Nothing | Its model page lists image and video as unsupported modalities |

`session/media` returns:

```json
{"session":"s-1","endpoint":"session/prompt","images":true,
 "realtime":false,"realtime-reason":"no-media-sink",
 "frames":{"supported":true,"max-bytes":184320,"max-width":640,
           "max-height":360,"max-per-minute":30,
           "mime-types":["image/png","image/jpeg"]},
 "model":"provider:model","vision":true,"reason":null}
```

`vision` is `true`, `false` or `unknown` (no provider module or no
capability answer).  Unknown is offered with `Vision unconfirmed`; false
is not offered (`No video · voice model`).  The harness answers this
without calling a model, so asking is free.

## Why WebRTC

The live audio path already uses WebRTC, and one transport that carries
audio and video together is the only one that can put a camera frame next
to the spoken word without inventing a second clock.

| Option | Latency | A/V sync | Bandwidth and adaptation | Encoding placement | Backpressure / recovery | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **WebRTC tracks** (chosen) | Interactive; RTP/RTCP with jitter buffer and NACK/PLI; typically well under a second on a LAN and a few hundred ms over the internet | One transport for both; RTCP sender reports give a common clock, so the far end can align audio and video | GCC congestion control, simulcast/bitrate adaptation by libwebrtc, DTLS/SRTP; no app-level rate loop | Device's libwebrtc encodes (VP8/H.264/VP9 depending on platform); no server transcode in this app | ICE restart/reconnect and `replaceTrack` give a clean source switch; `bufferedAmount` exposed for the data-channel path; stopping the track stops the camera | **Chosen for continuous tracks.** It is the only candidate that already exists in the voice path and preserves sync. |
| WebSocket/WebTransport with stills or encoded chunks | One RTT plus decode; no jitter buffer unless built | None built in; the app must timestamp and align | App owns pacing and congestion; no standard bandwidth estimate; head-of-line blocking on a reliable stream | App encodes every frame; server may transcode | App must implement reconnect, queue bounds and cancellation | Rejected for tracks. The ACP path already uses a request per still; that is enough for `Frame to chat`. |
| RTSP/RTP to an SFU | Low on a LAN | RTP timestamps give sync | RTCP feedback, but no browser-native stack | SFU may transcode/forward | Needs a separate signaling and ICE path | Rejected: another stack, another port, no Flutter support without native work. |
| HLS/DASH | Segment latency is seconds, not interactive | Segment boundaries, not lip sync | ABR by segment | Server transcodes | Player handles retry but not interactivity | Rejected: not a conversation transport. |
| MJPEG over HTTP | Per-frame request/decode; can be low on a LAN | None without a side channel | Every frame is independent; JPEG quality is the only knob | Client or server encodes JPEG | Simple retry, no shared congestion signal | Rejected for tracks; the still path is a bounded version of the same idea. |
| WebRTC data-channel images (chosen for stills) | One message, ordered and reliable; the measured app cost is below | N/A (a still) | 180 KiB encoded bound; 1/s; `bufferedAmount` cap | App encodes PNG; no server transcode | Ordered SCTP; explicit `channel busy` drop | **Chosen for providers whose documented input is images.** It is a still, named as a still in the UI. |

Evidence for the provider claims:

- OpenAI's [gpt-realtime announcement](https://openai.com/index/introducing-gpt-realtime/)
  says the Realtime API now supports image inputs.  A
  [WebRTC field report](https://webrtchacks.com/how-openai-does-webrtc-in-the-new-gpt-realtime/)
  notes that 1 FPS is the practical lower bound for browser capture, which
  is why sampled frames are capped at one per second.
- OpenAI's [GPT-Live-1 model page](https://developers.openai.com/api/docs/models/gpt-live-1)
  lists image and video under unsupported modalities and `v1/realtime`
  as unsupported.  The client therefore never claims frames or tracks for
  that model.
- The [Realtime conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations)
  documents image content parts in `conversation.item.create`, which is
  the message `openAiFrameMessage` builds.
- WebRTC's media and data-channel behavior is specified in
  [RFC 8825](https://www.rfc-editor.org/rfc/rfc8825) (overview),
  [RFC 8834](https://www.rfc-editor.org/rfc/rfc8834) (media transport) and
  [RFC 8831](https://www.rfc-editor.org/rfc/rfc8831) (data channels).
  Congestion control is libwebrtc's, not this app's.
- Android's requirement that a `MediaProjection` run inside a foreground
  service of type `mediaProjection` is documented by Android and is the
  reason for `ScreenShareService`; the flutter_webrtc issue
  [#1521](https://github.com/flutter-webrtc/flutter-webrtc/issues/1521)
  records the crash without it.

### Feature negotiation

The client offers two sendonly video transceivers in every generic offer,
with no track attached.  It reads `getCurrentDirection()` after the
answer: `sendonly` or `sendrecv` means accepted; anything else means the
provider took no video.  A track is attached only after that.  This
avoids both a false offer and a renegotiation for the first source.

For OpenAI's Realtime endpoint the client knows from the model gate that
tracks are never available, so it does not add a video transceiver; it
asks for frames in the data channel and reads nothing else.

### Backpressure, reconnect and cancellation

- **Backpressure.** Tracks are paced by libwebrtc; the app adds no queue.
  A still is refused when the data channel's `bufferedAmount` plus the
  base64 message would exceed 2 MiB (`liveFrameFitsBackpressure`), so a
  slow far end drops a frame instead of growing a queue.  The sampling
  loop also holds one capture at a time (`_sampling`).
- **Reconnect.** WebRTC ICE and DTLS are libwebrtc's.  The existing live
  backend's stop/start path closes the peer, detaches the track and
  releases the camera; a new call negotiates again.  There is no
  mid-call ICE restart button in this change.
- **Cancellation.** `stopMedia` stops the sampling timer, the preview
  timer, detaches the sender (`replaceTrack(null)`), stops the capture
  track and, for the screen, stops the Android foreground service.
  `VoiceController.end`, `updateSettings`, `retry`, `dispose` and the
  app's lifecycle hook all call it.
- **Lifecycle.** `AppController` forwards every `AppLifecycleState`;
  background/hidden/detached stops a live source and records
  `suspended`; resumed does not start one.  A source that needs the app
  in front is marked `foregroundOnly` in the capability.

## Bounds and cost

| Bound | Value | Enforced by |
| --- | --- | --- |
| Sent frame size | 640 × 360, downscaled to fit 180 KiB | `CaptureBounds`, `MediaCaptureSession.captureFrame` |
| Preview | 320 × 180, ≤ 120 KB, in memory only | `CaptureBounds`, `_previewOnce` |
| Sampling rate | 1 frame/s (`sampleInterval`), provider cap `maxFps: 1` | `_startSampling` |
| Frames per minute | 30, counted in a rolling minute | `_frameTimes` |
| Track | 15 fps at up to 640 × 360 requested; libwebrtc adapts | `CaptureBounds`, `startVisual` |
| Data-channel queue | 2 MiB | `liveFrameFitsBackpressure` |
| Model turns | None started automatically | `Frame to chat` is a press; sampled frames do not send `response.create` |

The 180 KiB bound is chosen so the base64 JSON message stays under the
256 KiB message size a portable WebRTC data channel accepts.  PNG is used
because `dart:ui` encodes it without a second codec; a photograph-like
frame is downscaled until it fits, while a flat screen frame keeps
640 × 360.  JPEG would keep more resolution at this size and is the next
step; the harness and `session/media` already accept `image/jpeg`.

## Measurements

`harness_client/test/media_benchmark_test.dart` runs on this machine, with
synthetic pixels (no camera, no screen), and prints real timestamps:

```text
MEDIA-BENCH summary frames=3 p50_ms=135 p95_ms=156 max_png_bytes=162819 max_json_bytes=217253
MEDIA-BENCH frame=0 app_ms=156 png_bytes=162819 json_bytes=217253 size=364x205
MEDIA-BENCH screen app_ms=18 png_bytes=1817 size=640x360
```

The first case is 1280 × 720 noise — a worst case for PNG — so it lands
at 364 × 205 and 162,819 bytes.  The second is a flat screen-like frame:
it keeps 640 × 360 at 1,817 bytes.  Both are the app's own work (decode,
scale, encode, base64 JSON), not network or provider latency.  A test
asserts the measured cost stays under five seconds, which is a runaway
cap, not a target.

## Compatibility matrix

| Client platform | Camera | Screen | Notes |
| --- | --- | --- | --- |
| Android phone/tablet | Yes, while the app is in front | Yes, with system MediaProjection consent and the app's own foreground-service notification | `CAMERA`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`; camera and screen each request permission on first use |
| iOS | Yes, camera permission | No | Screen needs a broadcast extension; the tooltip says `Screen · needs a broadcast extension` |
| macOS | Yes, camera entitlement and usage string | Yes, where the OS grants screen recording | Camera entitlement in debug and release |
| Windows/Linux desktop | Yes, where flutter_webrtc can open the device | Yes, where `getDisplayMedia` is supported by the platform | No additional manifest permission in this change |
| Web | No | No | `flutter_webrtc` frame capture is native-only; the app says unavailable rather than offering a track it cannot sample |

| Provider / receiver | Track (continuous) | Still frame | UI |
| --- | --- | --- | --- |
| OpenAI Realtime (`gpt-realtime*`, `gpt-4o-realtime*`) | No | Yes, `input_image` ≤ 1/s, no automatic response | `Camera frames · 1/s` / `Screen frames · 1/s` |
| GPT-Live-1 | No | No (image and video unsupported) | `No video · voice model` |
| A generic WebRTC sidecar that accepts a sendonly video m-line | Yes | Only if its answer has `media.frames` | `Camera live` / `Screen live` |
| Workspace session whose model reads images | No | Yes, one per press via `session/prompt` | `Camera preview` + local preview + `Frame to chat` |
| Harness without the `session/media` extension | No | No | control disabled; `Frame to chat · harness not ready` |
| Model without vision | No | No | `No video · voice model` |
| Vision unknown | No | Offered with a warning | `Vision unconfirmed` |

## Privacy and security

- **Explicit opt-in per source.**  Pressing `Camera` or `Screen` is the
  only way a source starts.  Android shows the system MediaProjection
  consent and this app's own `Screen share` foreground notification;
  camera uses the normal runtime permission.
- **No secret capture.**  The app never starts a source from a timer, a
  lifecycle resume, or a remote request.  Backgrounding stops it.
- **No raw media kept by default.**  A frame lives in memory for the
  capture that needs it.  flutter_webrtc writes `captureFrame.png` to
  the cache; the adapter deletes that one file immediately after reading
  it.  The preview is memory only and is dropped on stop.  There is no
  recording feature in this change.
- **What leaves the device.**  A track leaves through DTLS/SRTP to the
  provider that accepted it; a still leaves as base64 in a data-channel
  message or an ACP image block.  Both carry the source label
  (`Camera frame` / `Screen frame`) so the conversation says what it saw.
- **No recursive share by default.**  The phone screen share can include
  the app itself if the person leaves it in front; the app does not
  attempt to hide or crop its own window.  The Android notification names
  the capture for as long as it runs.
- **Tests capture nothing.**  Every test uses a scripted platform and
  synthetic pixels; none opens a camera, a microphone or the screen.

## Tests and evidence

| What | Test |
| --- | --- |
| Permission denial, pause, lifecycle stop, revoked permission, one source at a time, bounds, preview, microphone ownership | `harness_client/test/media_capture_test.dart` (10) |
| Track delivery, frame delivery, one-press workspace frames, no-delivery release, pause/resume, end stops capture, a refused track | `harness_client/test/voice_media_test.dart` (8) |
| Exact copy: every state, tooltips, disabled frame control, denied camera, frame limit, unknown vision, preview | `harness_client/test/voice_media_bar_test.dart` (8) |
| Session capability parsing and unknown/no-vision states | `harness_client/test/session_media_test.dart` (4) |
| Frame messages: OpenAI image part, no `response.create`, generic shape, backpressure | `harness_client/test/media_frame_protocol_test.dart` (4) |
| Backend seam: frame provider, refusal, detach on stop | `harness_client/test/voice_live_media_test.dart` (3) |
| A frame is one ACP image block in the real session controller, not an audio block | `harness_client/test/voice_session_test.dart` (`a frame is one ACP image block and never an audio block`) |
| `session/media` answer and extension method | `lisp/modules/harness-session-test.el` (`harness-session-media-answers-the-frame-endpoint-and-bounds`, `harness-session-media-is-an-acp-extension-method`) |
| Pictures of the real widget with real fonts | `harness_client/test/media_screenshots_test.dart`, `HARNESS_SHOTS=screenshots` |
| App-side timings (two synthetic frames) | `harness_client/test/media_benchmark_test.dart` (2) |
| `ACCESS_NETWORK_STATE` is declared, so libwebrtc cannot abort a call | `harness_client/test/build_config_test.dart` (`the permissions libwebrtc reads at runtime are declared`) |
| The local receiver answers every signalling path, accepts both video m-lines, decodes a frame and takes a still | `harness_client/e2e/test_media_receiver.py` |

Reproduce:

```sh
scripts/test.sh lisp/modules/harness-session-test.el
cd harness_client
flutter test test/media_capture_test.dart test/voice_media_test.dart \
  test/voice_media_bar_test.dart test/session_media_test.dart \
  test/media_frame_protocol_test.dart test/voice_live_media_test.dart \
  test/voice_session_test.dart test/media_benchmark_test.dart
HARNESS_SHOTS=screenshots flutter test test/media_screenshots_test.dart
python3 -m venv /tmp/media-venv && /tmp/media-venv/bin/pip install aiohttp aiortc
/tmp/media-venv/bin/python e2e/test_media_receiver.py
python3 e2e/media_emulator.py --phase capture --only camera \
  --sdk "$ANDROID_HOME" --dart "$(command -v dart)" \
  --flutter "$(command -v flutter)" --python /tmp/media-venv/bin/python
```

The last one needs an Android SDK, an emulator and minutes of wall
clock; the one before it runs in seconds and is the part that can be
checked on its own.

The pictures are `screenshots/media/phone-camera-ready.png`,
`phone-camera-live.png`, `phone-camera-paused.png`,
`phone-vision-unsupported.png` and `desktop-screen-frames.png`.  They are
fixtures: a scripted capture platform, a scripted backend and synthetic
frame bytes.  They show the real widget, copy and layout; they are not a
photograph of a device or a provider.

## What is verified, and what is not

Verified here:

- The capture state machine, bounds and cleanup, with a scripted platform.
- Capability parsing and the server's `session/media` answer.
- The WebRTC frame message shapes, model gate and backpressure
  arithmetic, and the backend seam that attaches and detaches a track.
  The offer/acceptance code needs a real peer connection and is built
  but not exercised by a test here.
- The ACP image block a `Frame to chat` press sends, through the real
  `SessionController` and fake harness.
- Exact rendered copy for the media bar, including every state and
  tooltip.
- Screenshots at phone and desktop sizes, with real fonts.
- Local app-side timings.
- A phone-sized call view that carries a pending turn and a problem
  notice lays out without overflowing: the orb yields to what the status
  and notices leave rather than holding a floor of its own
  (`voice_pending_speech_test.dart`, `pending limit renders its exact
  failure without clipping the draft`).

Not verified here, and honest limits:

- **No provider was used, and no real frame was decoded on a device.**
  A real Android 14 emulator drove the APK against a local receiver (see
  below), which proved signalling, DTLS and the data channel on a guest;
  its own camera pipeline could not start under software emulation, so
  the screenshots and the frame bytes are still synthetic.
- **No harness or provider accepts a continuous video track today.**  The
  client negotiates it and shows `live` only when an answer accepts it;
  that branch has fake-connection tests but no live endpoint.  A user
  with such a sidecar can use it.
- **The Android foreground service has not run successfully.**  A device
  showed it being refused and killing the app, which is fixed; no run has
  yet started it after a real consent, so the notification and the
  backgrounded-share behaviour are still unproven.
- **OpenAI realtime image input is not exercised with a key or a
  network.**  The message shape and model gate are tested; the provider
  may impose its own size or moderation limits.
- **A track from the far end is not rendered.**  This change sends video
  only; the app has no incoming video view.
- **JPEG is not produced.**  Frames are PNG, so a photograph is
  downscaled more than a JPEG would need.  The receiving side already
  accepts JPEG.
- **No mid-call ICE restart.**  A broken peer is ended and restarted by
  the normal call path, not repaired in place.
- **The web build offers no capture.**  A browser frame path would need
  a validated capture and decode seam.
- **Audio while screen sharing.**  The voice microphone continues; the
  screen capture asks for video only (`audio: false`) and does not mix
  device audio.

## On a real Android guest

`harness_client/e2e/media_emulator.py` drives the real APK on a
disposable Android 14 emulator against `media_receiver.py`, a local
aiortc peer, and records every step to `run.jsonl` with screenshots.
The guest has no KVM, so it runs under TCG software emulation and a
boot takes minutes; that is the reason a run is one long command.

What a run proved on the device, with the evidence beside it:

| Step | What the run saw |
| --- | --- |
| The app offers a call | `offer` in `receiver.jsonl`: 3 video m-lines, 1 audio |
| The answer is accepted | the app's `sdp_offer_answer` goes `stable -> have-local-offer`, then applies the answer |
| ICE and DTLS | `dtls_transport.cc: DTLS handshake complete`, `onConnectionChangeCONNECTED` |
| The data channel | `data-channel label=harness-voice`, then `{"type": "start"}` |
| The media bar | `Camera starting` / `Camera off`, tapped by the layout the screenshots show |

Four bugs the device found, and what they were:

1. **The app aborted as a call started.**  libwebrtc's
   `NetworkMonitor` reads `ConnectivityManager` for the active network,
   and its JNI does not catch the `SecurityException` a missing
   `ACCESS_NETWORK_STATE` raises: `jvm.cc` `Check failed: false`, then
   `Fatal signal 6`, the whole process.  Voice mode died this way too,
   before this change, because the permission was never declared.  It
   is declared now, and `test/build_config_test.dart` reads the
   manifest so it cannot be dropped again.
2. **The receiver answered only three paths.**  The client posts its
   offer to whatever address the Live provider names, and the run uses
   `/voice`; every offer got a 404 that read like a provider refusing
   video.  Every documented path answers now, and
   `test_media_receiver.py` asks all of them.
3. **The receiver encoded a PNG per frame on its event loop.**  That
   starved the sender's STUN consent checks and the peer was torn down
   as unreachable minutes into a share -- which looks exactly like a
   client that stopped sending.  Only the first frame and the last are
   encoded now, the last when a run asks for the summary.
4. **Screen sharing crashed the app.**  The `mediaProjection` foreground
   service was started before the projection was granted, which Android
   14+ refuses, and the refusal was uncaught on the main thread: the
   process died and the call with it.  See the next section.

What the device did **not** prove, and why:

- **No video frame was decoded from the camera or the screen on the
  guest.**  The bar reached `Camera starting`, then the system showed
  `Process system isn't responding`: the emulator's own camera pipeline
  cannot start under TCG at this speed, so the capture never produced
  a frame to send.  The track, the answer and the transport around it
  are real; the pixels are not.
- **Media must go to the host's LAN address, not its loopback.**  The
  ACP socket is TCP and travels through `adb reverse`; RTP is UDP and
  cannot.  A run seeded with `127.0.0.1` logged
  `Binding request timed out from 127.0.0.x` and the call failed --
  a test-harness address, not a client defect.  The driver uses the
  machine's own address for media and loopback only for ACP.
- **The accessibility tree cannot be polled while a track is live.**
  A dump is a guest process and a full traversal; asking every few
  seconds starves the app's network stack until ICE consent fails.  The
  driver taps the layout and reads the receiver, which is the only
  place a delivered frame exists.
- **No real provider, key or paid call.**  The far end is a local
  aiortc peer; no model was asked anything.

The run is not a test that can pass in CI: it needs an Android SDK,
an emulator and minutes of wall clock.  It is the evidence, and
`e2e/test_media_receiver.py` is its checkable half -- it runs in
seconds and exercises the answer, the acceptance, the data channel and
a decoded frame.

### Screen sharing: a crash the camera path never reached

The screen scenario found a bug the camera one could not, because the
camera pipeline fails before it gets this far.  Tapping `Screen`
killed the app:

```text
java.lang.SecurityException: Starting FGS with type mediaProjection
  callerApp=... targetSDK=36 requires permissions: all of
  [android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION] any of
  [android.permission.CAPTURE_VIDEO_OUTPUT, android:project_media]
  at app.harness.harness_client.ScreenShareService.onStartCommand
```

Two faults, both fixed:

1. **The order was wrong.**  The app started the `mediaProjection`
   foreground service and only then asked for the projection.  On
   Android 14+ the `android:project_media` app-op the grant creates is
   required *before* `startForeground` may declare the type, so the
   service was refused every time.  The projection is now asked for
   first and the service starts once the person has granted it --
   `getDisplayMedia` does not return until they answer, so that is the
   one point where the grant is known.
2. **The refusal killed the process.**  `startForeground` throws from
   the service's `onStartCommand`, on the main thread, and nothing
   caught it: the whole app died and the voice call with it.  The
   service now catches it and stops itself, so a refused service is a
   screen that is unavailable rather than an app that is gone.

`test/media_screen_order_test.dart` pins the order.  It fails against
the old code -- the recorder sees `foreground-start` before `consent`
-- and passes with the fix; that was checked by reverting the order
and running it.

**What the device did not confirm.**  The rebuilt APK was installed,
but that run's guest never brought the app to the front (it had been
through many boots and was ANR-ing), so the screen step was not
reached and the fix has not been re-confirmed on a device.  What is
established is the failure itself -- the `SecurityException` above,
from the guest's own log -- and that the code that caused it now
does the two things Android requires instead.
