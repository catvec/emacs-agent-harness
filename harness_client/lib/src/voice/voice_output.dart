/// The output side of a voice setup: which voices the device's speech engine
/// has, what rate it accepts, and the parameters a reply is spoken with.
///
/// Nothing here touches a platform channel.  The device's own engine is read
/// and driven through [VoiceOutputCatalogue] and [VoiceAuditionEngine], whose
/// production implementations live in `lib/src/services/voice_output_io.dart`;
/// a test, or a screenshot, hands in a fake.
library;

import 'package:flutter/foundation.dart';

import 'voice_settings.dart';

/// One voice the platform reports, as its catalogue described it.
///
/// [name] is what `FlutterTts.setVoice` is given, together with [locale].  A
/// voice may also carry a [quality], a [gender] and an [identifier], which
/// iOS and macOS report and Android does not; they are shown as they came and
/// are never invented.
@immutable
class VoiceOutputVoice {
  const VoiceOutputVoice({
    required this.name,
    this.locale = '',
    this.quality = '',
    this.gender = '',
    this.identifier = '',
  });

  final String name;
  final String locale;

  /// The platform's word for the voice's quality (`1`, `2`, `3`, or
  /// `default`/`enhanced`/`premium` on the Apple platforms), empty when it
  /// reported none.
  final String quality;

  /// The platform's word for the voice's gender (`1`/`2`/`3`, or `male`,
  /// `female`, `unspecified` on the Apple platforms), empty when it reported
  /// none.
  final String gender;

  /// The platform's own id for the voice, when it reported one.
  final String identifier;

  /// What the voice is called in a list: its name, then its locale when the
  /// catalogue gave one.
  String get label => locale.isEmpty ? name : '$name · $locale';

  /// What to send the engine: the name the platform gave, and its locale.
  /// The locale is left out when the catalogue gave none, rather than sent
  /// as an empty one.
  Map<String, String> toVoiceArgument() => <String, String>{
    'name': name,
    if (locale.isNotEmpty) 'locale': locale,
  };

  /// The same voice, as a document keeps it.
  VoiceSettings asSetting(VoiceSettings settings) =>
      settings.copyWith(outputVoice: name, outputVoiceLocale: locale);

  /// Whether [settings] ask for this voice.
  bool matches(VoiceSettings settings) =>
      settings.outputVoice.trim() == name &&
      (locale.isEmpty || settings.outputVoiceLocale.trim() == locale);

  @override
  bool operator ==(Object other) =>
      other is VoiceOutputVoice &&
      other.name == name &&
      other.locale == locale &&
      other.quality == quality &&
      other.gender == gender &&
      other.identifier == identifier;

  @override
  int get hashCode => Object.hash(name, locale, quality, gender, identifier);

  @override
  String toString() => 'VoiceOutputVoice($label)';
}

/// The rate range a platform's speech engine reports
/// (`FlutterTts.getSpeechRateValidRange`).  The numbers are the platform's
/// own scale: Android reports 0–1.5 with a normal of 0.5, iOS about
/// 0–1 with a normal of 0.5.
@immutable
class VoiceRateRange {
  const VoiceRateRange({
    required this.min,
    required this.normal,
    required this.max,
    this.platform = '',
  });

  final double min;
  final double normal;
  final double max;

  /// The platform the range came from, as the engine names it (`android`,
  /// `ios`), empty when it did not say.
  final String platform;

  /// Whether the numbers describe a range that can be offered at all.  A
  /// platform that answers nonsense is no better than one that failed.
  bool get usable =>
      min.isFinite &&
      normal.isFinite &&
      max.isFinite &&
      min < max &&
      normal >= min &&
      normal <= max;

  @override
  bool operator ==(Object other) =>
      other is VoiceRateRange &&
      other.min == min &&
      other.normal == normal &&
      other.max == max &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(min, normal, max, platform);

  @override
  String toString() => 'VoiceRateRange($min–$max, normal $normal)';
}

/// Why a catalogue or an engine could not answer, in words for the person
/// reading them.  [message] is the platform's own words where there are any,
/// and the sheet shows it as data.
class VoiceOutputException implements Exception {
  const VoiceOutputException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the sheet asks the platform's speech engine, and nothing else.
abstract class VoiceOutputCatalogue {
  /// The voices the engine has installed now.  Throws [VoiceOutputException]
  /// (or anything else) when the platform cannot answer.
  Future<List<VoiceOutputVoice>> loadVoices();

  /// The rate range the engine accepts, or null when the platform has no
  /// answer for it: the rate control is then not offered at all, rather than
  /// given a range this client made up.
  Future<VoiceRateRange?> loadRateRange();
}

/// Read what `FlutterTts.getVoices` answered, which is a List of Maps with
/// at least `name` and `locale`, and on the Apple platforms also `quality`,
/// `gender` and `identifier`.
///
/// A map without a `name` is not a voice that can be asked for, so it is
/// left out; nothing else is: a missing locale or quality is simply empty.
/// A list that is not a list at all (a null answer from an idle engine), or a
/// list with no usable voice in it, is an [VoiceOutputException]: "it has no
/// voices" is not something this client can say for the engine.
List<VoiceOutputVoice> parseVoiceOutputs(Object? raw) {
  if (raw is! List) {
    throw const VoiceOutputException('Voice list unavailable');
  }
  final voices = <VoiceOutputVoice>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    String field(String key) {
      final value = entry[key];
      return value is String ? value.trim() : '';
    }

    final name = field('name');
    if (name.isEmpty) continue;
    voices.add(
      VoiceOutputVoice(
        name: name,
        locale: field('locale'),
        quality: field('quality'),
        gender: field('gender'),
        identifier: field('identifier'),
      ),
    );
  }
  if (voices.isEmpty) {
    throw const VoiceOutputException('Voice list unavailable');
  }
  // A platform's own order is by quality and locale, not by name; the list a
  // person reads is in its name's order.  A stable sort keeps the platform's
  // order among voices that share a name and differ only in locale.
  final sorted = List<VoiceOutputVoice>.of(voices);
  sorted.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    return a.locale.toLowerCase().compareTo(b.locale.toLowerCase());
  });
  return sorted;
}

/// Read what `FlutterTts.getSpeechRateValidRange` answered: a Map with
/// `min`, `normal` and `max`, and usually `platform`.  The numbers may arrive
/// as numbers or as their text; a range that does not describe one is
/// [VoiceOutputException], so the rate control is hidden rather than given
/// an invented range.
VoiceRateRange parseVoiceRateRange(Object? raw) {
  if (raw is! Map) {
    throw const VoiceOutputException('Speech rate unavailable');
  }
  double? number(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  final min = number(raw['min']);
  final normal = number(raw['normal']);
  final max = number(raw['max']);
  if (min == null || normal == null || max == null) {
    throw const VoiceOutputException('Speech rate unavailable');
  }
  final platform = raw['platform'];
  final range = VoiceRateRange(
    min: min,
    normal: normal,
    max: max,
    platform: platform is String ? platform.trim() : '',
  );
  if (!range.usable) {
    throw const VoiceOutputException('Speech rate unavailable');
  }
  return range;
}

/// How a reply is spoken: the voice, the rate, the pitch and the volume, all
/// already validated against what the platform accepts.
///
/// [VoiceSpeech] applies exactly these to normal spoken replies, and the
/// sheet's audition applies exactly these to its preview, so what is heard in
/// the preview is what is heard in a conversation.  Defaults are absences: an
/// empty [voice] means the engine's default voice, a null [rate] the
/// platform's normal rate, and [defaultSpeechPitch] / [defaultSpeechVolume]
/// are the engine's own, which are then not set at all.
@immutable
class VoiceOutputParams {
  const VoiceOutputParams({
    this.voice,
    this.rate,
    this.pitch = VoiceSettings.defaultSpeechPitch,
    this.volume = VoiceSettings.defaultSpeechVolume,
  });

  /// What the settings ask for.
  factory VoiceOutputParams.forSettings(VoiceSettings settings) =>
      VoiceOutputParams(
        voice: settings.outputVoice.trim().isEmpty
            ? null
            : VoiceOutputVoice(
                name: settings.outputVoice.trim(),
                locale: settings.outputVoiceLocale.trim(),
              ),
        rate: settings.speechRate,
        pitch: settings.speechPitch,
        volume: settings.speechVolume,
      );

  /// The voice to ask for, or null for the engine's default.
  final VoiceOutputVoice? voice;

  /// The rate, or null for the platform's normal one.
  final double? rate;
  final double pitch;
  final double volume;

  /// Whether anything here differs from the engine's own defaults: a voice is
  /// chosen, or a rate, a pitch or a volume was changed.
  bool get isDefault =>
      voice == null &&
      rate == null &&
      pitch == VoiceSettings.defaultSpeechPitch &&
      volume == VoiceSettings.defaultSpeechVolume;

  @override
  bool operator ==(Object other) =>
      other is VoiceOutputParams &&
      other.voice == voice &&
      other.rate == rate &&
      other.pitch == pitch &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(voice, rate, pitch, volume);

  @override
  String toString() =>
      'VoiceOutputParams(voice: ${voice?.label ?? 'default'}, rate: '
      '${rate ?? 'normal'}, pitch: $pitch, volume: $volume)';
}

/// What went wrong with a drafted number, or null when nothing did.
///
/// The note names the parameter, the value as it was typed and the range it
/// had to be in, and is a noun phrase: `Rate · 0.20 outside 0.25–2.00`.
String? voiceParameterProblem({
  required String name,
  required String typed,
  required double value,
  required double min,
  required double max,
}) {
  final shown = typed.trim().isEmpty ? _numberText(value) : typed.trim();
  return '$name · $shown outside ${_numberText(min)}–${_numberText(max)}';
}

/// What went wrong with a drafted value that is not a number at all, such as
/// an empty field or letters: `Pitch · not a number`.
String voiceParameterNotANumber(String name) => '$name · not a number';

/// A number as the sheet's notes and sliders word it: two decimals, which is
/// as fine a step as any speech engine's parameters have.
String _numberText(double value) {
  if (!value.isFinite) return '$value';
  return value.toStringAsFixed(2);
}

/// The values a draft holds for the parameters, as they were typed, and the
/// validated [VoiceOutputParams] they describe.
///
/// A parameter is offered only when the platform supports it ([rateRange] is
/// the discovered range, null when the platform did not answer); a value for
/// one that is not offered is neither shown nor sent anywhere.  Validation is
/// the same before a Save and before an audition: a number outside its range
/// or not a number at all is refused, never clamped into something nobody
/// chose, and never reaches the engine.
@immutable
class VoiceParameterDraft {
  const VoiceParameterDraft({
    this.voice,
    this.rate,
    this.rateRange,
    this.pitch = '',
    this.volume = '',
  });

  /// The draft the settings name, with every offered parameter filled in.
  factory VoiceParameterDraft.fromSettings(
    VoiceSettings settings, {
    VoiceRateRange? rateRange,
  }) => VoiceParameterDraft(
    voice: settings.outputVoice.trim().isEmpty
        ? null
        : VoiceOutputVoice(
            name: settings.outputVoice.trim(),
            locale: settings.outputVoiceLocale.trim(),
          ),
    rate: rateRange == null
        ? null
        : (settings.speechRate ?? rateRange.normal).toStringAsFixed(2),
    rateRange: rateRange,
    pitch: settings.speechPitch.toStringAsFixed(2),
    volume: settings.speechVolume.toStringAsFixed(2),
  );

  /// The chosen voice, or null for the engine's default (the same value as
  /// a free-typed one: a name this device's list does not hold).
  final VoiceOutputVoice? voice;

  /// The rate as it was typed, or null when the platform offered no rate
  /// control.
  final String? rate;

  /// The range the platform discovered, or null when it discovered none.
  final VoiceRateRange? rateRange;

  /// The pitch as it was typed.
  final String pitch;

  /// The volume as it was typed.
  final String volume;

  /// Whether a rate control is offered at all.
  bool get offersRate => rateRange != null;

  VoiceParameterDraft copyWith({
    VoiceOutputVoice? voice,
    String? rate,
    String? pitch,
    String? volume,
  }) => VoiceParameterDraft(
    voice: voice ?? this.voice,
    rate: rate ?? this.rate,
    rateRange: rateRange,
    pitch: pitch ?? this.pitch,
    volume: volume ?? this.volume,
  );

  /// A draft for the engine's default voice, keeping the parameters.
  VoiceParameterDraft withDefaultVoice() => VoiceParameterDraft(
    rate: rate,
    rateRange: rateRange,
    pitch: pitch,
    volume: volume,
  );

  /// The problems with what was drafted, in the order the sheet shows its
  /// fields.  Empty when Save and Audition may go ahead.
  List<String> get problems => <String>[
    if (_rateProblem case final problem?) problem,
    if (_pitchProblem case final problem?) problem,
    if (_volumeProblem case final problem?) problem,
  ];

  String? get _rateProblem {
    final range = rateRange;
    final typed = rate;
    if (range == null || typed == null) return null;
    final value = double.tryParse(typed.trim());
    if (value == null) return voiceParameterNotANumber('Rate');
    if (!value.isFinite || value < range.min || value > range.max) {
      return voiceParameterProblem(
        name: 'Rate',
        typed: typed,
        value: value,
        min: range.min,
        max: range.max,
      );
    }
    return null;
  }

  String? get _pitchProblem {
    final value = double.tryParse(pitch.trim());
    if (value == null || !value.isFinite) {
      return voiceParameterNotANumber('Pitch');
    }
    if (!VoiceSettings.pitchInRange(value)) {
      return voiceParameterProblem(
        name: 'Pitch',
        typed: pitch,
        value: value,
        min: VoiceSettings.minSpeechPitch,
        max: VoiceSettings.maxSpeechPitch,
      );
    }
    return null;
  }

  String? get _volumeProblem {
    final value = double.tryParse(volume.trim());
    if (value == null || !value.isFinite) {
      return voiceParameterNotANumber('Volume');
    }
    if (!VoiceSettings.volumeInRange(value)) {
      return voiceParameterProblem(
        name: 'Volume',
        typed: volume,
        value: value,
        min: VoiceSettings.minSpeechVolume,
        max: VoiceSettings.maxSpeechVolume,
      );
    }
    return null;
  }

  /// The rate this draft speaks at, or null when it is the platform's normal
  /// rate or the platform offered no rate at all.
  ///
  /// A rate equal to the range's own normal one is the normal rate, not a
  /// setting of its own: it is stored as nothing and the engine's rate is left
  /// alone, which is what keeps a setup that changed nothing speaking exactly
  /// as it did before this setting existed.
  double? get rateValue {
    final range = rateRange;
    final typed = rate?.trim() ?? '';
    if (range == null || typed.isEmpty) return null;
    final value = double.tryParse(typed);
    if (value == null || !value.isFinite) return null;
    return value == range.normal ? null : value;
  }

  /// The parameters this draft describes, or null when it has a problem:
  /// nothing invalid is ever handed to the engine.  The settings themselves
  /// keep what was chosen, which for a problem of one parameter never
  /// happens, because Save refuses the whole draft.
  VoiceOutputParams? get params {
    if (problems.isNotEmpty) return null;
    return VoiceOutputParams(
      voice: voice,
      rate: rateValue,
      pitch: double.parse(pitch.trim()),
      volume: double.parse(volume.trim()),
    );
  }

  /// The settings this draft is written into, with every offered parameter.
  /// Only a draft without problems has settings.
  VoiceSettings? applyTo(VoiceSettings settings) {
    final resolved = params;
    if (resolved == null) return null;
    final voice = this.voice;
    return settings.copyWith(
      outputVoice: voice?.name ?? '',
      outputVoiceLocale: voice?.locale ?? '',
      speechRate: resolved.rate,
      clearSpeechRate: resolved.rate == null,
      speechPitch: resolved.pitch,
      speechVolume: resolved.volume,
    );
  }
}
