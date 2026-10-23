import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../acp/acp_message.dart';
import '../../models/transcript.dart';
import '../../state/interaction.dart';
import '../../state/session_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';
import 'markdown_view.dart';

class InteractionCard extends StatefulWidget {
  const InteractionCard({super.key, required this.controller});
  final SessionController controller;

  @override
  State<InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<InteractionCard> {
  final _answer = TextEditingController();
  final _scroll = ScrollController();
  String? _currentKey;

  /// The option picked of a question of one choice; of one of several, the
  /// option last tapped, whose diagram is shown.
  int _selectedQuestion = 0;

  /// The options ticked of a question of several choices.
  final Set<int> _ticked = <int>{};
  String? _pattern;
  bool _busy = false;
  String? _selectedPattern;
  final Map<int, Future<Uint8List?>> _images = {};

  @override
  void dispose() {
    _answer.dispose();
    _scroll.dispose();
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
    _answered();
  }

  Future<void> _question(String answer) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.controller.answerQuestion(answer.trim());
    _answered();
  }

  /// The answer is given.  If the card is still here, the answer did not
  /// go through and the request is shown again: it can be answered again.
  void _answered() {
    if (mounted && _busy) setState(() => _busy = false);
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
      _ticked.clear();
      // Another request: its pictures are not the last one's, and it is
      // read from its first line.
      _images.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: request.isQuestion
          ? _buildQuestion(context, request)
          : _buildPermission(context, request),
    );
  }

  /// The frame of a request: what it is (a header), what it says and offers
  /// (the [body], which scrolls when it is longer than the room there is),
  /// and, for what is answered with more than a button, the [footer] where
  /// the answer is given, which does not scroll away.  It takes the room it
  /// is given and no more, whatever the room: a request is always
  /// answerable.
  ///
  /// The body and the footer are told whether the room is [_stickyFooterRoom]
  /// or less, too little to keep much in sight beside a header and a footer
  /// (a small phone with its keyboard up): they leave the footer what must
  /// stay in place, a field that has focus, and move the rest into the body.
  ///
  /// A [title] is read in the header, up to three lines of it; a request
  /// that has none says what it has in its body, whole.
  Widget _shell({
    required BuildContext context,
    required Color accent,
    required IconData icon,
    required String eyebrow,
    String? title,
    String? subtitle,
    required Widget Function(bool tight) body,
    Widget Function(bool tight)? footer,
    VoidCallback? onDismiss,
  }) {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tight = constraints.maxHeight < _stickyFooterRoom;
          return Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: accent.withValues(alpha: 0.4),
                width: 1.2,
              ),
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
                _header(
                  context,
                  accent: accent,
                  icon: icon,
                  eyebrow: eyebrow,
                  title: title,
                  subtitle: subtitle,
                  onDismiss: onDismiss,
                ),
                Flexible(
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: body(tight),
                    ),
                  ),
                ),
                if (footer != null)
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                    child: footer(tight),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Less height than this has no room to keep the footer in sight beside
  /// the header and still show something of the body.
  static const _stickyFooterRoom = 340.0;

  Widget _header(
    BuildContext context, {
    required Color accent,
    required IconData icon,
    required String eyebrow,
    String? title,
    String? subtitle,
    VoidCallback? onDismiss,
  }) {
    final line = title == null;
    return Container(
      padding: EdgeInsets.fromLTRB(14, line ? 6 : 12, 6, line ? 6 : 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(17)),
      ),
      child: Row(
        // The icon is level with the first line of text, not the middle of
        // however many lines there are.
        crossAxisAlignment: line
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: 1,
                bottom: onDismiss == null || line ? 0 : 3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow.toUpperCase(),
                    style: HarnessText.label(context).copyWith(color: accent),
                  ),
                  if (title != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.rowTitle(context)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context),
                    ),
                  ],
                ],
              ),
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
      body: (_) => Padding(
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
                    style: HarnessText.mono(context),
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
                            style: HarnessText.mono(context),
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
    final multiple = request.allowMultiple;
    final diagrams = request.diagrams;
    if (_selectedQuestion >= options.length) _selectedQuestion = 0;
    _ticked.removeWhere((index) => index >= options.length);
    final selectedDiagram =
        diagrams.isNotEmpty && _selectedQuestion < diagrams.length
        ? diagrams[_selectedQuestion]
        : null;
    // A line of words is the title of the card and stays in sight while the
    // options scroll; anything longer is read in the body, whole.
    final question = request.title;
    final short = isShortQuestion(question);
    // One choice: the option picked is what is sent.  Several: what is
    // ticked and what is typed, so there is something to send once either
    // holds anything -- the field is listened to, for the button to know.
    Widget sendAnswer() => multiple
        ? ListenableBuilder(
            listenable: _answer,
            builder: (context, _) => HarnessPrimaryButton(
              label: _ticked.isEmpty
                  ? 'Send answer'
                  : 'Send answer (${_ticked.length})',
              icon: Icons.check_rounded,
              expand: true,
              busy: _busy,
              onPressed:
                  _busy || (_ticked.isEmpty && _answer.text.trim().isEmpty)
                  ? null
                  : _sendTyped,
            ),
          )
        : HarnessPrimaryButton(
            label: 'Send answer',
            icon: Icons.check_rounded,
            expand: true,
            busy: _busy,
            onPressed: _busy
                ? null
                : () => _question(options[_selectedQuestion]),
          );
    return _shell(
      context: context,
      accent: accent,
      icon: Icons.help_outline_rounded,
      eyebrow: 'Question',
      title: short ? question : null,
      onDismiss: _busy ? null : widget.controller.cancelQuestion,
      body: (tight) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!short)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: HarnessMarkdown(text: question, compact: true),
              ),
            if (request.cowboy.isNotEmpty) _CowboyNote(info: request.cowboy),
            for (var index = 0; index < options.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _QuestionChoice(
                  label: options[index],
                  multiple: multiple,
                  selected: multiple
                      ? _ticked.contains(index)
                      : index == _selectedQuestion,
                  // The diagram shown is the one of the option tapped last,
                  // ticked or not: outlined, when there are diagrams to tell
                  // which of the options it is the diagram of.
                  focused:
                      multiple &&
                      diagrams.isNotEmpty &&
                      index == _selectedQuestion,
                  hasDiagram: index < diagrams.length,
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _selectedQuestion = index;
                          if (multiple && !_ticked.add(index)) {
                            _ticked.remove(index);
                          }
                        }),
                ),
              ),
            if (selectedDiagram != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: _DiagramView(
                  diagram: selectedDiagram,
                  maxHeight: 200,
                  image: asString(selectedDiagram['type']) == 'image'
                      ? (_images[_selectedQuestion] ??= widget.controller
                            .questionImage(_selectedQuestion))
                      : null,
                ),
              ),
            // Where there is room it is in the footer, in sight.
            if (tight && options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: sendAnswer(),
              ),
          ],
        ),
      ),
      // Where it is answered: the option chosen, or what was typed.  Always
      // in reach, with the keyboard up too.  The field stays where it is
      // whatever the room, or it would lose the focus it is typed in.
      footer: (tight) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!tight && options.isNotEmpty) ...[
              sendAnswer(),
              const SizedBox(height: 10),
            ],
            Row(
              key: const ValueKey('question-typed-answer'),
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: HarnessTextField(
                    key: const Key('question-answer-field'),
                    controller: _answer,
                    // Beside what is ticked the words are a note to it.
                    hint: options.isEmpty
                        ? 'Type an answer'
                        : multiple && _ticked.isNotEmpty
                        ? 'Add a note'
                        : 'Or type an answer',
                    maxLines: 3,
                    minLines: 1,
                    // Not a field for lines: the keyboard's key says send,
                    // and it does.
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendTyped(),
                  ),
                ),
                const SizedBox(width: 6),
                HarnessIconButton(
                  icon: Icons.arrow_upward_rounded,
                  label: 'Send typed answer',
                  onPressed: _busy ? null : _sendTyped,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Answer with what was typed, if anything was; for a question of several
  /// choices, with the options ticked too (see [multipleAnswer]).  Nothing
  /// is sent when there is nothing to send.
  void _sendTyped() {
    final request = widget.controller.currentInteraction;
    final typed = _answer.text.trim();
    final text = request != null && request.allowMultiple
        ? multipleAnswer(request.questionOptions, _ticked, typed)
        : typed;
    if (text.isNotEmpty) _question(text);
  }
}

/// Whether [question] is a line of plain words: one the header of the card
/// shows whole.  A longer one, or one with lines or Markdown in it, is
/// read in the body of the card, where it scrolls.
bool isShortQuestion(String question) {
  final text = question.trim();
  return text.length <= 140 &&
      !text.contains('\n') &&
      !RegExp(r'[`*#>\[\]|]|\b_|_\b').hasMatch(text);
}

/// An option of a question: the one picked, a radio button, when only one may
/// be; one of several that may be [multiple], a check box, ticked when
/// [selected].  The option whose diagram shows is [focused], outlined, when
/// it is not ticked and has no other mark to say so.
class _QuestionChoice extends StatelessWidget {
  const _QuestionChoice({
    required this.label,
    required this.selected,
    required this.hasDiagram,
    required this.onTap,
    this.multiple = false,
    this.focused = false,
  });

  final String label;
  final bool selected;
  final bool hasDiagram;
  final VoidCallback? onTap;
  final bool multiple;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outlined = focused && !selected;
    return Semantics(
      // A check box says whether it is ticked; a radio button, whether it is
      // the one picked.
      button: !multiple,
      selected: multiple ? null : selected,
      checked: multiple ? selected : null,
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
                  : outlined
                  ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                  : theme.colorScheme.outlineVariant,
              width: selected || outlined ? 1.3 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                multiple
                    ? (selected
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded)
                    : (selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded),
                size: 17,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                // The label is said once: by the option, above.
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: HarnessText.body(context).copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      height: 1.3,
                    ),
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
                fontSize: 11,
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
    final preview = asString(info['preview']);
    // The ways to go on, and what each would cost: a table, a way to a row,
    // with the cost at the edge.
    final choices = [
      for (final choice in asMapList(info['choices']).take(4))
        (
          asStringOr(choice['label'], asStringOr(choice['choice'], '')),
          asStringOr(choice['cost-text'], ''),
        ),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: HarnessColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: HarnessColors.amber.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bolt_rounded,
                size: 15,
                color: HarnessColors.amber,
              ),
              const SizedBox(width: 6),
              Text(
                'Cold prompt cache',
                style: HarnessText.meta(context).copyWith(
                  fontWeight: FontWeight.w700,
                  color: HarnessColors.amber,
                ),
              ),
              if (preview != null && preview.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.caption(context),
                  ),
                ),
              ],
            ],
          ),
          for (final (label, cost) in choices)
            if (label.isNotEmpty || cost.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(label, style: HarnessText.caption(context)),
                    ),
                    if (cost.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(cost, style: HarnessText.meta(context)),
                    ],
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
