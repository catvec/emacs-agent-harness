import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_audition.dart';
import 'package:harness_client/src/voice/voice_output.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'support/voice_fakes.dart';

/// What `FlutterTts.getVoices` answers on Android: a name and a locale, and
/// nothing else.
const _androidVoices = <Object?>[
  <String, Object?>{'name': 'en-us-x-sfg-local', 'locale': 'en-US'},
  <String, Object?>{'name': 'en-gb-x-gba-local', 'locale': 'en-GB'},
  <String, Object?>{'name': 'de-de-x-deb-network', 'locale': 'de-DE'},
];

/// What it answers on iOS: a name and a locale, and also a quality, a gender
/// and an identifier.
const _iosVoices = <Object?>[
  <String, Object?>{
    'name': 'Samantha',
    'locale': 'en-US',
    'quality': '3',
    'gender': '2',
    'identifier': 'com.apple.voice.premium.en-US.Samantha',
  },
  <String, Object?>{
    'name': 'Daniel',
    'locale': 'en-GB',
    'quality': '2',
    'gender': '1',
    'identifier': 'com.apple.voice.enhanced.en-GB.Daniel',
  },
  <String, Object?>{
    'name': 'Anna',
    'locale': 'de-DE',
    'quality': '1',
    'gender': '2',
    'identifier': 'com.apple.voice.compact.de-DE.Anna',
  },
];

void main() {
  group('the device catalogue', () {
    test('reads the Android maps, which carry no quality or gender', () {
      final voices = parseVoiceOutputs(_androidVoices);
      expect(voices.map((voice) => voice.name), [
        'de-de-x-deb-network',
        'en-gb-x-gba-local',
        'en-us-x-sfg-local',
      ]);
      final english = voices.last;
      expect(english.locale, 'en-US');
      expect(english.quality, '');
      expect(english.gender, '');
      expect(english.identifier, '');
      expect(english.label, 'en-us-x-sfg-local · en-US');
      expect(english.toVoiceArgument(), {
        'name': 'en-us-x-sfg-local',
        'locale': 'en-US',
      });
    });

    test('reads the iOS maps, quality, gender and identifier included', () {
      final voices = parseVoiceOutputs(_iosVoices);
      expect(voices.map((voice) => voice.name), ['Anna', 'Daniel', 'Samantha']);
      final samantha = voices.last;
      expect(samantha.locale, 'en-US');
      expect(samantha.quality, '3');
      expect(samantha.gender, '2');
      expect(samantha.identifier, 'com.apple.voice.premium.en-US.Samantha');
      expect(samantha.toVoiceArgument(), {
        'name': 'Samantha',
        'locale': 'en-US',
      });
    });

    test('leaves a malformed entry out, and keeps the rest', () {
      final voices = parseVoiceOutputs(<Object?>[
        ..._androidVoices,
        // No name at all: a voice cannot be asked for by nothing.
        <String, Object?>{'locale': 'fr-FR'},
        // A name that is not text.
        <String, Object?>{'name': 7, 'locale': 'fr-FR'},
        // Not a map at all.
        'en-us-x-sfg-local',
      ]);
      expect(voices, hasLength(3));
      expect(voices.map((voice) => voice.name), isNot(contains('')));
    });

    test('an engine that answers nothing is unavailable, not empty', () {
      // Android's getVoices answers null when the engine is not ready.
      expect(
        () => parseVoiceOutputs(null),
        throwsA(isA<VoiceOutputException>()),
      );
      expect(
        () => parseVoiceOutputs(<Object?>[]),
        throwsA(isA<VoiceOutputException>()),
      );
      expect(
        () => parseVoiceOutputs(<Object?>[
          <String, Object?>{'locale': 'en-US'},
        ]),
        throwsA(isA<VoiceOutputException>()),
      );
    });

    test('reads a rate range, whose numbers may arrive as text', () {
      final range = parseVoiceRateRange(<String, Object?>{
        'min': '0',
        'normal': '0.5',
        'max': '1.5',
        'platform': 'android',
      });
      expect(range.min, 0);
      expect(range.normal, 0.5);
      expect(range.max, 1.5);
      expect(range.platform, 'android');
      expect(range.usable, isTrue);
    });

    test('a range that does not describe one is not offered', () {
      expect(
        () => parseVoiceRateRange(<String, Object?>{'min': 0, 'max': 1}),
        throwsA(isA<VoiceOutputException>()),
        reason: 'no normal rate',
      );
      expect(
        () => parseVoiceRateRange(<String, Object?>{
          'min': 2.0,
          'normal': 1.0,
          'max': 0.5,
        }),
        throwsA(isA<VoiceOutputException>()),
        reason: 'min above max',
      );
      expect(
        () => parseVoiceRateRange(<String, Object?>{
          'min': 0.0,
          'normal': double.nan,
          'max': 1.0,
        }),
        throwsA(isA<VoiceOutputException>()),
      );
      expect(
        () => parseVoiceRateRange(null),
        throwsA(isA<VoiceOutputException>()),
      );
    });

    test('a catalogue that throws is reported in the engine own words', () async {
      final catalogue = FakeVoiceCatalogue(
        voicesError: const VoiceOutputException('TextToSpeech is not ready'),
        rateError: StateError('no rate'),
      );
      await expectLater(
        catalogue.loadVoices(),
        throwsA(
          isA<VoiceOutputException>().having(
            (error) => error.message,
            'message',
            'TextToSpeech is not ready',
          ),
        ),
      );
      await expectLater(catalogue.loadRateRange(), throwsA(isA<StateError>()));
    });
  });

  group('the output settings', () {
    test('a default setup names no voice and no rate', () {
      const settings = VoiceSettings();
      final params = VoiceOutputParams.forSettings(settings);
      expect(params.voice, isNull);
      expect(params.rate, isNull);
      expect(params.pitch, 1.0);
      expect(params.volume, 1.0);
      expect(params.isDefault, isTrue);
    });

    test('the settings carry the voice, its locale and the parameters', () {
      const settings = VoiceSettings(
        outputVoice: 'Samantha',
        outputVoiceLocale: 'en-US',
        speechRate: 0.42,
        speechPitch: 1.3,
        speechVolume: 0.7,
      );
      final params = VoiceOutputParams.forSettings(settings);
      expect(params.voice?.name, 'Samantha');
      expect(params.voice?.locale, 'en-US');
      expect(params.voice?.toVoiceArgument(), {
        'name': 'Samantha',
        'locale': 'en-US',
      });
      expect(params.rate, 0.42);
      expect(params.pitch, 1.3);
      expect(params.volume, 0.7);
      expect(params.isDefault, isFalse);
    });

    test('a voice without a locale asks for the name alone', () {
      final params = VoiceOutputParams.forSettings(
        const VoiceSettings(outputVoice: 'en-us-x-sfg-local'),
      );
      expect(params.voice?.toVoiceArgument(), {'name': 'en-us-x-sfg-local'});
    });

    const range = VoiceRateRange(min: 0.25, normal: 0.5, max: 2.0);

    VoiceParameterDraft draft({
      String? rate = '0.50',
      String pitch = '1.00',
      String volume = '1.00',
      VoiceOutputVoice? voice,
      VoiceRateRange? rateRange = range,
    }) => VoiceParameterDraft(
      voice: voice,
      rate: rate,
      rateRange: rateRange,
      pitch: pitch,
      volume: volume,
    );

    test('the platform normal rate is no rate, and speaks as before', () {
      final normal = draft(rate: '0.50');
      expect(normal.problems, isEmpty);
      expect(normal.params!.rate, isNull);
      expect(
        normal.applyTo(const VoiceSettings())!.speechRate,
        isNull,
        reason: 'the normal rate is the absence of a setting',
      );
      expect(draft(rate: '0.51').params!.rate, 0.51);
    });

    test('a draft inside every range has no problem and its params', () {
      final checked = draft(
        rate: '0.75',
        pitch: '1.20',
        volume: '0.40',
        voice: const VoiceOutputVoice(name: 'Samantha', locale: 'en-US'),
      );
      expect(checked.problems, isEmpty);
      final params = checked.params!;
      expect(params.voice?.name, 'Samantha');
      expect(params.rate, 0.75);
      expect(params.pitch, 1.2);
      expect(params.volume, 0.4);
    });

    test('a rate outside the discovered range is named and refused', () {
      final outside = draft(rate: '0.20');
      expect(outside.problems, ['Rate · 0.20 outside 0.25–2.00']);
      expect(outside.params, isNull);
      expect(outside.applyTo(const VoiceSettings()), isNull);

      final above = draft(rate: '2.50');
      expect(above.problems, ['Rate · 2.50 outside 0.25–2.00']);
    });

    test('a pitch or volume outside its documented range is refused', () {
      expect(draft(pitch: '0.40').problems, ['Pitch · 0.40 outside 0.50–2.00']);
      expect(draft(pitch: '2.10').problems, ['Pitch · 2.10 outside 0.50–2.00']);
      expect(draft(volume: '1.50').problems, [
        'Volume · 1.50 outside 0.00–1.00',
      ]);
      expect(draft(volume: '-0.10').problems, [
        'Volume · -0.10 outside 0.00–1.00',
      ]);
    });

    test('a value that is not a number at all is refused too', () {
      expect(draft(rate: 'fast').problems, ['Rate · not a number']);
      expect(draft(pitch: '').problems, ['Pitch · not a number']);
      expect(draft(volume: 'NaN').problems, ['Volume · not a number']);
      expect(draft(rate: '').problems, ['Rate · not a number']);
    });

    test('a platform without a rate range offers none, and needs none', () {
      final none = draft(rate: null, rateRange: null);
      expect(none.offersRate, isFalse);
      expect(none.problems, isEmpty);
      expect(none.params!.rate, isNull);
      // A rate that was typed before the range disappeared is not sent.
      final stale = draft(rate: '99.00', rateRange: null);
      expect(stale.problems, isEmpty);
      expect(stale.params!.rate, isNull);
    });

    test('a draft writes the voice, its locale and the parameters', () {
      final settings = draft(
        rate: '0.75',
        pitch: '0.90',
        volume: '0.50',
        voice: const VoiceOutputVoice(name: 'Anna', locale: 'de-DE'),
      ).applyTo(const VoiceSettings(realtimeVoice: 'vale'))!;
      expect(settings.outputVoice, 'Anna');
      expect(settings.outputVoiceLocale, 'de-DE');
      expect(settings.speechRate, 0.75);
      expect(settings.speechPitch, 0.9);
      expect(settings.speechVolume, 0.5);
      expect(settings.realtimeVoice, 'vale', reason: 'the rest is untouched');
    });

    test('the default voice clears what was saved', () {
      final settings = draft(voice: null).applyTo(
        const VoiceSettings(outputVoice: 'Samantha', outputVoiceLocale: 'en-US'),
      )!;
      expect(settings.outputVoice, '');
      expect(settings.outputVoiceLocale, '');
    });

    test('a draft is read from the settings, normal rate and all', () {
      final read = VoiceParameterDraft.fromSettings(
        const VoiceSettings(speechPitch: 1.5, speechVolume: 0.25),
        rateRange: range,
      );
      expect(read.rate, '0.50', reason: "the platform's normal rate");
      expect(read.pitch, '1.50');
      expect(read.volume, '0.25');
      expect(read.voice, isNull);
      final named = VoiceParameterDraft.fromSettings(
        const VoiceSettings(
          outputVoice: 'Samantha',
          outputVoiceLocale: 'en-US',
          speechRate: 1.25,
        ),
        rateRange: range,
      );
      expect(named.rate, '1.25');
      expect(named.voice?.name, 'Samantha');
    });
  });

  group('the audition', () {
    VoiceAuditionRequest sample([double rate = 0.5]) => VoiceAuditionRequest(
      text: 'Harness output voice',
      params: VoiceOutputParams(
        voice: const VoiceOutputVoice(name: 'Samantha', locale: 'en-US'),
        rate: rate,
      ),
    );

    test('a preview is loading, then playing, then stopped', () async {
      // An engine that has been asked to speak but not yet begun: the state
      // is what the control says in that moment.
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final states = <VoiceAuditionState>[];
      audition.addListener(() => states.add(audition.state));
      final running = audition.audition(sample());
      expect(audition.state, VoiceAuditionState.loading);
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.loading);
      engines.last.begin();
      expect(audition.state, VoiceAuditionState.playing);
      engines.last.finish();
      await running;
      expect(audition.state, VoiceAuditionState.stopped);
      expect(states, [
        VoiceAuditionState.loading,
        VoiceAuditionState.playing,
        VoiceAuditionState.stopped,
      ]);
      expect(engines.made, 1);
    });

    test('an engine that begins at once is playing without a pause', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.playing);
      engines.last.finish();
      await running;
      expect(audition.state, VoiceAuditionState.stopped);
    });

    test('the engine is asked for the draft, unsaved values and all', () async {
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(
        VoiceAuditionRequest(
          text: 'Harness output voice',
          params: VoiceOutputParams.forSettings(
            const VoiceSettings(
              outputVoice: 'Anna',
              outputVoiceLocale: 'de-DE',
              speechRate: 0.8,
              speechPitch: 1.4,
              speechVolume: 0.3,
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final spoken = engines.last.spoken.single;
      expect(spoken.params.voice?.name, 'Anna');
      expect(spoken.params.voice?.toVoiceArgument(), {
        'name': 'Anna',
        'locale': 'de-DE',
      });
      expect(spoken.params.rate, 0.8);
      expect(spoken.params.pitch, 1.4);
      expect(spoken.params.volume, 0.3);
      engines.last.finish();
      await running;
    });

    test('a stop ends the preview and its completion is ignored', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.playing);
      await audition.stop();
      expect(audition.state, VoiceAuditionState.stopped);
      expect(engines.last.stops, 1);
      await running;
      expect(
        audition.state,
        VoiceAuditionState.stopped,
        reason: 'the completion of the stopped generation does nothing',
      );
    });

    test('a failure is shown with the engine words, and retried', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      engines.nextFailure = StateError('setVoice returned 0');
      final audition = VoiceAuditionController(engineFactory: engines.call);
      await audition.audition(sample());
      expect(audition.state, VoiceAuditionState.failed);
      expect(audition.message, 'Bad state: setVoice returned 0');
      expect(audition.isFailed, isTrue);
      expect(audition.isActive, isFalse);

      // Retry is another preview, on another engine, with the same values.
      final retry = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.playing);
      expect(audition.message, isNull);
      expect(engines.made, 2);
      engines.last.finish();
      await retry;
      expect(audition.state, VoiceAuditionState.stopped);
    });

    test('a failure during the words is a failure too', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      engines.last.fail(StateError('audio interrupted'));
      await running;
      expect(audition.state, VoiceAuditionState.failed);
      expect(audition.message, contains('audio interrupted'));
      expect(engines.last.stops, 1, reason: 'the engine was silenced');
    });

    test(
      'a rapid re-audition ends the old one and ignores its completion',
      () async {
        final engines = FakeAuditionEngines(startsImmediately: true);
        final audition = VoiceAuditionController(engineFactory: engines.call);
        final first = audition.audition(sample(0.5));
        await Future<void>.delayed(Duration.zero);
        final firstEngine = engines.last;
        expect(audition.state, VoiceAuditionState.playing);

        final second = audition.audition(sample(0.9));
        await Future<void>.delayed(Duration.zero);
        expect(engines.made, 2);
        expect(firstEngine.stops, 1, reason: 'the first was stopped');
        expect(audition.state, VoiceAuditionState.playing);
        expect(audition.request?.params.rate, 0.9);

        // The first generation finishes late: nothing moves, and its voice is
        // not the one being previewed.
        firstEngine.finish();
        await first;
        expect(audition.state, VoiceAuditionState.playing);
        expect(audition.request?.params.rate, 0.9);

        engines.last.finish();
        await second;
        expect(audition.state, VoiceAuditionState.stopped);
      },
    );

    test('a voice change during loading ignores the old completion', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final first = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.playing);

      await audition.invalidate();
      expect(audition.state, VoiceAuditionState.stopped);
      expect(engines.last.stops, 1);
      // The old engine's completion arrives after the invalidation.
      engines.last.finish();
      await first;
      expect(audition.state, VoiceAuditionState.stopped);
      expect(audition.generation, greaterThan(0));
    });

    test('a preview that never finishes fails rather than waiting forever', () async {
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(
        engineFactory: engines.call,
        timeout: const Duration(milliseconds: 20),
      );
      await audition.audition(sample());
      expect(audition.state, VoiceAuditionState.failed);
      expect(audition.message, contains('Speech timeout'));
    });

    test('a provider that cannot audition says so and speaks nothing', () async {
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(
        engineFactory: engines.call,
        available: false,
      );
      expect(audition.state, VoiceAuditionState.unavailable);
      await audition.audition(sample());
      expect(engines.made, 0);
      expect(audition.state, VoiceAuditionState.unavailable);
      expect(audition.isActive, isFalse);
    });

    test('the audition follows the provider', () async {
      final engines = FakeAuditionEngines(startsImmediately: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(audition.state, VoiceAuditionState.playing);

      // The sheet switches to the live provider: the preview ends and the
      // control is unavailable.
      await audition.setAvailable(false);
      expect(audition.state, VoiceAuditionState.unavailable);
      expect(engines.last.stops, 1);
      engines.last.finish();
      await running;
      expect(audition.state, VoiceAuditionState.unavailable);

      // Back to the clip provider: the control is offered again, idle.
      await audition.setAvailable(true);
      expect(audition.state, VoiceAuditionState.idle);
    });

    test('a new engine replaces the old one and its preview', () async {
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      await audition.replaceEngine(engines.call);
      expect(audition.state, VoiceAuditionState.stopped);
      engines.last.finish();
      await running;
      expect(audition.state, VoiceAuditionState.stopped);

      final next = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      expect(engines.made, 2, reason: 'the new factory built the engine');
      engines.last.finish();
      await next;
    });

    test('disposing stops the engine and ignores what it says later', () async {
      final engines = FakeAuditionEngines();
      final audition = VoiceAuditionController(engineFactory: engines.call);
      final running = audition.audition(sample());
      await Future<void>.delayed(Duration.zero);
      final engine = engines.last;
      audition.dispose();
      expect(engine.stops, 1);
      // The engine ends after the sheet is gone; nothing is reported.
      engine.finish();
      await running;
    });

    test('auditioning never touches the saved settings', () async {
      const saved = VoiceSettings(
        outputVoice: 'Samantha',
        outputVoiceLocale: 'en-US',
        speechRate: 0.5,
      );
      final engines = FakeAuditionEngines(autoFinish: true);
      final audition = VoiceAuditionController(engineFactory: engines.call);
      // A draft of different, unsaved values.
      final draft = const VoiceSettings(
        outputVoice: 'Anna',
        outputVoiceLocale: 'de-DE',
        speechRate: 1.2,
        speechPitch: 1.5,
        speechVolume: 0.4,
      );
      await audition.audition(
        VoiceAuditionRequest(
          text: 'Harness output voice',
          params: VoiceOutputParams.forSettings(draft),
        ),
      );
      expect(engines.spoken.single.params.voice?.name, 'Anna');
      expect(saved, const VoiceSettings(
        outputVoice: 'Samantha',
        outputVoiceLocale: 'en-US',
        speechRate: 0.5,
      ));
      expect(saved.hashCode, isNot(equals(draft.hashCode)));
    });

    test('a preview request keeps the values it was built with', () {
      final request = sample(0.25);
      expect(request.params.rate, 0.25);
      expect(request.text, 'Harness output voice');
      expect(request.toString(), contains('Samantha'));
    });
  });
}
