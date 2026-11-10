import 'package:flutter/foundation.dart';

/// How voice mode addresses the agent.
///
/// [clip] records one utterance at a time and hands it over as a WAV clip:
/// either transcribed into a message, or as an ACP audio content block.
/// [live] keeps a continuous audio stream open with a realtime provider and
/// speaks the agent's replies through it.
enum VoiceProvider { clip, live }

/// What the clip provider does with a recorded utterance.
enum ClipDelivery {
  /// Transcribe the WAV at a speech endpoint, then send the text.
  transcript,

  /// Send the WAV itself as an ACP audio content block.
  audioPrompt,
}

/// What the voice screen is set to, kept with the device rather than with one
/// harness: a phone that talks to its own harness and to a workstation should
/// not have to set the microphone up twice.
///
/// # What it holds
///
/// The setup of the provider ([provider], the endpoints and their tokens, the
/// delivery and the language), whether replies are spoken ([speakReplies]),
/// and how they are spoken when the clip provider reads them out: the device
/// voice ([outputVoice], with its [outputVoiceLocale]), the speech rate
/// ([speechRate]) and the pitch and volume ([speechPitch], [speechVolume]).
///
/// # Persistence
///
/// One JSON document per device, under the `shared_preferences` key
/// `voiceSettings`; [SettingsController] writes it when the setup sheet is
/// saved and reads it at launch.  It is scoped to this device, not to one
/// harness: signing out of a harness does not forget it, and a second device
/// has its own.  Auditioning a voice in the sheet never reaches this document:
/// only an explicit Save writes it.
///
/// The document names its [version]; version 1 predates the output voice and
/// its parameters, and loads with their defaults.  Each value of the document
/// is read on its own, so a damaged one costs only its own default:
///
///  * [outputVoice] is the voice's own `name`, as the platform reports it;
///    empty (or not a string) means the engine's default voice.
///  * [outputVoiceLocale] is the `locale` that came with that name, which the
///    platform asks for alongside it; empty is left out of the request.
///  * [speechRate] is a number inside the platform's own range, which is
///    discovered at run time and is not the same on Android and iOS; null
///    means the platform's normal rate, and the engine's rate is not set.
///  * [speechPitch] is 0.5–2.0 and [speechVolume] is 0.0–1.0, the ranges
///    flutter_tts documents.  A number outside its range, or not a finite
///    number at all, falls back to its default (1.0) rather than being
///    clamped: the file is not a place to invent a setting nobody chose.
@immutable
class VoiceSettings {
  const VoiceSettings({
    this.provider = VoiceProvider.clip,
    this.clipDelivery = ClipDelivery.transcript,
    this.speechEndpoint = '',
    this.speechModel = '',
    this.speechToken = '',
    this.language = '',
    this.speakReplies = true,
    this.realtimeEndpoint = '',
    this.realtimeModel = 'gpt-live-1',
    this.realtimeToken = '',
    this.realtimeVoice = '',
    this.outputVoice = '',
    this.outputVoiceLocale = '',
    this.speechRate,
    this.speechPitch = defaultSpeechPitch,
    this.speechVolume = defaultSpeechVolume,
  });

  /// The lowest speech pitch flutter_tts documents.
  static const double minSpeechPitch = 0.5;

  /// The highest speech pitch flutter_tts documents.
  static const double maxSpeechPitch = 2.0;

  /// The rate a fresh engine is set up with, which is
  /// `FlutterTts.setSpeechRate`'s normal value: the rate a reply is spoken at
  /// when no rate was chosen.
  static const double defaultSpeechRate = 0.5;

  /// The pitch replies are spoken at unless another is set.
  static const double defaultSpeechPitch = 1.0;

  /// The lowest speech volume flutter_tts documents.
  static const double minSpeechVolume = 0.0;

  /// The highest speech volume flutter_tts documents.
  static const double maxSpeechVolume = 1.0;

  /// The volume replies are spoken at unless another is set.
  static const double defaultSpeechVolume = 1.0;

  /// The version the stored document is written at.  2 adds the output voice
  /// and the parameters it is spoken with.
  static const int currentVersion = 2;

  /// The provider a voice screen starts with.
  final VoiceProvider provider;

  /// What the clip provider sends: text from a transcription, or the clip.
  final ClipDelivery clipDelivery;

  /// The speech-to-text endpoint.  Empty means the harness's own host on
  /// port 8080, where the local whisper.cpp server in `docs/voice.md` runs.
  final String speechEndpoint;

  /// The transcription model, for an endpoint that takes one (OpenAI's
  /// `/v1/audio/transcriptions`).  Empty for whisper.cpp's server.
  final String speechModel;

  /// The bearer token the speech endpoint needs, when it needs one.
  final String speechToken;

  /// The spoken language, as an ISO 639-1 code.  Empty lets the endpoint
  /// detect it.
  final String language;

  /// Whether the agent's text replies are spoken back.
  final bool speakReplies;

  /// Where the live provider opens its WebRTC session.
  final String realtimeEndpoint;

  /// The realtime model asked for at that endpoint.
  final String realtimeModel;

  /// The bearer token the realtime endpoint takes.  It can be an API key,
  /// which the app exchanges for an ephemeral key, or an ephemeral key.
  final String realtimeToken;

  /// The voice the live provider is asked to speak with.  Empty uses its
  /// default.
  final String realtimeVoice;

  /// The device voice the clip provider reads replies in, by the `name` the
  /// platform's own catalogue reports (`FlutterTts.getVoices`).  Empty means
  /// the engine's default voice; nothing here is a list of voice names, and
  /// a name that is no longer installed is simply not found by the engine.
  ///
  /// The live provider has no such setting: its realtime voice is
  /// provider-defined, and is [realtimeVoice].
  final String outputVoice;

  /// The locale that came with [outputVoice] in the platform's catalogue,
  /// which `FlutterTts.setVoice` asks for along with the name (a voice name
  /// alone need not be unique).  Empty leaves it out of the request.
  final String outputVoiceLocale;

  /// The rate replies are spoken at, inside the platform's own discovered
  /// range.  Null means the platform's normal rate, and the engine's rate is
  /// left as it is.
  final double? speechRate;

  /// The pitch replies are spoken at, 0.5–2.0.
  final double speechPitch;

  /// The volume replies are spoken at, 0.0–1.0.
  final double speechVolume;

  VoiceSettings copyWith({
    VoiceProvider? provider,
    ClipDelivery? clipDelivery,
    String? speechEndpoint,
    String? speechModel,
    String? speechToken,
    String? language,
    bool? speakReplies,
    String? realtimeEndpoint,
    String? realtimeModel,
    String? realtimeToken,
    String? realtimeVoice,
    String? outputVoice,
    String? outputVoiceLocale,
    double? speechRate,
    double? speechPitch,
    double? speechVolume,
    bool clearSpeechRate = false,
  }) => VoiceSettings(
    provider: provider ?? this.provider,
    clipDelivery: clipDelivery ?? this.clipDelivery,
    speechEndpoint: speechEndpoint ?? this.speechEndpoint,
    speechModel: speechModel ?? this.speechModel,
    speechToken: speechToken ?? this.speechToken,
    language: language ?? this.language,
    speakReplies: speakReplies ?? this.speakReplies,
    realtimeEndpoint: realtimeEndpoint ?? this.realtimeEndpoint,
    realtimeModel: realtimeModel ?? this.realtimeModel,
    realtimeToken: realtimeToken ?? this.realtimeToken,
    realtimeVoice: realtimeVoice ?? this.realtimeVoice,
    outputVoice: outputVoice ?? this.outputVoice,
    outputVoiceLocale: outputVoiceLocale ?? this.outputVoiceLocale,
    speechRate: clearSpeechRate ? null : (speechRate ?? this.speechRate),
    speechPitch: speechPitch ?? this.speechPitch,
    speechVolume: speechVolume ?? this.speechVolume,
  );

  /// The endpoint the clip provider actually uses, given the address of the
  /// harness this device is signed in to.  A blank explicit endpoint falls
  /// back to the harness's host on port 8080: the harness's own machine is
  /// where the local speech server in `docs/voice.md` runs.  Null host (a
  /// memory transport in a test, an empty address) leaves it blank.
  String effectiveSpeechEndpoint(String harnessAddress) {
    final explicit = speechEndpoint.trim();
    if (explicit.isNotEmpty) return explicit;
    final host = harnessHostAddress(harnessAddress);
    if (host == null) return '';
    return 'http://$host:8080/inference';
  }

  /// Whether voice mode has what it needs to start a session.
  bool configuredFor(String harnessAddress) => switch (provider) {
    VoiceProvider.clip =>
      clipDelivery == ClipDelivery.audioPrompt ||
          effectiveSpeechEndpoint(harnessAddress).isNotEmpty,
    VoiceProvider.live => realtimeEndpoint.trim().isNotEmpty,
  };

  /// Whether [rate] is a number inside the platform range [_min]–[_max].
  static bool rateInRange(double? rate, {required double min, required double max}) =>
      rate == null || (rate.isFinite && rate >= min && rate <= max);

  /// Whether [pitch] is a number flutter_tts accepts.
  static bool pitchInRange(double pitch) =>
      pitch.isFinite && pitch >= minSpeechPitch && pitch <= maxSpeechPitch;

  /// Whether [volume] is a number flutter_tts accepts.
  static bool volumeInRange(double volume) =>
      volume.isFinite && volume >= minSpeechVolume && volume <= maxSpeechVolume;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': currentVersion,
    'provider': provider.name,
    'clipDelivery': clipDelivery.name,
    'speechEndpoint': speechEndpoint,
    'speechModel': speechModel,
    'speechToken': speechToken,
    'language': language,
    'speakReplies': speakReplies,
    'realtimeEndpoint': realtimeEndpoint,
    'realtimeModel': realtimeModel,
    'realtimeToken': realtimeToken,
    'realtimeVoice': realtimeVoice,
    'outputVoice': outputVoice,
    'outputVoiceLocale': outputVoiceLocale,
    // A rate is written only when there is one: the platform's normal rate is
    // the absence of a setting, not a number the file claims.
    if (speechRate case final rate?) 'speechRate': rate,
    'speechPitch': speechPitch,
    'speechVolume': speechVolume,
  };

  /// Read a stored document of any version.  Version 1 has no output voice
  /// and no parameters, so it loads with their defaults; every value is read
  /// on its own, and one that is damaged keeps only its own default.
  factory VoiceSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    String text(String key, String fallback) {
      final value = map[key];
      return value is String ? value : fallback;
    }

    bool flag(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    /// A number inside [_min]–[_max], or the default.  A string is not a
    /// number here: the document is written by this app, and a value that
    /// arrived as text is not one anybody chose.
    double number(
      String key,
      double fallback, {
      required double min,
      required double max,
    }) {
      final value = map[key];
      final parsed = value is num ? value.toDouble() : null;
      if (parsed == null || !parsed.isFinite || parsed < min || parsed > max) {
        return fallback;
      }
      return parsed;
    }

    final rate = map['speechRate'];
    final parsedRate = rate is num ? rate.toDouble() : null;

    final provider = switch (text('provider', 'clip')) {
      'live' => VoiceProvider.live,
      _ => VoiceProvider.clip,
    };
    final delivery = switch (text('clipDelivery', 'transcript')) {
      'audioPrompt' => ClipDelivery.audioPrompt,
      _ => ClipDelivery.transcript,
    };
    return VoiceSettings(
      provider: provider,
      clipDelivery: delivery,
      speechEndpoint: text('speechEndpoint', ''),
      speechModel: text('speechModel', ''),
      speechToken: text('speechToken', ''),
      language: text('language', ''),
      speakReplies: flag('speakReplies', true),
      realtimeEndpoint: text('realtimeEndpoint', ''),
      realtimeModel: text('realtimeModel', 'gpt-live-1'),
      realtimeToken: text('realtimeToken', ''),
      realtimeVoice: text('realtimeVoice', ''),
      outputVoice: text('outputVoice', ''),
      outputVoiceLocale: text('outputVoiceLocale', ''),
      // A rate is validated against the platform range when it is used, which
      // is the only place that range is known; a number that is not finite
      // is no rate at all, and any finite number is kept as saved.
      speechRate: parsedRate != null && parsedRate.isFinite
          ? parsedRate
          : null,
      speechPitch: number(
        'speechPitch',
        defaultSpeechPitch,
        min: minSpeechPitch,
        max: maxSpeechPitch,
      ),
      speechVolume: number(
        'speechVolume',
        defaultSpeechVolume,
        min: minSpeechVolume,
        max: maxSpeechVolume,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceSettings &&
      other.provider == provider &&
      other.clipDelivery == clipDelivery &&
      other.speechEndpoint == speechEndpoint &&
      other.speechModel == speechModel &&
      other.speechToken == speechToken &&
      other.language == language &&
      other.speakReplies == speakReplies &&
      other.realtimeEndpoint == realtimeEndpoint &&
      other.realtimeModel == realtimeModel &&
      other.realtimeToken == realtimeToken &&
      other.realtimeVoice == realtimeVoice &&
      other.outputVoice == outputVoice &&
      other.outputVoiceLocale == outputVoiceLocale &&
      other.speechRate == speechRate &&
      other.speechPitch == speechPitch &&
      other.speechVolume == speechVolume;

  @override
  int get hashCode => Object.hash(
    provider,
    clipDelivery,
    speechEndpoint,
    speechModel,
    speechToken,
    language,
    speakReplies,
    realtimeEndpoint,
    realtimeModel,
    realtimeToken,
    realtimeVoice,
    outputVoice,
    outputVoiceLocale,
    speechRate,
    speechPitch,
    speechVolume,
  );
}

/// The host of [address], as a URL host would read it.
///
/// The app keeps the harness's address as it was typed, with or without a
/// scheme (`ws://host:port/acp`, `host:port`).  A bare IPv6 address is given
/// the brackets a URL needs.  Null when no host can be read.
String? harnessHostAddress(String address) {
  final text = address.trim();
  if (text.isEmpty) return null;
  final withScheme = text.contains('://') ? text : 'ws://$text';
  final uri = Uri.tryParse(withScheme);
  final host = uri?.host;
  if (host == null || host.isEmpty) return null;
  return host.contains(':') ? '[$host]' : host;
}
