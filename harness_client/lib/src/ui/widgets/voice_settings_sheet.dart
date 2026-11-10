import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/voice_output_io.dart';
import '../../voice/voice_audition.dart';
import '../../voice/voice_output.dart';
import '../../voice/voice_settings.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';

/// The words a preview says.  A noun phrase, not a sentence: it is the sample
/// the engine reads out, and the only text an audition ever speaks.
const String voiceAuditionSample = 'Harness output voice';

/// The setup of a voice screen: which provider it uses, and what that
/// provider needs to hear and speak.
///
/// [catalogue] and [engineFactory] are the device's speech engine: the
/// production ones read `flutter_tts`'s installed voices and rate range and
/// audition through it, and a test or a screenshot hands in scripted ones.  A
/// sheet never opens a platform channel of its own.
Future<VoiceSettings?> showVoiceSettingsSheet(
  BuildContext context, {
  required VoiceSettings settings,
  required String harnessAddress,
  VoiceOutputCatalogue? catalogue,
  VoiceAuditionEngine Function(VoiceSettings settings)? engineFactory,
}) {
  return showHarnessSheet<VoiceSettings>(
    context: context,
    builder: (sheetContext) => VoiceSettingsSheet(
      settings: settings,
      harnessAddress: harnessAddress,
      catalogue: catalogue,
      engineFactory: engineFactory,
    ),
  );
}

/// The voice setup sheet: the provider and its endpoints, and one section for
/// the output voice — which of the device's voices replies are spoken in, how
/// fast and how loud, and a preview of exactly those values.
///
/// The sheet holds a draft of the whole setup.  A preview speaks the draft as
/// it stands, saved or not, and never saves anything; only Save writes the
/// whole draft, and `Unsaved changes` with `Revert` makes the difference
/// visible and undoable.
class VoiceSettingsSheet extends StatefulWidget {
  const VoiceSettingsSheet({
    super.key,
    required this.settings,
    required this.harnessAddress,
    this.catalogue,
    this.engineFactory,
  });

  final VoiceSettings settings;
  final String harnessAddress;

  /// The device's voice catalogue; the platform's own when nothing else is
  /// given.
  final VoiceOutputCatalogue? catalogue;

  /// Builds the engine an audition speaks through, from the values being
  /// auditioned; the device's speech engine when nothing else is given.  The
  /// whole settings are handed in, so a preview speaks in the language the
  /// setup chose.
  final VoiceAuditionEngine Function(VoiceSettings settings)? engineFactory;

  @override
  State<VoiceSettingsSheet> createState() => _VoiceSettingsSheetState();
}

/// What the sheet knows of the device's voices: what is loaded, what failed,
/// and the rate range the engine accepts.
@immutable
class _VoiceCatalogue {
  const _VoiceCatalogue({
    this.loading = true,
    this.voices = const <VoiceOutputVoice>[],
    this.problem,
    this.rateRange,
    this.rateProbed = false,
  });

  final bool loading;
  final List<VoiceOutputVoice> voices;

  /// What the engine said when the list could not be read, as data.
  final String? problem;

  /// The rate range the platform reported, or null when it reported none (a
  /// failure or an absent answer): the rate control is then not offered at
  /// all.
  final VoiceRateRange? rateRange;

  /// Whether the rate range has been asked for, so a failure is not retried
  /// on every rebuild.
  final bool rateProbed;

  bool get failed => problem != null && !loading;

  _VoiceCatalogue withVoices(List<VoiceOutputVoice> voices) => _VoiceCatalogue(
    loading: false,
    voices: voices,
    rateRange: rateRange,
    rateProbed: rateProbed,
  );

  _VoiceCatalogue withProblem(Object error) => _VoiceCatalogue(
    loading: false,
    problem: _oneLine(error),
    rateRange: rateRange,
    rateProbed: rateProbed,
  );

  _VoiceCatalogue withRateRange(VoiceRateRange? range) => _VoiceCatalogue(
    loading: loading,
    voices: voices,
    problem: problem,
    rateRange: range,
    rateProbed: true,
  );
}

class _VoiceSettingsSheetState extends State<VoiceSettingsSheet> {
  late VoiceProvider _provider = widget.settings.provider;
  late ClipDelivery _delivery = widget.settings.clipDelivery;
  late final _speechEndpoint = TextEditingController(
    text: widget.settings.speechEndpoint,
  );
  late final _speechModel = TextEditingController(
    text: widget.settings.speechModel,
  );
  late final _speechToken = TextEditingController(
    text: widget.settings.speechToken,
  );
  late final _language = TextEditingController(text: widget.settings.language);
  late final _realtimeEndpoint = TextEditingController(
    text: widget.settings.realtimeEndpoint,
  );
  late final _realtimeModel = TextEditingController(
    text: widget.settings.realtimeModel,
  );
  late final _realtimeToken = TextEditingController(
    text: widget.settings.realtimeToken,
  );
  late final _realtimeVoice = TextEditingController(
    text: widget.settings.realtimeVoice,
  );
  late bool _speakReplies = widget.settings.speakReplies;
  _VoiceCatalogue _catalogue = const _VoiceCatalogue();
  bool _catalogueAsked = false;
  late VoiceAuditionController _audition;
  String? _error;

  /// The device voice the draft asks for, and the locale that came with it.
  /// A name typed by hand (when the device's list could not be read) is
  /// [VoiceOutputVoice] too, without a locale.
  VoiceOutputVoice? _outputVoice;
  late final _outputVoiceText = TextEditingController(
    text: widget.settings.outputVoice,
  );
  late final _outputVoiceLocale = TextEditingController(
    text: widget.settings.outputVoiceLocale,
  );

  /// The parameters as they are typed.  The rate field is empty until the
  /// platform's range arrives, since its normal rate is only known then.
  late final _rate = TextEditingController(
    text: widget.settings.speechRate?.toStringAsFixed(2) ?? '',
  );
  late final _pitch = TextEditingController(
    text: widget.settings.speechPitch.toStringAsFixed(2),
  );
  late final _volume = TextEditingController(
    text: widget.settings.speechVolume.toStringAsFixed(2),
  );

  @override
  void initState() {
    super.initState();
    final name = widget.settings.outputVoice.trim();
    if (name.isNotEmpty) {
      _outputVoice = VoiceOutputVoice(
        name: name,
        locale: widget.settings.outputVoiceLocale.trim(),
      );
    }
    _audition = VoiceAuditionController(
      engineFactory: _engineForDraft,
      available: _auditionAvailable,
    )..addListener(_auditionChanged);
    // The device's voices are read when the sheet opens, never at launch: a
    // device that never opens this sheet never asks its engine for anything.
    if (_provider == VoiceProvider.clip) scheduleMicrotask(_loadCatalogue);
  }

  @override
  void dispose() {
    _audition.removeListener(_auditionChanged);
    _audition.dispose();
    for (final controller in [
      _speechEndpoint,
      _speechModel,
      _speechToken,
      _language,
      _realtimeEndpoint,
      _realtimeModel,
      _realtimeToken,
      _realtimeVoice,
      _outputVoiceText,
      _outputVoiceLocale,
      _rate,
      _pitch,
      _volume,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _auditionChanged() {
    if (mounted) setState(() {});
  }

  /// Whether this provider has a voice this client can preview.  The clip
  /// provider speaks through the device's engine, whose voices can be listed
  /// and tried; the live provider's realtime voice is defined by its own
  /// endpoint and model, and this client holds no verified catalogue to try
  /// one against.
  ///
  /// It follows the provider being drafted rather than the saved settings, and
  /// is asked for again whenever the provider — or a realtime endpoint or
  /// model the live provider would need — changes, so the control always
  /// describes the setup on screen.
  bool get _auditionAvailable => _provider == VoiceProvider.clip;

  VoiceAuditionEngine _engineForDraft() {
    final builder = widget.engineFactory;
    final settings = _draft() ?? widget.settings;
    if (builder != null) return builder(settings);
    return voiceAuditionEngineFactory(settings)();
  }

  /// Read the device's voices and rate range.  They are two answers that
  /// arrive on their own: a slow rate range must not keep the voice list from
  /// being shown, and a failed list must not hide a rate the platform did
  /// report.
  Future<void> _loadCatalogue() async {
    _catalogueAsked = true;
    final catalogue = widget.catalogue ?? voiceOutputCatalogue();
    // The range is asked for first, with its failure answered at once: a
    // platform that throws rather than answers must not leave an error
    // nobody is listening to while the voice list is still on its way.
    Future<VoiceRateRange?> range;
    try {
      range = catalogue.loadRateRange().catchError((Object _) => null);
    } catch (_) {
      range = Future<VoiceRateRange?>.value();
    }
    try {
      final voices = await catalogue.loadVoices();
      if (!mounted) return;
      setState(() {
        _catalogue = _catalogue.withVoices(voices);
        // A stored voice the device still has keeps the locale exactly as
        // the platform spells it, rather than the one that was saved.
        final chosen = _outputVoice;
        if (chosen != null) {
          for (final voice in voices) {
            if (voice.name == chosen.name &&
                (chosen.locale.isEmpty || voice.locale == chosen.locale)) {
              _outputVoice = voice;
              _outputVoiceText.text = voice.name;
              _outputVoiceLocale.text = voice.locale;
              break;
            }
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _catalogue = _catalogue.withProblem(error));
    }
    VoiceRateRange? discovered;
    try {
      discovered = await range;
    } catch (_) {
      discovered = null;
    }
    if (!mounted) return;
    setState(() {
      _catalogue = _catalogue.withRateRange(discovered);
      if (discovered != null && _rate.text.trim().isEmpty) {
        _rate.text = _savedRateText;
      }
    });
  }

  /// The rate field's text for what is saved: the stored rate, or the
  /// platform's own normal rate once it is known, and nothing until then.
  String get _savedRateText {
    final stored = widget.settings.speechRate;
    if (stored != null) return stored.toStringAsFixed(2);
    final range = _catalogue.rateRange;
    return range == null ? '' : range.normal.toStringAsFixed(2);
  }

  /// The voice the draft names: the one chosen from the device's list, or the
  /// name typed by hand when the list itself could not be read.  Empty is the
  /// engine's default.
  VoiceOutputVoice? get _draftVoice {
    final chosen = _outputVoice;
    if (chosen != null) return chosen;
    final typed = _outputVoiceText.text.trim();
    if (typed.isEmpty) return null;
    final locale = _outputVoiceLocale.text.trim();
    return VoiceOutputVoice(name: typed, locale: locale);
  }

  VoiceParameterDraft get _parameters => VoiceParameterDraft(
    voice: _draftVoice,
    rateRange: _catalogue.rateRange,
    rate: _catalogue.rateRange == null ? null : _rate.text,
    pitch: _pitch.text,
    volume: _volume.text,
  );

  /// The whole draft, or null when it holds something that may not be saved:
  /// an out-of-range or malformed number is refused, never clamped into a
  /// value nobody chose and never written.
  VoiceSettings? _draft() {
    final applied = VoiceParameterDraft(
      voice: _draftVoice,
      rateRange: _catalogue.rateRange,
      rate: _catalogue.rateRange == null ? null : _rate.text,
      pitch: _pitch.text,
      volume: _volume.text,
    ).applyTo(widget.settings);
    if (applied == null) return null;
    // A rate the platform no longer reports a range for is left as it was
    // saved: hiding a control is not the same as erasing its value.
    final rate = _catalogue.rateRange == null
        ? widget.settings.speechRate
        : applied.speechRate;
    return applied.copyWith(
      provider: _provider,
      clipDelivery: _delivery,
      speechEndpoint: _speechEndpoint.text.trim(),
      speechModel: _speechModel.text.trim(),
      speechToken: _speechToken.text.trim(),
      language: _language.text.trim(),
      speakReplies: _speakReplies,
      realtimeEndpoint: _realtimeEndpoint.text.trim(),
      realtimeModel: _realtimeModel.text.trim(),
      realtimeToken: _realtimeToken.text.trim(),
      realtimeVoice: _realtimeVoice.text.trim(),
      speechRate: rate,
      clearSpeechRate: rate == null,
    );
  }

  void _save() {
    final draft = _draft();
    if (draft == null) {
      // The parameter notes are already on screen; a second copy of one here
      // would say the same thing twice.
      setState(() => _error = null);
      return;
    }
    final missing = switch (draft.provider) {
      VoiceProvider.clip =>
        draft.clipDelivery == ClipDelivery.transcript &&
                draft.effectiveSpeechEndpoint(widget.harnessAddress).isEmpty
            ? 'Speech endpoint required'
            : null,
      VoiceProvider.live =>
        draft.realtimeEndpoint.isEmpty ? 'Realtime endpoint required' : null,
    };
    if (missing != null) {
      setState(() => _error = missing);
      return;
    }
    Navigator.of(context).pop(draft);
  }

  /// Put the draft back to what is saved, so a draft that differs from it
  /// visibly stops differing.  A preview of the old draft is stopped.
  void _revert() {
    setState(() {
      _provider = widget.settings.provider;
      _delivery = widget.settings.clipDelivery;
      _speechEndpoint.text = widget.settings.speechEndpoint;
      _speechModel.text = widget.settings.speechModel;
      _speechToken.text = widget.settings.speechToken;
      _language.text = widget.settings.language;
      _speakReplies = widget.settings.speakReplies;
      _realtimeEndpoint.text = widget.settings.realtimeEndpoint;
      _realtimeModel.text = widget.settings.realtimeModel;
      _realtimeToken.text = widget.settings.realtimeToken;
      _realtimeVoice.text = widget.settings.realtimeVoice;
      final name = widget.settings.outputVoice.trim();
      _outputVoice = name.isEmpty
          ? null
          : VoiceOutputVoice(
              name: name,
              locale: widget.settings.outputVoiceLocale.trim(),
            );
      _outputVoiceText.text = name;
      _outputVoiceLocale.text = widget.settings.outputVoiceLocale;
      _rate.text = _savedRateText;
      _pitch.text = widget.settings.speechPitch.toStringAsFixed(2);
      _volume.text = widget.settings.speechVolume.toStringAsFixed(2);
      _error = null;
    });
    unawaited(_audition.setAvailable(_auditionAvailable));
    unawaited(_audition.invalidate());
  }

  void _changeProvider(VoiceProvider next) {
    if (next == _provider) return;
    setState(() {
      _provider = next;
      _error = null;
    });
    // A preview belongs to the provider it was started with: the live
    // provider's voice is defined by its endpoint, and this client has no
    // catalogue to try one against.
    unawaited(_audition.setAvailable(_auditionAvailable));
    if (next == VoiceProvider.clip && !_catalogueAsked) {
      unawaited(_loadCatalogue());
    }
  }

  /// A change to the voice or to one of its parameters stops a preview that
  /// is running; its completion cannot bring it back, and it can never speak
  /// the old voice over the new draft.
  void _changedOutput() {
    setState(() => _error = null);
    unawaited(_audition.invalidate());
  }

  void _chooseVoice(VoiceOutputVoice? voice) {
    setState(() {
      _outputVoice = voice;
      _outputVoiceText.text = voice?.name ?? '';
      _outputVoiceLocale.text = voice?.locale ?? '';
    });
    _changedOutput();
  }

  void _auditionNow() {
    if (_audition.isActive) {
      unawaited(_audition.stop());
      return;
    }
    final params = _parameters.params;
    // Nothing invalid ever reaches the engine: the notes under the fields say
    // what must be fixed, and the preview is refused.
    if (params == null) return;
    setState(() => _error = null);
    unawaited(
      _audition.audition(
        VoiceAuditionRequest(text: voiceAuditionSample, params: params),
      ),
    );
  }

  double _sliderValue(
    TextEditingController controller,
    double min,
    double max,
    double fallback,
  ) {
    final typed = double.tryParse(controller.text.trim());
    if (typed == null || !typed.isFinite) return fallback;
    return typed.clamp(min, max);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clip = _provider == VoiceProvider.clip;
    final draft = _draft();
    final changed = draft == null || draft != widget.settings;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          HarnessSpace.sm,
          HarnessSpace.sheetGutter,
          HarnessSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Voice settings', style: HarnessText.sheetTitle(context)),
            const SizedBox(height: HarnessSpace.lg),
            const HarnessSectionHeader(label: 'Provider'),
            HarnessSegmented<VoiceProvider>(
              key: const Key('voice-provider'),
              options: const [
                (VoiceProvider.clip, 'Clip'),
                (VoiceProvider.live, 'Live'),
              ],
              value: _provider,
              onChanged: _changeProvider,
            ),
            const SizedBox(height: HarnessSpace.md),
            Text(
              clip
                  ? 'WAV clips · around one pause'
                  : 'WebRTC · continuous audio',
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.lg),
            if (clip) ..._clipFields(context) else ..._liveFields(context),
            const SizedBox(height: HarnessSpace.lg),
            const HarnessSectionHeader(label: 'Output'),
            _speakRepliesRow(context, clip),
            ..._outputVoiceSection(context, clip),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: HarnessSpace.sm),
                child: Text(
                  _error!,
                  key: const Key('voice-settings-error'),
                  style: HarnessText.caption(context)
                      .copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: HarnessSpace.xl),
            if (changed) _unsaved(context),
            const SizedBox(height: HarnessSpace.sm),
            HarnessPrimaryButton(
              key: const Key('voice-save'),
              label: 'Save',
              expand: true,
              onPressed: _save,
            ),
            const SizedBox(height: HarnessSpace.sm),
            HarnessSecondaryButton(
              key: const Key('voice-cancel'),
              label: 'Cancel',
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _speakRepliesRow(BuildContext context, bool clip) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Speak replies', style: HarnessText.rowTitle(context)),
                const SizedBox(height: 1),
                Text(
                  clip ? 'Device voice' : 'Provider voice',
                  style: HarnessText.caption(context),
                ),
              ],
            ),
          ),
          HarnessSwitch(
            key: const Key('voice-speak-replies'),
            value: _speakReplies,
            onChanged: (value) => setState(() => _speakReplies = value),
          ),
        ],
      ),
    );
  }

  /// `Unsaved changes` and the `Revert` that goes back to the saved settings.
  Widget _unsaved(BuildContext context) {
    return Row(
      key: const Key('voice-unsaved'),
      children: [
        Expanded(
          child: Text(
            'Unsaved changes',
            style: HarnessText.caption(context),
          ),
        ),
        HarnessTextButton(
          key: const Key('voice-revert'),
          label: 'Revert',
          dense: true,
          onPressed: _revert,
        ),
      ],
    );
  }

  /// The output voice: the device's own voices and how a reply is spoken in
  /// them, or the provider's realtime voice, which this client cannot try.
  List<Widget> _outputVoiceSection(BuildContext context, bool clip) {
    return [
      const HarnessSectionHeader(label: 'Output voice'),
      if (clip) _voiceChoice(context) else _liveVoiceField(context),
      if (clip) ..._parametersSection(context),
      ..._auditionSection(context, clip),
    ];
  }

  Widget _liveVoiceField(BuildContext context) {
    return _Field(
      key: const Key('voice-realtime-voice'),
      controller: _realtimeVoice,
      label: 'Voice',
      hint: 'Provider default',
      onChanged: () {
        setState(() => _error = null);
        unawaited(_audition.setAvailable(_auditionAvailable));
      },
    );
  }

  /// The voice field: the list the device reported, or, when it could not
  /// report one, an honest line and a name typed by hand.
  Widget _voiceChoice(BuildContext context) {
    final theme = Theme.of(context);
    final catalogue = _catalogue;
    if (catalogue.loading) {
      return Padding(
        padding: const EdgeInsets.only(top: HarnessSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Voice', style: HarnessText.label(context)),
            const SizedBox(height: 5),
            Container(
              key: const Key('voice-output-voice-loading'),
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  const HarnessActivity(radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Loading voices',
                      style: HarnessText.body(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (catalogue.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Field(
            key: const Key('voice-output-voice'),
            controller: _outputVoiceText,
            label: 'Voice',
            hint: 'Engine default',
            semanticsLabel: 'Voice',
            onChanged: () {
              setState(() {
                _outputVoice = null;
                _outputVoiceLocale.text = '';
              });
              _changedOutput();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: HarnessSpace.xs),
            child: Tooltip(
              message: catalogue.problem!,
              child: Text(
                'Voice list unavailable',
                key: const Key('voice-output-voice-problem'),
                style: HarnessText.caption(
                  context,
                ).copyWith(color: theme.colorScheme.error),
              ),
            ),
          ),
        ],
      );
    }
    final label = _voiceLabel(catalogue.voices);
    return Padding(
      padding: const EdgeInsets.only(top: HarnessSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Voice', style: HarnessText.label(context)),
          const SizedBox(height: 5),
          _Focusable(
            key: const Key('voice-output-voice'),
            label: 'Voice',
            value: label,
            onActivate: () => _pickVoice(catalogue.voices),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.body(context),
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the voice field says: the chosen voice, by the name the device
  /// reported, or `Default` for the engine's own.
  String _voiceLabel(List<VoiceOutputVoice> voices) {
    final chosen = _outputVoice;
    if (chosen == null) return 'Default';
    for (final voice in voices) {
      if (voice == chosen) return voice.label;
    }
    return chosen.label;
  }

  Future<void> _pickVoice(List<VoiceOutputVoice> voices) async {
    final chosen = await showHarnessMenu<int>(
      context: context,
      title: 'Voice',
      items: [
        const HarnessMenuItem(value: -1, label: 'Default'),
        for (var index = 0; index < voices.length; index++)
          HarnessMenuItem(value: index, label: voices[index].label),
      ],
    );
    if (chosen == null || !mounted) return;
    _chooseVoice(chosen < 0 ? null : voices[chosen]);
  }

  /// Rate, pitch and volume: only the ones the platform genuinely supports.
  /// The rate is offered only once the platform has reported the range it
  /// accepts, and a pitch or a volume only for the device's own engine.
  List<Widget> _parametersSection(BuildContext context) {
    final range = _catalogue.rateRange;
    return [
      if (range != null)
        _ParameterField(
          fieldKey: const Key('voice-rate-field'),
          sliderKey: const Key('voice-rate-slider'),
          label: 'Rate',
          controller: _rate,
          hint: range.normal.toStringAsFixed(2),
          min: range.min,
          max: range.max,
          fallback: range.normal,
          rangeText:
              '${range.min.toStringAsFixed(2)}–${range.max.toStringAsFixed(2)}',
          onChanged: _changedOutput,
          value: () => _sliderValue(_rate, range.min, range.max, range.normal),
        ),
      _ParameterField(
        fieldKey: const Key('voice-pitch-field'),
        sliderKey: const Key('voice-pitch-slider'),
        label: 'Pitch',
        controller: _pitch,
        hint: VoiceSettings.defaultSpeechPitch.toStringAsFixed(2),
        min: VoiceSettings.minSpeechPitch,
        max: VoiceSettings.maxSpeechPitch,
        fallback: VoiceSettings.defaultSpeechPitch,
        rangeText:
            '${VoiceSettings.minSpeechPitch.toStringAsFixed(2)}–'
            '${VoiceSettings.maxSpeechPitch.toStringAsFixed(2)}',
        onChanged: _changedOutput,
        value: () => _sliderValue(
          _pitch,
          VoiceSettings.minSpeechPitch,
          VoiceSettings.maxSpeechPitch,
          VoiceSettings.defaultSpeechPitch,
        ),
      ),
      _ParameterField(
        fieldKey: const Key('voice-volume-field'),
        sliderKey: const Key('voice-volume-slider'),
        label: 'Volume',
        controller: _volume,
        hint: VoiceSettings.defaultSpeechVolume.toStringAsFixed(2),
        min: VoiceSettings.minSpeechVolume,
        max: VoiceSettings.maxSpeechVolume,
        fallback: VoiceSettings.defaultSpeechVolume,
        rangeText:
            '${VoiceSettings.minSpeechVolume.toStringAsFixed(2)}–'
            '${VoiceSettings.maxSpeechVolume.toStringAsFixed(2)}',
        onChanged: _changedOutput,
        value: () => _sliderValue(
          _volume,
          VoiceSettings.minSpeechVolume,
          VoiceSettings.maxSpeechVolume,
          VoiceSettings.defaultSpeechVolume,
        ),
      ),
    ];
  }

  /// The audition control, its state and what went wrong, or the reason this
  /// provider has none.
  List<Widget> _auditionSection(BuildContext context, bool clip) {
    final theme = Theme.of(context);
    final state = _audition.state;
    final active = _audition.isActive;
    final failed = state == VoiceAuditionState.failed;
    final label = !clip
        ? 'Audition · unavailable'
        : failed
        ? 'Retry'
        : active
        ? 'Stop'
        : 'Audition';
    final status = switch (state) {
      VoiceAuditionState.loading => 'Loading',
      VoiceAuditionState.playing => 'Playing',
      VoiceAuditionState.stopped => 'Stopped',
      VoiceAuditionState.failed => 'Failed',
      VoiceAuditionState.unavailable => 'Unavailable',
      VoiceAuditionState.idle => null,
    };
    final tooltip = !clip
        ? 'Realtime voice · provider-defined'
        : switch (state) {
            VoiceAuditionState.loading => 'Audition · loading',
            VoiceAuditionState.playing => 'Audition · playing',
            VoiceAuditionState.stopped => 'Audition · stopped',
            VoiceAuditionState.failed => 'Audition · failed',
            _ => 'Audition · draft values',
          };
    return [
      const SizedBox(height: HarnessSpace.md),
      Row(
        children: [
          Semantics(
            button: true,
            enabled: clip,
            label: label,
            value: status,
            hint: tooltip,
            onTap: clip ? _auditionNow : null,
            excludeSemantics: true,
            child: Tooltip(
              message: tooltip,
              child: HarnessSecondaryButton(
                key: const Key('voice-audition'),
                label: label,
                onPressed: clip ? _auditionNow : null,
              ),
            ),
          ),
          if (status != null) ...[
            const SizedBox(width: HarnessSpace.md),
            Flexible(
              child: Text(
                status,
                key: const Key('voice-audition-status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HarnessText.caption(
                  context,
                ).copyWith(color: theme.colorScheme.onSurface),
              ),
            ),
          ],
        ],
      ),
      if (!clip)
        Padding(
          padding: const EdgeInsets.only(top: HarnessSpace.xs),
          child: Text(
            'Realtime voice · provider-defined',
            key: const Key('voice-audition-reason'),
            style: HarnessText.caption(context),
          ),
        ),
      if (failed && _audition.message != null)
        Padding(
          padding: const EdgeInsets.only(top: HarnessSpace.xs),
          child: Text(
            _audition.message!,
            key: const Key('voice-audition-error'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HarnessText.caption(
              context,
            ).copyWith(color: theme.colorScheme.error),
          ),
        ),
      if (clip) ..._problems(context),
    ];
  }

  /// What must be fixed before Save or Audition: one line a problem, naming
  /// the parameter, the value as it was typed and the range.
  List<Widget> _problems(BuildContext context) {
    final problems = _parameters.problems;
    if (problems.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      for (var index = 0; index < problems.length; index++)
        Padding(
          padding: const EdgeInsets.only(top: HarnessSpace.xs),
          child: Text(
            problems[index],
            key: Key('voice-output-problem-$index'),
            style: HarnessText.caption(
              context,
            ).copyWith(color: theme.colorScheme.error),
          ),
        ),
    ];
  }

  List<Widget> _clipFields(BuildContext context) {
    final derived = widget.settings
        .copyWith(speechEndpoint: '')
        .effectiveSpeechEndpoint(widget.harnessAddress);
    return [
      const HarnessSectionHeader(label: 'Delivery'),
      HarnessSegmented<ClipDelivery>(
        key: const Key('voice-delivery'),
        options: const [
          (ClipDelivery.transcript, 'Transcript'),
          (ClipDelivery.audioPrompt, 'Audio prompt'),
        ],
        value: _delivery,
        onChanged: (next) => setState(() => _delivery = next),
      ),
      if (_delivery == ClipDelivery.transcript) ...[
        const SizedBox(height: HarnessSpace.lg),
        const HarnessSectionHeader(label: 'Speech'),
        _Field(
          key: const Key('voice-speech-endpoint'),
          controller: _speechEndpoint,
          label: 'Speech endpoint',
          hint: derived.isEmpty ? 'https://host:8080/inference' : derived,
        ),
        _Field(
          key: const Key('voice-speech-model'),
          controller: _speechModel,
          label: 'Model',
          hint: 'whisper.cpp · empty',
        ),
        _Field(
          key: const Key('voice-speech-token'),
          controller: _speechToken,
          label: 'Token',
          hint: 'Bearer token · optional',
          obscure: true,
        ),
        _Field(
          key: const Key('voice-language'),
          controller: _language,
          label: 'Language',
          hint: 'ISO 639-1 · auto',
        ),
      ],
    ];
  }

  List<Widget> _liveFields(BuildContext context) {
    return [
      const HarnessSectionHeader(label: 'Realtime'),
      _Field(
        key: const Key('voice-realtime-endpoint'),
        controller: _realtimeEndpoint,
        label: 'Realtime endpoint',
        hint: 'https://api.openai.com/v1',
        onChanged: () {
          setState(() => _error = null);
          unawaited(_audition.setAvailable(_auditionAvailable));
        },
      ),
      _Field(
        key: const Key('voice-realtime-model'),
        controller: _realtimeModel,
        label: 'Realtime model',
        hint: 'gpt-live-1',
        onChanged: () {
          setState(() => _error = null);
          unawaited(_audition.setAvailable(_auditionAvailable));
        },
      ),
      _Field(
        key: const Key('voice-realtime-token'),
        controller: _realtimeToken,
        label: 'Token',
        hint: 'Ephemeral key or API key',
        obscure: true,
      ),
      _Field(
        key: const Key('voice-language'),
        controller: _language,
        label: 'Language',
        hint: 'ISO 639-1 · auto',
      ),
    ];
  }
}

String _oneLine(Object error) {
  final line = '$error'.trim().split('\n').first.trim();
  if (line.isEmpty) return error.runtimeType.toString();
  return line.length <= 160 ? line : '${line.substring(0, 159)}…';
}

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.semanticsLabel,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  /// What a screen reader calls the field, when the drawn label is not
  /// enough; the field is labelled by [label] otherwise.
  final String? semanticsLabel;

  /// Runs when the words change, for a field something else is drawn from.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final field = HarnessTextField(
      controller: controller,
      hint: hint,
      obscure: obscure,
      maxLines: 1,
      onChanged: onChanged == null ? null : (_) => onChanged!(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    );
    return Padding(
      padding: const EdgeInsets.only(top: HarnessSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: HarnessText.label(context)),
          const SizedBox(height: 5),
          if (semanticsLabel == null)
            field
          else
            Semantics(textField: true, label: semanticsLabel, child: field),
        ],
      ),
    );
  }
}

/// One speech parameter: its name, a field its value can be typed into, and
/// a slider over the range that is genuinely supported.
///
/// The slider only offers [min]–[max] — for the rate, the range the platform
/// itself reported — and the field is where a person can type anything.  What
/// is typed is validated rather than clamped, so a number outside the range
/// is said out loud and never reaches the engine.
class _ParameterField extends StatelessWidget {
  const _ParameterField({
    required this.fieldKey,
    required this.sliderKey,
    required this.label,
    required this.controller,
    required this.hint,
    required this.min,
    required this.max,
    required this.fallback,
    required this.rangeText,
    required this.onChanged,
    required this.value,
  });

  final Key fieldKey;
  final Key sliderKey;
  final String label;
  final TextEditingController controller;
  final String hint;
  final double min;
  final double max;
  final double fallback;

  /// The range, as the note under the slider words it.
  final String rangeText;
  final VoidCallback onChanged;

  /// The slider's own position, clamped into the offered range.
  final double Function() value;

  @override
  Widget build(BuildContext context) {
    final steps = ((max - min) / 0.05).round();
    final shown = value().toStringAsFixed(2);
    return Padding(
      padding: const EdgeInsets.only(top: HarnessSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(label, style: HarnessText.label(context)),
              ),
              SizedBox(
                width: 84,
                child: Semantics(
                  textField: true,
                  label: label,
                  child: HarnessTextField(
                    key: fieldKey,
                    controller: controller,
                    hint: hint,
                    maxLines: 1,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => onChanged(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11),
            ),
            child: Slider(
              key: sliderKey,
              min: min,
              max: max,
              divisions: steps < 2 ? null : steps,
              value: value(),
              label: shown,
              semanticFormatterCallback: (position) =>
                  '$label ${position.toStringAsFixed(2)}',
              onChanged: (position) {
                controller.text = position.toStringAsFixed(2);
                onChanged();
              },
            ),
          ),
          Text(
            '$label · $rangeText',
            key: fieldKey is ValueKey<String>
                ? Key('${(fieldKey as ValueKey<String>).value}-range')
                : null,
            style: HarnessText.caption(context),
          ),
        ],
      ),
    );
  }
}

/// A control of the sheet that a keyboard can reach with Tab and run with
/// Enter or Space, as a screen reader names it.
///
/// The widgets of the app's own kit are not focusable on their own (they are
/// drawn as a platform's controls, and a bottom sheet leaves focus to them);
/// this wrapper is the one focus node the sheet owns, so the order of the
/// fields, the voice, the audition and the buttons is a person's Tab order.
/// It does not hijack a text field: a field takes its own keys, and this only
/// answers a key while its own node has focus.
class _Focusable extends StatefulWidget {
  const _Focusable({
    super.key,
    required this.child,
    required this.label,
    this.value,
    this.onActivate,
  });

  final Widget child;

  /// What the control is called to a screen reader.
  final String label;

  /// What it holds, when it says something (`Default`, a voice's name).
  final String? value;

  /// Runs on a tap, Enter or Space; null makes the control unavailable.
  final VoidCallback? onActivate;

  @override
  State<_Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<_Focusable> {
  late final FocusNode _node = FocusNode(
    debugLabel: 'voice-settings · ${widget.label}',
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (widget.onActivate == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.select) {
      widget.onActivate!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.onActivate != null,
      label: widget.label,
      value: widget.value,
      onTap: widget.onActivate,
      excludeSemantics: true,
      child: Focus(
        focusNode: _node,
        onKeyEvent: _key,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onActivate,
          child: widget.child,
        ),
      ),
    );
  }
}
