import 'dart:async';

import 'package:flutter/foundation.dart';

/// The Android audio output a voice conversation plays through, named once so
/// every player in the app asks the platform for the same one.
///
/// # Why one name
///
/// On Android, which volume control a player follows is decided by the audio
/// attributes it plays with, not by the app: the legacy stream a usage maps to
/// is what the hardware keys and the volume sliders adjust
/// (`AudioAttributes.toVolumeStreamType`), and the `AudioManager` mode decides
/// which stream the framework makes active while nothing else is playing
/// (`AudioService.getActiveStreamType`).
///
/// Neither backend named its output, so each got a default that is not the
/// media stream:
///
///  * the live WebRTC stream plays with `flutter_webrtc`'s defaults,
///    `USAGE_VOICE_COMMUNICATION` and `STREAM_VOICE_CALL`, and its
///    `AudioSwitch` puts the phone in `MODE_IN_COMMUNICATION`; in that mode the
///    framework forces the call stream, so media volume and the media slider
///    move and the voice does not change;
///  * the speech engine was never told anything, so its own choice (and, with
///    a Bluetooth headset, the SCO link the recorder brings up) decided, which
///    is again a stream the person is not adjusting.
///
/// [AndroidVoiceOutput.standard] is the one answer, and both backends are
/// given it.
///
/// # The choice
///
/// `media` usage with `speech` content type, `music` stream and `normal` mode:
///
///  * `USAGE_MEDIA` maps to `STREAM_MUSIC`, so media volume -- the keys and
///    the slider -- changes how loud the voice is, and the keys control media
///    while the voice screen is open;
///  * `CONTENT_TYPE_SPEECH` tells the platform the sound is speech, which is
///    what has it processed as voice rather than as music;
///  * `MODE_NORMAL` keeps the phone out of the in-call mode that would make
///    the framework force the call stream instead.
///
/// `USAGE_ASSISTANT` maps to `STREAM_MUSIC` too and is what Google's own
/// assistant audio uses; it is not chosen here because it only exists from
/// API 26 while this app runs below that, and because the media usage is the
/// one every player here can be given: `flutter_webrtc` takes it directly, the
/// speech engine's only attributes call lands on the same stream, and the
/// Kotlin side can set it itself.
///
/// [AndroidVoiceOutput.focus] is `gain`, so another app's music ducks out of
/// the way of a spoken reply instead of mixing with it.
///
/// Nothing here changes a device volume.  The app asks to be heard on the
/// stream the person is already adjusting, and leaves the level to them.
@immutable
class AndroidVoiceOutput {
  const AndroidVoiceOutput({
    this.usage = AndroidVoiceUsage.media,
    this.contentType = AndroidVoiceContentType.speech,
    this.streamType = AndroidVoiceStreamType.music,
    this.mode = AndroidVoiceMode.normal,
    this.focus = AndroidVoiceFocus.gain,
    this.forceAudioRouting = false,
  });

  /// The one output both voice backends play through.
  static const standard = AndroidVoiceOutput();

  /// What the sound is for.  Its legacy stream is [streamType]; the two must
  /// agree, and [isMediaStream] is what says they do.
  final AndroidVoiceUsage usage;

  /// What the sound is.
  final AndroidVoiceContentType contentType;

  /// The legacy stream the same audio is addressed to, for a platform or a
  /// vendor stack that still routes by stream.
  final AndroidVoiceStreamType streamType;

  /// The `AudioManager` mode held while the conversation is audible.
  final AndroidVoiceMode mode;

  /// How much audio focus is requested while the conversation is audible.
  final AndroidVoiceFocus focus;

  /// Whether the platform should keep routing the microphone and the output
  /// to a device it picked even though [mode] is not a communication mode.
  ///
  /// `flutter_webrtc`'s `AudioSwitch` only routes when the mode is
  /// `inCommunication` or `inCall`, unless this is set.  It is left unset: its
  /// Bluetooth device is activated by starting an SCO link, which moves the
  /// whole conversation to call audio -- another stream, another volume
  /// control, and narrowband -- and its earpiece device would move media audio
  /// off the speaker.  With it unset, media audio follows the platform's own
  /// media route: the speaker, a wired headset, or a Bluetooth headset on its
  /// A2DP profile, all of which media volume controls.
  final bool forceAudioRouting;

  /// Whether [usage] and [streamType] name the same stream, i.e. whether the
  /// keys, the sliders and the player agree.
  bool get isMediaStream =>
      usage.legacyStream == streamType &&
      streamType == AndroidVoiceStreamType.music;

  /// The `flutter_webrtc` audio configuration for a live session, as the map
  /// its Android side reads.  The names are the ones `AudioUtils` matches, and
  /// the same map configures both the playout track (through `initialize`) and
  /// the session's mode, focus and routing (through
  /// `setAndroidAudioConfiguration`).
  Map<String, Object?> get webrtcConfiguration => <String, Object?>{
    'manageAudioFocus': true,
    'androidAudioMode': mode.webrtcName,
    'androidAudioFocusMode': focus.webrtcName,
    'androidAudioStreamType': streamType.webrtcName,
    'androidAudioAttributesUsageType': usage.webrtcName,
    'androidAudioAttributesContentType': contentType.webrtcName,
    'forceHandleAudioRouting': forceAudioRouting,
  };

  /// What the Kotlin side is told, so the activity's volume control stream and
  /// the description it logs agree with the two players.
  Map<String, Object?> toMap() => <String, Object?>{
    'usage': usage.name,
    'contentType': contentType.name,
    'streamType': streamType.name,
    'mode': mode.name,
    'focus': focus.name,
    'forceAudioRouting': forceAudioRouting,
  };

  @override
  bool operator ==(Object other) =>
      other is AndroidVoiceOutput &&
      other.usage == usage &&
      other.contentType == contentType &&
      other.streamType == streamType &&
      other.mode == mode &&
      other.focus == focus &&
      other.forceAudioRouting == forceAudioRouting;

  @override
  int get hashCode => Object.hash(
    usage,
    contentType,
    streamType,
    mode,
    focus,
    forceAudioRouting,
  );

  @override
  String toString() =>
      'AndroidVoiceOutput(${usage.name}, ${contentType.name}, '
      '${streamType.name}, ${mode.name}, ${focus.name})';
}

/// `AudioAttributes` usages this app may ask for, named as the platform's own
/// constants are once their prefix is dropped.
enum AndroidVoiceUsage {
  media,
  assistant,
  navigation;

  /// The legacy stream `AudioAttributes.toVolumeStreamType` maps this usage
  /// to, which is the control that then adjusts it.
  AndroidVoiceStreamType get legacyStream => switch (this) {
    AndroidVoiceUsage.media ||
    AndroidVoiceUsage.assistant ||
    AndroidVoiceUsage.navigation => AndroidVoiceStreamType.music,
  };

  String get webrtcName => switch (this) {
    AndroidVoiceUsage.media => 'media',
    AndroidVoiceUsage.assistant => 'assistant',
    AndroidVoiceUsage.navigation => 'assistanceNavigationGuidance',
  };
}

/// `AudioAttributes` content types, named as the platform names them.
enum AndroidVoiceContentType {
  speech,
  music;

  String get webrtcName => name;
}

/// Legacy streams, named as the platform names them.
enum AndroidVoiceStreamType {
  music,
  voiceCall;

  String get webrtcName => switch (this) {
    AndroidVoiceStreamType.music => 'music',
    AndroidVoiceStreamType.voiceCall => 'voiceCall',
  };
}

/// `AudioManager` modes the app holds while a conversation is audible.
enum AndroidVoiceMode {
  normal,
  inCommunication;

  String get webrtcName => switch (this) {
    AndroidVoiceMode.normal => 'normal',
    AndroidVoiceMode.inCommunication => 'inCommunication',
  };
}

/// The audio focus the app asks for while a conversation is audible.
enum AndroidVoiceFocus {
  gain,
  gainTransient;

  String get webrtcName => switch (this) {
    AndroidVoiceFocus.gain => 'gain',
    AndroidVoiceFocus.gainTransient => 'gainTransient',
  };
}

/// How a voice conversation's microphone is opened, around
/// [AndroidVoiceOutput].
///
/// The microphone belongs to a different plugin than the player, and the two
/// disagree about Bluetooth by default: `record` brings up a Bluetooth SCO link
/// for a headset's microphone, which switches the whole conversation to call
/// audio -- another stream, another volume control, and narrowband -- even
/// though the reply is playing on the media stream.  [captureSco] is therefore
/// false while a voice conversation is live: the reply stays on the stream the
/// person is adjusting, and the microphone is the phone's or the wired
/// headset's own.  A Bluetooth headset is still heard through its A2DP profile
/// and still plays and pauses the call with its button (the media session in
/// `MainActivity`); only its microphone is not used.
@immutable
class AndroidVoiceRouting {
  const AndroidVoiceRouting({this.captureSco = false});

  /// What a voice conversation uses.
  static const standard = AndroidVoiceRouting();

  /// Whether opening the microphone may bring up a Bluetooth SCO link.
  final bool captureSco;

  @override
  bool operator ==(Object other) =>
      other is AndroidVoiceRouting && other.captureSco == captureSco;

  @override
  int get hashCode => captureSco.hashCode;

  @override
  String toString() => 'AndroidVoiceRouting(sco: $captureSco)';
}

/// The Android audio session a voice backend plays through.
///
/// A backend asks for the platform to be put on [AndroidVoiceOutput.standard]
/// when it starts and to be given back when it ends.  Off Android every call
/// is a no-op, which is what [SilentVoiceAndroidAudio] is for; the Android
/// implementation is `PlatformVoiceAndroidAudio` in `services/`, because it
/// is the one that touches platform channels and this layer stays pure.
abstract class VoiceAndroidAudio {
  /// The output this session plays through.
  AndroidVoiceOutput get output;

  /// The platform's own account of its audio state: the mode, the stream the
  /// volume keys control, that stream's volume, the route and the focus.
  /// Null when the platform did not answer, which is what a platform without
  /// a native bridge says.
  Future<Map<String, Object?>?> describe();

  /// Before a live session opens: put the platform's realtime player and its
  /// session mode, focus and routing on [output], and have the activity
  /// control the volume stream [output] maps to.
  Future<void> beginLive();

  /// After the live session closes: give the device, the mode, the focus and
  /// the volume keys back.
  Future<void> endLive();

  /// Before the clip provider speaks: have the activity control the volume
  /// stream [output] maps to, for as long as the screen is open.
  Future<void> beginSpeech();

  /// Put the speech engine on [output]'s stream.  The engine's own default
  /// attributes decide which stream its audio lands on, and a stream the
  /// volume keys do not control is a reply whose volume cannot be changed.
  Future<void> speechAttributes(Object tts);

  /// After the clip provider's last utterance: give the keys back.
  Future<void> endSpeech();
}

/// A platform with no Android audio session: every call is a no-op and there
/// is nothing to describe.
class SilentVoiceAndroidAudio implements VoiceAndroidAudio {
  const SilentVoiceAndroidAudio();

  @override
  AndroidVoiceOutput get output => AndroidVoiceOutput.standard;

  @override
  Future<Map<String, Object?>?> describe() async => null;

  @override
  Future<void> beginLive() async {}

  @override
  Future<void> endLive() async {}

  @override
  Future<void> beginSpeech() async {}

  @override
  Future<void> speechAttributes(Object tts) async {}

  @override
  Future<void> endSpeech() async {}
}
