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
    this.awaitingAnswer = false,
    this.offline = false,
    this.drafts,
    this.draftKey = '',
    this.footer,
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

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  late final TextEditingController _text = TextEditingController(
    text: widget.drafts?.text(widget.draftKey) ?? '',
  );
  final _focus = FocusNode();
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
  void dispose() {
    widget.drafts?.removeListener(_followDraft);
    _text.removeListener(_rememberDraft);
    _text.dispose();
    _focus.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cupertino = HarnessStyle.isCupertino(context);
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.canAttach)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, bottom: 2),
                      child: Semantics(
                        button: true,
                        label: 'Attach images',
                        child: GestureDetector(
                          onTap: widget.running ? null : _pickImages,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                              shape: BoxShape.circle,
                            ),
                            child: _picking
                                ? const Padding(
                                    padding: EdgeInsets.all(11),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.add_photo_alternate_outlined,
                                    size: 20,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: HarnessTextField(
                        key: const Key('composer-field'),
                        controller: _text,
                        focusNode: _focus,
                        hint: widget.offline
                            ? 'Reconnecting… what you type is kept'
                            : widget.awaitingAnswer
                            ? 'Answer above to continue'
                            : widget.running
                            ? 'The agent is working…'
                            : _keyboardHint
                            ? 'Message the harness · Enter to send'
                            : 'Message the harness',
                        maxLines: 5,
                        minLines: 1,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        onChanged: (_) => setState(() {}),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 11,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (widget.running)
                    _RoundActionButton(
                      icon: CupertinoIcons.stop_fill,
                      materialIcon: Icons.stop_rounded,
                      color: theme.colorScheme.error,
                      label: 'Stop the turn',
                      busy: widget.cancelling,
                      onTap: widget.cancelling ? null : widget.onStop,
                    )
                  else
                    _RoundActionButton(
                      key: const Key('composer-send'),
                      icon: CupertinoIcons.arrow_up,
                      materialIcon: Icons.arrow_upward_rounded,
                      color: _canSend
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHigh,
                      foreground: _canSend
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                      label: 'Send message',
                      onTap: _canSend ? _send : null,
                    ),
                ],
              ),
              if (widget.footer != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: widget.footer!,
                )
              else if (!widget.running && _text.text.isEmpty)
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
          width: 42,
          height: 42,
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
