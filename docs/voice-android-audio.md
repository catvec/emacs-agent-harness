# Voice on Android: which stream plays, and which control changes it

While voice output speaks on a phone, changing media volume did not change
how loud it was.  This page records what actually happened, the one output
both providers now play through, the alternatives, and how a run on a device
proves it.  The measurements are in
[the evidence file](evidence/voice-android-media-volume/galaxy-s23-logcat.txt).

## What the platform does, and why it was not media volume

Android does not let a player choose the volume control it follows.  It
derives it: `AudioAttributes.toVolumeStreamType` maps a player's *usage* to
a legacy stream, and the hardware keys, the volume slider and the framework's
own volume control all act on that stream.  Two things then override the
choice:

1. **The audio mode.**  While `AudioManager.getMode()` is a communication
   mode (`MODE_IN_COMMUNICATION`, `MODE_IN_CALL`), the framework's
   `AudioService.getActiveStreamType` makes the *call* stream the one the
   keys and the framework's volume control address, whatever the player's
   usage says.  Media volume then moves a stream nothing is playing on.
2. **The player's usage.**  A player built with
   `USAGE_VOICE_COMMUNICATION` maps to `STREAM_VOICE_CALL`, and one built with
   `USAGE_ASSISTANCE_ACCESSIBILITY` maps to `STREAM_ACCESSIBILITY`.  Neither
   is the media stream, so neither answers the media keys.

Both of the app's voice providers fell into one of those, each in its own
way, because neither named its output:

- **The live provider** plays through `flutter_webrtc`.  When the app sets no
  `androidAudioConfiguration`, that plugin's `AudioSwitchManager` keeps its
  defaults: `MODE_IN_COMMUNICATION`, `STREAM_VOICE_CALL` and
  `USAGE_VOICE_COMMUNICATION`.  `getUserMedia({audio})` starts the switch,
  which sets the mode.  So a live conversation held the phone in
  communication mode: the media slider moved and the provider's voice did
  not change.
- **The clip provider** speaks through `flutter_tts`.  The app never called
  `setAudioAttributes`, so the engine's own choice decided, and with a
  Bluetooth headset the `record` plugin's `manageBluetoothSco` (default
  true) started an SCO link on the microphone: call audio, another stream,
  narrowband, and again not the media stream.

Nothing here is a plugin bug.  Both plugins offer the configuration; the app
never gave it.

## The choice: one output, named once

`AndroidVoiceOutput.standard` (in `lib/src/voice/voice_android_audio.dart`)
is the one answer, and both backends are given it:

| Field | Value | Why |
| --- | --- | --- |
| usage | `media` | `toVolumeStreamType` maps it to `STREAM_MUSIC` |
| content type | `speech` | tells the platform the sound is speech |
| stream | `music` | the legacy stream the same audio is addressed to |
| mode | `normal` | keeps the framework off the call stream |
| focus | `gain` | another app's music ducks out of the way |
| force routing | `false` | see below |

`isMediaStream` is the invariant that makes the two agree: the usage's legacy
stream must be the stream the output names, and that stream must be music.
A configuration that fails it is not the media stream, however it is spelled.

`USAGE_ASSISTANT` also maps to `STREAM_MUSIC` and is what Google's own
assistant audio uses.  It is not chosen because it only exists from API 26
while this app runs below that, and because `media` is the usage every
player here can be given: `flutter_webrtc` takes it directly, the speech
engine's only attributes call lands on the same stream, and the Kotlin side
can set it itself.

`forceAudioRouting` stays false on purpose.  `flutter_webrtc`'s `AudioSwitch`
only routes in a communication mode unless it is set, and its Bluetooth
device is activated by starting an SCO link.  Forcing the route would move
the whole conversation back to call audio -- the exact bug this page is
about.  Left unset, media audio follows the platform's own media route: the
speaker, a wired headset, or a Bluetooth headset on its A2DP profile, all of
which media volume controls.

## How each provider is put on it

`lib/src/services/voice_android_audio_io.dart` is the platform side, and it
is the only place that touches a plugin for this.  Every call is best effort
and reported as data: a phone whose OEM refuses one must still speak.

- **Live**: `WebRTC.initialize` with the media configuration *before any peer
  connection*.  The playout track's attributes are read once, when the audio
  device module is made inside `initialize`; a process that already made one
  keeps its configuration, so this must come first.  Then
  `Helper.setAndroidAudioConfiguration` for the mode, the focus and the route
  switch, which is configured before it starts.
- **Clip**: `setAudioAttributesForNavigation` on the engine before its first
  utterance.  It sets `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` with
  `CONTENT_TYPE_SPEECH`, which maps to `STREAM_MUSIC`; the plugin exposes no
  other attributes call.  The microphone is opened with
  `AndroidRecordConfig(manageBluetooth: false)` so it cannot bring up SCO.

Both backends ask for the session when they start and give it back when they
stop: `beginLive`/`endLive`, `beginSpeech`/`endSpeech`.  A backend that fails
to open gives it back too, so a refused microphone or endpoint does not leave
the keys claimed.

## The app's own Kotlin

Neither plugin can be asked for two things, so the app's activity owns them:
`android/app/src/main/kotlin/app/harness/harness_client/VoiceAudioChannel.kt`
behind the `app.harness/voice_audio` channel.

- `volumeControlStream = STREAM_MUSIC` while a call is open, so the keys
  adjust it even at an instant when nothing is playing, and the value it had
  before is put back afterwards.
- The `AudioManager` mode and an `AudioFocusRequest` built with the output's
  own attributes, held for the call and released after it.
- `describe`: the platform's account of itself -- the mode, the stream the
  keys control, that stream's volume and maximum, the media volume, the
  routes, the focus, and **every active player with its usage, content type,
  the stream the usage maps to, and that stream's volume**.  The last is the
  important one: it is the platform saying where the sound actually went,
  which no amount of reading the app's own settings can establish.

## What was rejected

- **Setting the volume from the app.**  Tempting and wrong: it would fight
  the person's own level, and the bug is that their control does not reach
  the sound, not that the sound is at the wrong level.  The app asks to be
  heard on the stream they are already adjusting and leaves the level alone.
- **`MODE_IN_COMMUNICATION` with the media stream.**  Some routing advice
  recommends it for Bluetooth microphones.  It cannot work here: the mode is
  what makes the framework force the call stream, so the media attributes
  would be overridden by the very mode chosen to help.
- **Forcing the audio route.**  It starts SCO, which is call audio.  See
  above.
- **One `AudioFocusRequest` for the whole app.**  Focus belongs to what is
  audible.  It is held while a call is open and abandoned when it ends, so
  the phone is not kept ducking other apps for a screen nobody is on.

## What a person sees and hears

Nothing on screen changes: this is routing and control, not copy.  What
changes is that the media slider and the hardware volume keys now change how
loud a reply is, on the speaker, a wired headset, and a Bluetooth headset on
A2DP.  A Bluetooth headset's *microphone* is not used during a call, because
using it is what brings SCO up; its playback and its play/pause button still
work.

## Verifying it on a device

`tool/voice_audio_probe.sh` builds `tool/voice_audio_probe.dart` -- the app's
own audio session and speech engine, no screen of the app -- into a package
of its own (`app.harness.client.probe`, so it never replaces the app a person
has paired), installs it, runs it, and moves the media volume while it
speaks.  Everything it prints is under `HarnessVoiceProbe` in logcat.

### An emulator is the default; a phone is opted into

A run installs an app, speaks aloud and moves the media volume.  That is not
something to do to a phone that merely happens to be attached: the run that
produced the evidence below picked the first device `adb devices` listed,
which was the owner's own phone, and spoke at him while he was asleep.  The
procedure now decides the device instead of taking one:

- With no argument it uses the one attached emulator (`emulator-*`), and
  says which attached phone it is leaving alone.  No emulator is exit 4: it
  does not fall back to a phone, and more than one emulator is exit 2 until
  `--device` names one.
- `--device SERIAL` takes an emulator.  A phone's serial is refused there.
- `--real-device SERIAL --owner-permission` is the only way to a phone, and
  the permission is the owner of that phone asking for this run, at this
  time -- not a property of the phone being connected, and not a blanket
  permission that a later run inherits.  Either flag without the other, or
  both device flags at once, is exit 2 before adb is called.
- On a phone the media volume is never set above the level the phone had
  when the run started, and that level is put back at the end, so a run can
  never be louder than its owner left the phone.

`tool/test_voice_audio_probe.py` holds this with a fake adb: a phone alone
is never chosen, a phone run without the permission never reaches a device,
an emulator beside a phone gets every call, and a permitted phone run clamps
7 and 13 to the phone's own 4.  It is one of the tools' tests
`tool/check_build.sh` runs.  [This picture](evidence/voice-android-media-volume/probe-device-choice.png)
is the choice at a glance: what the old rule picked, what the new one picks
with a phone and an emulator both attached, what it says when only a phone
is, and the clamp on a permitted phone run.

An emulator cannot be heard, so what it establishes is the routing and the
volume the platform reports, not the loudness in a room.  The audible half
needs a person listening on the same run -- which is why a phone run is
theirs to ask for.

What to read, and what a good run looks like.  The recorded run is on a
Samsung Galaxy S23 (SM-S918U1), Android 17, and was made on the owner's own
phone by the old procedure that took whatever device was attached, without
his permission for it.  It is kept as what it is -- the platform's account
of the media stream -- and not as a step to repeat: the same fields are
what an emulator run shows, and a phone run is now the owner's to ask for.
It is in
[the evidence file](evidence/voice-android-media-volume/galaxy-s23-logcat.txt),
and [this picture](evidence/voice-android-media-volume/galaxy-s23-run.png)
is the same run at a glance:

- `mode=0` -- `MODE_NORMAL`, not a communication mode.
- `volumeControlStream=3` -- the keys adjust `STREAM_MUSIC`.
- `playing=usage=12/navigation/contentType=1/stream=3/volume=7` -- the
  platform's own report of the active player: navigation usage (what
  `setAudioAttributesForNavigation` sets), speech content type, and
  **stream 3, `STREAM_MUSIC`**.
- The same reply's `volume` follows the media volume the script sets: 7, then
  2, then 12 in the recorded run.
- `end` shows `volumeControlStream=-2147483648` (`USE_DEFAULT_STREAM_TYPE`)
  and `hasFocus=false`: the session was given back.

The script checks those fields and exits non-zero when they do not hold.  It
does not claim to hear anything: whether the reply got quieter is for a
person listening on the same run, and the script says so when it ends.

## Testing

`test/voice_android_audio_test.dart` asserts, with exact values:

- the one output is `media`/`speech`/`music`/`normal`/`gain`, and
  `isMediaStream` holds for it and fails for a call-stream pairing;
- every usage maps to the music stream;
- the WebRTC configuration names `normal`, `music`, `media`, `speech` and
  `forceHandleAudioRouting: false`;
- the map the Kotlin side reads is exactly the output's;
- the microphone's routing does not capture SCO;
- each backend claims the session before it connects and gives it back after,
  on both the success and the failure path, in order;
- the bridge to the Kotlin sends `begin` with the output's map and reads back
  the platform's answer, and answers nothing (rather than throwing) on a
  build with no bridge.

## What is not verified here

The audible change is the one thing no automated check establishes.  The
recorded run proves the player is on the media stream and that its volume
follows the media volume; a person listening on the same run is what
confirms it is heard.  Bluetooth (A2DP and SCO), wired and USB headsets were
not attached during the recorded run, so the route list in it is the phone's
own speaker; the routing logic is the platform's for those routes, and the
probe reports whichever are present when it runs.

No emulator run is recorded yet: the emulator-first procedure above is held
by `tool/test_voice_audio_probe.py`, which drives the script with a fake
adb, rather than by output in this directory.  An emulator would show the
same fields the recorded run shows -- the stream the player names and the
volume it follows -- and could not show loudness.
