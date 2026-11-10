/// The device's speech engine, for the output voice the setup sheet chooses
/// and the parameters a reply is spoken with.
///
/// This is the one place the app touches `flutter_tts` for the output side:
/// the catalogue the sheet lists voices from, the audition preview, and the
/// parameters [FlutterTtsVoiceSpeech] applies to ordinary spoken replies.
/// The sheet and the runtime share [applyVoiceOutputParams], so a preview and
/// a reply are spoken with the same voice, rate, pitch and volume.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../voice/voice_audition.dart';
import '../voice/voice_output.dart';
import '../voice/voice_settings.dart';
import 'voice_audio_io.dart';

/// The platform's own catalogue: `getVoices` for the installed voices and
/// `getSpeechRateValidRange` for the rate the engine accepts.
///
/// Both calls are made only when the sheet opens, never at start-up, and a
/// call that fails is reported as a [VoiceOutputException] rather than
/// answered with a list this client invented.  The rate range is optional:
/// a platform without an answer gets no rate control.
class FlutterTtsVoiceOutputCatalogue implements VoiceOutputCatalogue {
  FlutterTtsVoiceOutputCatalogue({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<List<VoiceOutputVoice>> loadVoices() async {
    try {
      return parseVoiceOutputs(await _tts.getVoices);
    } on VoiceOutputException {
      rethrow;
    } catch (error) {
      throw VoiceOutputException(_oneLine(error));
    }
  }

  @override
  Future<VoiceRateRange?> loadRateRange() async {
    try {
      final range = await _tts.getSpeechRateValidRange;
      return parseVoiceRateRange(<String, Object?>{
        'min': range.min,
        'normal': range.normal,
        'max': range.max,
        'platform': range.platform.name,
      });
    } catch (_) {
      // No rate control rather than an invented range: the platform did not
      // say what it accepts, and a slider over guessed numbers would be a
      // promise this client cannot keep.
      return null;
    }
  }
}

/// Apply [params] to [tts], before it says anything.
///
/// Only what was actually chosen is written: no voice means the engine's own
/// default voice, a null rate keeps the platform's normal rate, and a pitch or
/// volume at its default is not written either.  That is what keeps a setup
/// that changed nothing speaking exactly as it did before this setting
/// existed.  Each preview and each call has an engine of its own, made with
/// the values it speaks with, so nothing here has to undo a previous voice.
Future<void> applyVoiceOutputParams(
  FlutterTts tts,
  VoiceOutputParams params,
) async {
  final voice = params.voice;
  if (voice != null && voice.name.isNotEmpty) {
    await tts.setVoice(voice.toVoiceArgument());
  }
  if (params.rate case final rate? when rate.isFinite) {
    await tts.setSpeechRate(rate);
  }
  if (params.pitch != VoiceSettings.defaultSpeechPitch) {
    await tts.setPitch(params.pitch);
  }
  if (params.volume != VoiceSettings.defaultSpeechVolume) {
    await tts.setVolume(params.volume);
  }
}

/// The platform's speech engine, as the sheet's audition uses it: set the
/// drafted values, say a sentence, and stop.
///
/// It is a `VoiceSpeech` too, so the clip backend's ordinary replies are
/// spoken through the same object and the same [applyVoiceOutputParams]; a
/// preview is therefore what a conversation sounds like.
class FlutterTtsVoiceAuditionEngine implements VoiceAuditionEngine {
  FlutterTtsVoiceAuditionEngine({this.language = '', FlutterTts? tts})
    : _speech = FlutterTtsVoiceSpeech(language: language, tts: tts);

  final FlutterTtsVoiceSpeech _speech;
  final String language;

  @override
  Future<void> speak(
    VoiceAuditionRequest request, {
    VoidCallback? onStart,
  }) async {
    // A preview is one sentence, and the sheet shows it starting only once
    // the platform says it has: `awaitSpeakCompletion` makes the future
    // complete with the audio, not with the request.
    await _speech.speak(request.text, spoken: request.params, onStart: onStart);
  }

  @override
  Future<void> stop() => _speech.stop();
}

/// The engine a sheet's audition uses for [settings]: the device's speech
/// engine for the clip provider, and none for the live one, whose realtime
/// voice belongs to its endpoint.
VoiceAuditionEngineFactory voiceAuditionEngineFactory(
  VoiceSettings settings,
) => () => FlutterTtsVoiceAuditionEngine(language: settings.language);

/// The catalogue of the provider a sheet is set to.  Both providers show the
/// device's voices only for the clip provider; the live one has no catalogue
/// this client can verify, which is why its audition is unavailable.
VoiceOutputCatalogue voiceOutputCatalogue() => FlutterTtsVoiceOutputCatalogue();

String _oneLine(Object error) {
  final line = '$error'.trim().split('\n').first.trim();
  if (line.isEmpty) return error.runtimeType.toString();
  return line.length <= 160 ? line : '${line.substring(0, 159)}…';
}
