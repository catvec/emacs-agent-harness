import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../acp/acp_message.dart';
import '../../models/transcript.dart';
import '../../state/interaction.dart';
import '../../state/session_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';

class InteractionCard extends StatefulWidget {
  const InteractionCard({super.key, required this.controller});
  final SessionController controller;

  @override
  State<InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<InteractionCard> {
  final _answer = TextEditingController();
  String? _currentKey;
  int _selectedQuestion = 0;
  String? _pattern;
  bool _busy = false;
  String? _selectedPattern;
  final Map<int, Future<Uint8List?>> _images = {};

  @override
  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _permission(String optionId) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.answerPermission(
      optionId,
      pattern: _selectedPattern?.trim().isEmpty == true
          ? null
          : _selectedPattern,
    );
  }

  Future<void> _question(String answer) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.answerQuestion(answer.trim());
  }

  Future<void> _editPattern() async {
    final value = await showHarnessTextPrompt(
      context: context,
      title: 'Path pattern',
      message: 'The lasting answer covers paths matching this pattern.',
      initial: _selectedPattern ?? '',
      confirmLabel: 'Use pattern',
    );
    if (value != null) setState(() => _selectedPattern = value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.controller.currentInteraction;
    if (request == null) return const SizedBox.shrink();
    final key =
        '${request.method}:${request.pendingId ?? request.questionId}:${request.title}';
    if (key != _currentKey) {
      _currentKey = key;
      _pattern = asString(request.harness['pattern']);
      _selectedPattern = _pattern;
      _answer.clear();
      _busy = false;
      _selectedQuestion = 0;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: request.isQuestion
          ? _buildQuestion(context, request)
          : _buildPermission(context, request),
    );
  }

  Widget _shell({
    required BuildContext context,
    required Color accent,
    required IconData icon,
    required String eyebrow,
    required String title,
    String? subtitle,
    required Widget body,
    VoidCallback? onDismiss,
  }) {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.4), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.07),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(17),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(icon, size: 17, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          eyebrow.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                            letterSpacing: 1.0,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onDismiss != null)
                    HarnessIconButton(
                      icon: Icons.close_rounded,
                      label: 'Dismiss',
                      size: 18,
                      onPressed: onDismiss,
                    ),
                ],
              ),
            ),
            Flexible(child: SingleChildScrollView(child: body)),
          ],
        ),
      ),
    );
  }

  Widget _buildPermission(BuildContext context, InteractionRequest request) {
    final theme = Theme.of(context);
    final accent = HarnessColors.amber;
    final input = _permissionInput(request.input);
    final patterns = request.harness['pattern'];
    final options = request.options;
    PermissionOption? option(String id) {
      for (final item in options) {
        if (item.id == id) return item;
      }
      return null;
    }

    final allow = option('allow-once');
    final deny = option('deny-once');
    final more = options
        .where((item) => item.id != 'allow-once' && item.id != 'deny-once')
        .toList();
    return _shell(
      context: context,
      accent: accent,
      icon: Icons.shield_outlined,
      eyebrow: 'Permission',
      title: request.title,
      subtitle: request.subtitle,
      onDismiss: _busy ? null : widget.controller.dismissPermission,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (input.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    input,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ),
            if (patterns is String && patterns.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: HarnessTap(
                  onTap: _busy ? null : _editPattern,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: accent.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.filter_alt_outlined,
                          size: 15,
                          color: accent,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _selectedPattern ?? patterns,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: HarnessPrimaryButton(
                    label: allow?.name ?? 'Allow once',
                    icon: Icons.check_rounded,
                    busy: _busy,
                    onPressed: _busy
                        ? null
                        : () => _permission(allow?.id ?? 'allow-once'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: HarnessSecondaryButton(
                    label: deny?.name ?? 'Deny',
                    icon: Icons.close_rounded,
                    onPressed: _busy
                        ? null
                        : () => _permission(deny?.id ?? 'deny-once'),
                  ),
                ),
              ],
            ),
            if (more.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: HarnessTextButton(
                  label: 'More options',
                  icon: Icons.more_horiz_rounded,
                  onPressed: _busy
                      ? null
                      : () async {
                          final choice =
                              await showHarnessMenu<PermissionOption>(
                                context: context,
                                title: 'Answer for…',
                                items: [
                                  for (final item in more)
                                    HarnessMenuItem(
                                      value: item,
                                      label: item.name,
                                      icon: item.isAllow
                                          ? Icons.check_rounded
                                          : Icons.block_rounded,
                                      destructive: !item.isAllow,
                                    ),
                                ],
                              );
                          if (choice != null && mounted) _permission(choice.id);
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _permissionInput(Object? input) {
    if (input == null) return '';
    if (input is String) return input;
    if (input is Map) {
      final map = asMap(input);
      final command = asString(map['command']);
      if (command != null && command.isNotEmpty) return command;
      final path = asString(map['path']);
      if (path != null && path.isNotEmpty) return path;
      final query = asString(map['query']);
      if (query != null && query.isNotEmpty) return query;
    }
    return prettyJson(input);
  }

  Widget _buildQuestion(BuildContext context, InteractionRequest request) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final options = request.questionOptions;
    final diagrams = request.diagrams;
    if (_selectedQuestion >= options.length) _selectedQuestion = 0;
    final selectedDiagram =
        diagrams.isNotEmpty && _selectedQuestion < diagrams.length
        ? diagrams[_selectedQuestion]
        : null;
    return _shell(
      context: context,
      accent: accent,
      icon: Icons.help_outline_rounded,
      eyebrow: 'Question',
      title: request.title,
      onDismiss: _busy ? null : widget.controller.cancelQuestion,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (request.cowboy.isNotEmpty) _CowboyNote(info: request.cowboy),
            for (var index = 0; index < options.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _QuestionChoice(
                  label: options[index],
                  selected: index == _selectedQuestion,
                  hasDiagram: index < diagrams.length,
                  onTap: _busy
                      ? null
                      : () => setState(() => _selectedQuestion = index),
                ),
              ),
            if (selectedDiagram != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: _DiagramView(
                  diagram: selectedDiagram,
                  maxHeight: 120,
                  image: asString(selectedDiagram['type']) == 'image'
                      ? (_images[_selectedQuestion] ??= widget.controller
                            .questionImage(_selectedQuestion))
                      : null,
                ),
              ),
            if (options.isNotEmpty) ...[
              const SizedBox(height: 4),
              HarnessPrimaryButton(
                label: 'Send answer',
                icon: Icons.check_rounded,
                expand: true,
                busy: _busy,
                onPressed: _busy
                    ? null
                    : () => _question(options[_selectedQuestion]),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: HarnessTextField(
                    controller: _answer,
                    hint: options.isEmpty
                        ? 'Type an answer'
                        : 'Or type an answer',
                    maxLines: 3,
                    minLines: 1,
                    onSubmitted: (_) => _question(_answer.text),
                  ),
                ),
                const SizedBox(width: 6),
                HarnessIconButton(
                  icon: Icons.arrow_upward_rounded,
                  label: 'Send typed answer',
                  onPressed: _busy
                      ? null
                      : () {
                          final text = _answer.text.trim();
                          if (text.isNotEmpty) _question(text);
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionChoice extends StatelessWidget {
  const _QuestionChoice({
    required this.label,
    required this.selected,
    required this.hasDiagram,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool hasDiagram;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.07)
                : theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: selected ? 1.3 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 17,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    fontSize: 13.5,
                  ),
                ),
              ),
              if (hasDiagram)
                Icon(
                  Icons.image_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.55,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagramView extends StatelessWidget {
  const _DiagramView({
    required this.diagram,
    required this.image,
    this.maxHeight = 210,
  });
  final JsonMap diagram;
  final Future<Uint8List?>? image;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final type = asString(diagram['type']);
    if (type == 'ascii') {
      final text = asStringOr(diagram['text'], '');
      return Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF17171A)
              : const Color(0xFFF1EDE6),
          borderRadius: BorderRadius.circular(9),
        ),
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                height: 1.25,
              ),
            ),
          ),
        ),
      );
    }
    if (image == null) return const SizedBox.shrink();
    return FutureBuilder<Uint8List?>(
      future: image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            child: Center(child: HarnessActivity(radius: 9)),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Text(
              'The image could not be loaded.',
              style: TextStyle(fontSize: 12),
            ),
          );
        }
        final mime = asString(diagram['mime']) ?? 'image/png';
        if (mime.contains('svg')) {
          return Container(
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(8),
            color: Colors.white,
            child: SvgPicture.memory(bytes, fit: BoxFit.contain),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            height: maxHeight,
            errorBuilder: (_, _, _) => const SizedBox(
              height: 80,
              child: Center(child: Text('The image could not be displayed.')),
            ),
          ),
        );
      },
    );
  }
}

class _CowboyNote extends StatelessWidget {
  const _CowboyNote({required this.info});
  final JsonMap info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = asString(info['preview']);
    final choices = asMapList(info['choices']).take(4).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: HarnessColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: HarnessColors.amber.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bolt_rounded,
                size: 13,
                color: HarnessColors.amber,
              ),
              const SizedBox(width: 4),
              Text(
                'Cold prompt cache',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: HarnessColors.amber,
                  fontSize: 10.5,
                ),
              ),
              if (preview != null && preview.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                  ),
                ),
              ],
            ],
          ),
          if (choices.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                for (final choice in choices)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${asStringOr(choice['label'], asStringOr(choice['choice'], ''))} ${asStringOr(choice['cost-text'], '')}'
                          .trim(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9.5,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
