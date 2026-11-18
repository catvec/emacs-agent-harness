# Android resume latency: where the wait goes, and what the app says meanwhile (2026-11-14)

**What was reported.**  The Flutter client on the phone does connect eventually, with no error, but going back into a session after the app has been away is slow, and while it happens the app says almost nothing.  This document measures where the time goes and says what changed.

**What is not claimed.**  Nothing here is evidence of a bad saved endpoint or a refused credential: the phone reached the harness, the listener answered, and the app did connect by itself.  No setting, credential, permission policy, provider pin or queue hold is touched.

## 1. The path a resume takes

`AppLifecycleState.resumed` calls `AppController.resumed()`, which calls `setForeground(true)` and then `checkConnection()`.  Before this change:

| Step | Code | Bound before |
| --- | --- | --- |
| Probe the connection that looks open | `client.probe()` | `probeTimeout`, 5 s |
| Open the socket (WebSocket) | `WebSocketAcpTransport.connect` | 15 s |
| Open the socket (plain TCP) | `Socket.connect` | none |
| `initialize` | `client.initialize` | 12 s |
| `authenticate` (TCP, secret) | `client.authenticate` | 5 min |
| `initialize` again after sign-in | `client.initialize` | 12 s |
| `session/list` | `refreshSessions` | 5 min |
| `insights/projects` and `project/mains` | `refreshProjects` | 5 min |

The first bound is the one a person meets first, and it was the wrong way round: a phone that was asleep holds a socket that died without a word, and the app spent the full five seconds of the probe waiting for an answer that could not come, with the phase still `connected` -- so not even the reconnecting banner showed.  Only then did it start to reconnect.

## 2. What was measured

Synthetic and reproducible: `harness_client/test/resume_latency_test.dart` drives the real `AppController` against `FakeHarness`, whose stages can be given the times a phone's network gives them (`connectDelay`, `initializeDelay`, `authenticateDelay`, `answerDelay`).  It prints `BENCH resume` lines and holds the app to bounds.  A socket that takes 40 ms, a harness that thinks 120 ms about `initialize` and 30 ms about each request:

```
BENCH resume case=cold runs=3 median=260ms min=258ms max=264ms
  stages=0:connecting 41:connecting/handshaking 163:connecting/readingSessions
         195:connecting/readingProjects 258:connected
BENCH resume case=dead silent-until-reconnect=2001ms
```

The cold resume is the sum of its stages (40 + 122 + 32 + 63), and each stage is now named.  The dead-socket case is the one a person feels: **2001 ms** before the app even begins to reconnect, which is the new `resumeProbeTimeout` of 2 s, down from 5000 ms.

## 3. What changed

1. **A dead socket is found in two seconds, not five.**  `resumed()` probes with `resumeProbeTimeout` (2 s); `checkConnection()` keeps 5 s when something else asks.  A harness that is there answers in milliseconds, so the shorter bound only costs a harness that is not there, and that one is about to be reconnected to anyway.
2. **A connect that never completes is given up on.**  `AppController._open` bounds the socket at `connectTimeout` (10 s) however the transport is opened, and `openAcpTransport` gives `Socket.connect` the same bound (it had none, so a `tcp://` device could hang until the platform gave up).
3. **The app says what it is doing, and for how long.**  `AppController` names the stage it is in (`ConnectionStage`: `checking`, `connecting`, `handshaking`, `signingIn`, `readingSessions`, `readingProjects`, `waiting`).  `ConnectionStageLine` draws it with an age that ticks once a second: `Waiting to retry · 3s` on the banner over the screens, `Connecting · 4s` on the card a remembered device shows.  A stage entered again (the next attempt) starts its age over, which is the truth: that is a new wait.
4. **The first screen is not queued behind the rest.**  After a reconnect, `refreshProjects` and the task, workspace, usage and quota reads are started together with the open conversation, rather than one after the other; the sessions still come first and alone, because they are what the first screen shows.

## 4. Copy

Every new string is a noun phrase, per `CLAUDE.md`; the notice's heading is unchanged (`Connection lost. Reconnecting…`), and the stage is the line under it.  The strings, pinned by exact assertions:

| Stage | Shown |
| --- | --- |
| `checking` | `Checking connection` |
| `connecting` | `Connecting` |
| `handshaking` | `Handshake` |
| `signingIn` | `Signing in` |
| `readingSessions` | `Reading sessions` |
| `readingProjects` | `Reading projects` |
| `waiting` | `Waiting to retry` |

With the age: `Connecting · now`, `Waiting to retry · 3s`.

## 5. Alternatives considered

- **A WebSocket ping instead of `$/ping`.**  `dart:io` already pings every 25 s, which is what finds a dead socket while the app is away; the probe exists for the case where the app was not running long enough for a ping to fail.  A shorter ping interval would find death sooner but wake the radio more often, which is the battery cost the app avoids today.
- **Reconnecting without probing.**  A resume could always drop the old socket and connect again.  That turns every foregrounding into a full handshake (and a transcript read), for a connection that is usually fine; the probe is what keeps the common case cheap.
- **A shorter connect timeout than 10 s.**  A VPN that is coming back can take a few seconds; below about ten the app would give up on connections that would have worked.

## 6. What was not changed, and why

- **The harness's own start-up.**  A cold launch waits for the harness's address, which is printed after its modules load; that is the server's cost, documented in `docs/analysis/transcript-load-2026-11-07.md`, and changing when the address is printed is a contract change with the server, not a client fix.
- **Auth, credentials, permission policy, provider pins, queue holds.**  Untouched.
- **The live harness and Noah's phone.**  Nothing was installed on, driven on or restarted for this work; the screenshots are the app drawn by `flutter test` (`HARNESS_SHOTS=... flutter test test/resume_screenshots_test.dart`).

## 7. Verification

Measured on the final committed tree, `ae666b0`, in this worktree:

- `harness_client/tool/check_build.sh`: **passed** in 788 s -- `pub get --enforce-lockfile`, `flutter analyze` (no issues), `flutter test` (1414 tests: 1374 passed, 27 failed, 13 skipped; the same 27 names fail on the base commit `9a1f28f` that the check extracts and runs for itself, so this branch adds none), the release APK build, and both tool suites (`test_qr_tools.py`, `test_check_build.py`).
- `scripts/test.sh` (the whole Emacs suite, not a subset): **PASS (full run)**, 197 files, 0 failed, 383 s.
- The `BENCH resume` lines above come from `flutter test test/resume_latency_test.dart`, which is synthetic and repeatable: `FakeHarness` with scripted delays, no real device and no real harness.
- Screenshots: `android-resume-banner.png`, `android-resume-card.png` (`HARNESS_SHOTS=... flutter test test/resume_screenshots_test.dart`).

One unrelated test fix came with this branch, in `harness_client/tool/test_qr_tools.py`: the two tests that wait for the fake phone's connect port used a 15 s wait while the port opens about 9 s and 12 s in (it appears on the (connect\_after + 1)th `adb mdns services` listing, and `qr_install.sh` lists them every 3 s).  Under the load of a full build check both failed on a machine that was merely busy; the wait is now 20 s, the behaviour unchanged.

