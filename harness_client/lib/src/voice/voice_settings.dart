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
  });

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

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
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
  };

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
      other.realtimeVoice == realtimeVoice;

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
