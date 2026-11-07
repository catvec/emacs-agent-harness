import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/drafts.dart';
import '../../state/prompt_attachment.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/platform_style.dart';
import '../theme/harness_theme.dart';
import 'image_attachments.dart';

class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.running,
    required this.cancelling,
    required this.canAttach,
    this.enabled = true,
    this.canVoice = false,
    this.onVoice,
    this.awaitingAnswer = false,
    this.offline = false,
    this.drafts,
    this.draftKey = '',
    this.footer,
    this.tight = false,
    this.header,
    this.focusNode,
    this.hint,
    this.textController,
  });

  /// Takes the message to send.  Whether it was taken: where it was not
  /// (there is no connection to send it over), what was typed stays in the
  /// field, to be sent when it can be.
  final bool Function(String text, List<PromptAttachment> attachments) onSend;
  final VoidCallback onStop;
  final bool running;
  final bool cancelling;
  final bool canAttach;
  final bool enabled;

  /// Whether the screen offers the voice mode: a session that can take a
  /// message, with no question waiting to be answered on screen first.
  final bool canVoice;
  final VoidCallback? onVoice;
  final bool awaitingAnswer;

  /// There is no connection to the harness at the moment: what is typed is
  /// kept, and sending waits for the connection.
  final bool offline;

  /// Where the text of the field is kept, under [draftKey], so that it
  /// outlives this widget: the field starts from what was left there, keeps
  /// it as it changes, and follows what is put there from outside (a message
  /// that was not sent after all comes back).
  final DraftStore? drafts;
  final String draftKey;

  /// A row under the field: what decides how the next message is handled,
  /// and how the conversation stands.  Without one, a line of help.
  final Widget? footer;

  /// The keyboard leaves a strip of a page on a small phone at twice the
  /// text: the field ends at two lines and the reply bar keeps one.
  final bool tight;

  /// What stands over the field: the message or thread this one answers,
  /// when it answers one.  It is part of the composer, so the keyboard
  /// lifts it with the field instead of covering it.
  final Widget? header;

  /// The field's focus, for a caller that has to give it: a button that asks
  /// for something to be typed (a task's *Send back*) puts the cursor here.
  /// Without one the field keeps a focus of its own.
  final FocusNode? focusNode;

  /// What the empty field says a message does in this conversation, in place
  /// of the usual line: that it sends a task in review back, say.  What is
  /// so before it (no connection, an answer to give, a turn at work) is
  /// still said first.
  final String? hint;

  /// A controller the caller keeps, to restore a failed message into the
  /// field; the field disposes only one it made itself.
  final TextEditingController? textController;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  late final TextEditingController _text = widget.textController ??
      TextEditingController(text: widget.drafts?.text(widget.draftKey) ?? '');
  bool get _ownsText => widget.textController == null;
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  final _attachments = <PromptAttachment>[];
  String? _attachmentError;
  bool _picking = false;

  bool get _canSend =>
      widget.enabled &&
      !widget.running &&
      (_text.text.trim().isNotEmpty || _attachments.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _text.addListener(_rememberDraft);
    widget.drafts?.addListener(_followDraft);
  }

  @override
  void didUpdateWidget(MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Something waits to be answered, which is not here: the keyboard that
    // was up for this field is of no use, and, where the field goes out of
    // sight, would stay.
    if (widget.awaitingAnswer && !oldWidget.awaitingAnswer) {
      _focus.unfocus();
    }
    // A composer that moves to another draft (the workspace switched to
    // another thread) keeps each draft where it belongs: save what was
    // typed under the old key, then show the new key's text.  Without
    // this an external controller carries one thread's words to another.
    if (oldWidget.draftKey != widget.draftKey) {
      oldWidget.drafts?.setText(oldWidget.draftKey, _text.text);
      final stored = widget.drafts?.text(widget.draftKey) ?? '';
      if (stored != _text.text) {
        _text.value = TextEditingValue(
          text: stored,
          selection: TextSelection.collapsed(offset: stored.length),
        );
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    widget.drafts?.removeListener(_followDraft);
    _text.removeListener(_rememberDraft);
    if (_ownsText) _text.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  /// What is typed is kept in the store.
  void _rememberDraft() => widget.drafts?.setText(widget.draftKey, _text.text);

  /// What was put in the store from outside is shown.  (What this field
  /// keeps there itself is the text it holds already.)
  void _followDraft() {
    final stored = widget.drafts?.text(widget.draftKey) ?? '';
    if (stored == _text.text) return;
    _text.value = TextEditingValue(
      text: stored,
      selection: TextSelection.collapsed(offset: stored.length),
    );
    setState(() {});
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _text.text;
    final attachments = List<PromptAttachment>.of(_attachments);
    // Only a message that was taken is cleared from the field.
    if (!widget.onSend(text, attachments)) return;
    _text.clear();
    setState(() {
      _attachments.clear();
      _attachmentError = null;
    });
    _focus.requestFocus();
  }

  Future<void> _pickImages() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _attachmentError = null;
    });
    try {
      final loaded = await pickImageAttachments(
        room: maxImageAttachments - _attachments.length,
      );
      if (loaded.isEmpty || !mounted) return;
      setState(() => _attachments.addAll(loaded));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _attachmentError =
            'This platform cannot open the photo picker: ${error.toString().split('\n').first}',
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Whether there is a physical keyboard to say how to send with.
  bool get _keyboardHint =>
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux) &&
      MediaQuery.sizeOf(context).width >= 600;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final desktop =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows;
    if (!desktop) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The button that adds pictures, when the harness takes them.
  Widget _attach(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(right: 4, bottom: 2),
    child: Semantics(
      button: true,
      label: 'Attach images',
      child: GestureDetector(
        key: const Key('composer-attach'),
        onTap: widget.running ? null : _pickImages,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            shape: BoxShape.circle,
          ),
          child: _picking
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
      ),
    ),
  );

  /// The field a message is written in.  It is given the whole width on a
  /// narrow screen, where the controls take a row of their own rather than
  /// squeeze the words into a column of one letter.
  Widget _field(ThemeData theme, {required int maxLines}) {
    final hint = widget.offline
        ? 'Reconnecting… what you type is kept'
        : widget.awaitingAnswer
        ? 'Answer above to continue'
        : widget.running
        ? 'The agent is working…'
        : widget.hint ??
              (_keyboardHint ? 'Message · Enter to send' : 'Message');
    return Focus(
      onKeyEvent: _onKey,
      child: HarnessTextField(
        key: const Key('composer-field'),
        controller: _text,
        focusNode: _focus,
        hint: hint,
        maxLines: maxLines,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        onChanged: (_) => setState(() {}),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 11,
        ),
      ),
    );
  }

  Widget _voice(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(right: 6, bottom: 2),
    child: _RoundActionButton(
      key: const Key('composer-voice'),
      icon: CupertinoIcons.mic,
      materialIcon: Icons.mic_rounded,
      color: theme.colorScheme.surfaceContainerHigh,
      foreground: theme.colorScheme.onSurfaceVariant,
      label: 'Voice mode',
      onTap: widget.enabled ? widget.onVoice : null,
    ),
  );

  Widget _primary(ThemeData theme) {
    if (widget.running) {
      return _RoundActionButton(
        icon: CupertinoIcons.stop_fill,
        materialIcon: Icons.stop_rounded,
        color: theme.colorScheme.error,
        label: 'Stop the turn',
        busy: widget.cancelling,
        onTap: widget.cancelling ? null : widget.onStop,
      );
    }
    return _RoundActionButton(
      key: const Key('composer-send'),
      icon: CupertinoIcons.arrow_up,
      materialIcon: Icons.arrow_upward_rounded,
      color: _canSend
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHigh,
      foreground: _canSend ? Colors.white : theme.colorScheme.onSurfaceVariant,
      label: 'Send message',
      onTap: _canSend ? _send : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cupertino = HarnessStyle.isCupertino(context);
    // A phone at a large text size has no room for a line of advice under the
    // controls: the words being written keep that height instead.
    final largeText = MediaQuery.textScalerOf(context).scale(15) > 19.5;
    final compact =
        MediaQuery.sizeOf(context).width < 380 || largeText || widget.tight;
    final background = cupertino
        ? CupertinoTheme.of(context).barBackgroundColor
        : theme.colorScheme.surfaceContainerLowest;
    return Container(
      decoration: BoxDecoration(
        color: background,
        border: Border(
          top: BorderSide(
            color: cupertino
                ? CupertinoColors.separator.resolveFrom(context)
                : theme.colorScheme.outlineVariant,
            width: cupertino ? 0.5 : 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.header != null) widget.header!,
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    height: 58,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _attachments.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final attachment = _attachments[index];
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                attachment.bytes,
                                width: 58,
                                height: 58,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  width: 58,
                                  height: 58,
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: -4,
                              top: -4,
                              child: GestureDetector(
                                onTap: () => setState(
                                  () => _attachments.removeAt(index),
                                ),
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.colorScheme.outlineVariant,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 13,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              if (_attachmentError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _attachmentError!,
                    style: HarnessText.caption(context)
                        .copyWith(color: theme.colorScheme.error),
                  ),
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  // On a narrow phone, or at a large text size, the controls
                  // beside the field leave it too little room: a word as
                  // short as Message breaks.  They take a row of their own,
                  // and the field keeps the width for a sentence.
                  final compact =
                      constraints.maxWidth < 360 || largeText || widget.tight;
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Below a page's worth of room, the field stops at
                        // two lines and scrolls its words rather than push
                        // the controls under the keyboard.
                        _field(theme, maxLines: widget.tight ? 2 : 3),
                        const SizedBox(height: 6),
                        Row(
                          key: const Key('composer-controls'),
                          children: [
                            if (widget.canAttach) _attach(theme),
                            if (widget.canVoice) _voice(theme),
                            const Spacer(),
                            _primary(theme),
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (widget.canAttach) _attach(theme),
                      Expanded(child: _field(theme, maxLines: 5)),
                      if (widget.canVoice) _voice(theme),
                      const SizedBox(width: 6),
                      _primary(theme),
                    ],
                  );
                },
              ),
              if (widget.footer != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: widget.footer!,
                )
              else if (!widget.running && _text.text.isEmpty && !compact)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6),
                  child: Text(
                    _keyboardHint
                        ? 'Enter to send · Shift + Enter for a new line'
                        : 'The harness may ask before it runs a tool.',
                    style: HarnessText.caption(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    super.key,
    required this.icon,
    required this.materialIcon,
    required this.color,
    required this.label,
    this.foreground = Colors.white,
    this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final IconData materialIcon;
  final Color color;
  final Color foreground;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final effective = onTap == null ? color.withValues(alpha: 0.5) : color;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: effective,
            shape: BoxShape.circle,
            boxShadow: onTap == null
                ? null
                : [
                    BoxShadow(
                      color: effective.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: busy
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                )
              : Icon(
                  cupertino ? icon : materialIcon,
                  size: cupertino ? 20 : 22,
                  color: foreground,
                ),
        ),
      ),
    );
  }
}
