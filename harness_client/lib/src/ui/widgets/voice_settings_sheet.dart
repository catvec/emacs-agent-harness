import 'package:flutter/material.dart';

import '../../voice/voice_settings.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';

/// The setup of a voice screen: which provider it uses, and what that
/// provider needs to hear and speak.
Future<VoiceSettings?> showVoiceSettingsSheet(
  BuildContext context, {
  required VoiceSettings settings,
  required String harnessAddress,
}) {
  return showHarnessSheet<VoiceSettings>(
    context: context,
    builder: (sheetContext) =>
        VoiceSettingsSheet(settings: settings, harnessAddress: harnessAddress),
  );
}

class VoiceSettingsSheet extends StatefulWidget {
  const VoiceSettingsSheet({
    super.key,
    required this.settings,
    required this.harnessAddress,
  });

  final VoiceSettings settings;
  final String harnessAddress;

  @override
  State<VoiceSettingsSheet> createState() => _VoiceSettingsSheetState();
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
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _speechEndpoint,
      _speechModel,
      _speechToken,
      _language,
      _realtimeEndpoint,
      _realtimeModel,
      _realtimeToken,
      _realtimeVoice,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  VoiceSettings _draft() => widget.settings.copyWith(
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
  );

  void _save() {
    final draft = _draft();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clip = _provider == VoiceProvider.clip;
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
              onChanged: (next) => setState(() {
                _provider = next;
                _error = null;
              }),
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Speak replies',
                          style: HarnessText.rowTitle(context),
                        ),
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
            ),
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
      ),
      _Field(
        key: const Key('voice-realtime-model'),
        controller: _realtimeModel,
        label: 'Realtime model',
        hint: 'gpt-live-1',
      ),
      _Field(
        key: const Key('voice-realtime-token'),
        controller: _realtimeToken,
        label: 'Token',
        hint: 'Ephemeral key or API key',
        obscure: true,
      ),
      _Field(
        key: const Key('voice-realtime-voice'),
        controller: _realtimeVoice,
        label: 'Voice',
        hint: 'Provider default',
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

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: HarnessSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: HarnessText.label(context)),
          const SizedBox(height: 5),
          HarnessTextField(
            controller: controller,
            hint: hint,
            obscure: obscure,
            maxLines: 1,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
          ),
        ],
      ),
    );
  }
}
