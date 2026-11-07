import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/review_composer.dart';
import '../widgets/review_threads.dart';
import 'review_file_screen.dart';

/// One thread of a review: its conversation, its state, and the box to write
/// in.
///
/// A reply is a draft kept by the harness (`add-comment`), and goes with the
/// feedback or the replies the review sends; a reply in a closed thread
/// opens it again.  The box is at the bottom so the keyboard never covers
/// it, and what was typed survives leaving the page: the draft holds it.
class ReviewThreadScreen extends StatefulWidget {
  const ReviewThreadScreen({
    super.key,
    required this.controller,
    required this.threadId,
  });

  final ReviewController controller;
  final String threadId;

  @override
  State<ReviewThreadScreen> createState() => _ReviewThreadScreenState();
}

class _ReviewThreadScreenState extends State<ReviewThreadScreen> {
  late String _threadId = widget.threadId;
  ReviewThread? _thread;
  ReviewDraft? _draft;
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _thread = widget.controller.thread(_threadId);
    final thread = _thread;
    if (thread != null) {
      _draft = widget.controller.replyDraft(thread);
      _text.text = _draft?.text ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  ReviewThread? get _current => widget.controller.thread(_threadId) ?? _thread;

  /// The next or previous thread of the review, as the list shows them.
  void _stepThread(int direction) {
    final next = widget.controller.stepThread(direction, fromId: _threadId);
    if (next == null || next.id == _threadId) return;
    setState(() {
      _threadId = next.id;
      _thread = next;
      _draft = widget.controller.replyDraft(next);
      _text.text = _draft?.text ?? '';
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
    _focus.unfocus();
  }

  Future<void> _reply({ReviewComment? to}) async {
    final thread = _current;
    final draft = _draft;
    if (thread == null || draft == null) return;
    if (_text.text.trim().isEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('No words')));
      return;
    }
    draft.text = _text.text;
    if (to != null) draft.replyTo = to.id;
    final saved = await widget.controller.saveDraft(draft.key);
    if (!mounted) return;
    if (saved) {
      _text.clear();
      setState(() {});
    }
  }

  void _quote(ReviewThread thread, ReviewComment comment) {
    final draft = _draft;
    if (draft == null) return;
    draft.replyTo = comment.id;
    draft.text = '${comment.quoteMarkdown}\n\n';
    setState(() {
      _text.text = draft.text;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
    _focus.requestFocus();
  }

  Future<void> _showPlace(ReviewThread thread) async {
    final location = thread.location;
    if (location == null || location.file.isEmpty) return;
    // The lines a comment names are those of the version it was written at:
    // read that version first, even when the file is gone or renamed now.
    if (!await widget.controller.showRevision(thread.revision)) return;
    if (!mounted) return;
    final file = widget.controller.changes?.file(location.file);
    if (file == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('File unavailable')),
      );
      return;
    }
    widget.controller.selectFile(file.path);
    await Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewFileScreen(
          controller: widget.controller,
          path: file.path,
          focusThreadId: thread.id,
        ),
      ),
    );
  }

  void _openFeedback() {
    Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => ReviewFeedbackScreen(controller: widget.controller),
      ),
    );
  }

  /// The file and line of a thread, short enough for the header: the whole
  /// path is in the card below, where there is room for it.
  String _placeLabel(ReviewLocation? location) {
    if (location == null || location.file.isEmpty) return 'The change';
    final name = location.file.split('/').last;
    if (location.line == null) return name;
    final end = location.endLine;
    return end != null && end != location.line
        ? '$name:${location.line}–$end'
        : '$name:${location.line}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final thread = _current;
        if (thread == null) {
          return HarnessPage(
            title: 'Thread',
            body: const HarnessEmptyState(
              icon: Icons.forum_outlined,
              title: 'No thread',
              message: 'Not in this review',
            ),
          );
        }
        _thread = thread;
        _draft ??= widget.controller.replyDraft(thread);
        final location = thread.location;
        return HarnessPage(
          title: 'Thread',
          subtitle: Text(
            _placeLabel(location),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            HarnessIconButton(
              key: const ValueKey('thread-previous'),
              icon: Icons.keyboard_arrow_up_rounded,
              label: 'Previous thread',
              onPressed: widget.controller.threads.length <= 1
                  ? null
                  : () => _stepThread(-1),
            ),
            HarnessIconButton(
              key: const ValueKey('thread-next'),
              icon: Icons.keyboard_arrow_down_rounded,
              label: 'Next thread',
              onPressed: widget.controller.threads.length <= 1
                  ? null
                  : () => _stepThread(1),
            ),
          ],
          body: ReviewThreadConversation(
            controller: widget.controller,
            thread: thread,
            onReply: (comment) {
              _draft?.replyTo = comment.id;
              _focus.requestFocus();
            },
            onQuote: (comment) => _quote(thread, comment),
            onShowPlace: () => _showPlace(thread),
          ),
          bottom: SafeArea(
            top: false,
            child: _ReplyBar(
              controller: widget.controller,
              text: _text,
              focus: _focus,
              onReply: () => _reply(),
              onQuote: () {
                final comment = thread.last;
                if (comment != null) _quote(thread, comment);
              },
              onFeedback: _openFeedback,
            ),
          ),
        );
      },
    );
  }
}

class _ReplyBar extends StatelessWidget {
  const _ReplyBar({
    required this.controller,
    required this.text,
    required this.focus,
    required this.onReply,
    required this.onQuote,
    required this.onFeedback,
  });

  final ReviewController controller;
  final TextEditingController text;
  final FocusNode focus;
  final VoidCallback onReply;
  final VoidCallback onQuote;
  final VoidCallback onFeedback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drafts =
        controller.localDrafts.length + controller.sendableDraftCount;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        HarnessSpace.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HarnessTextField(
            key: const ValueKey('thread-reply-field'),
            controller: text,
            focusNode: focus,
            hint: 'Reply',
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: HarnessSpace.sm),
          Wrap(
            spacing: HarnessSpace.xs,
            runSpacing: HarnessSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HarnessTextButton(
                key: const ValueKey('thread-reply-quote'),
                label: 'Quote',
                icon: Icons.format_quote_rounded,
                dense: true,
                onPressed: onQuote,
              ),
              HarnessTextButton(
                key: const ValueKey('thread-reply-feedback'),
                label: 'Feedback',
                dense: true,
                onPressed: onFeedback,
              ),
              if (drafts > 0)
                Text(
                  drafts == 1 ? '1 draft' : '$drafts drafts',
                  style: HarnessText.meta(context),
                ),
            ],
          ),
          const SizedBox(height: HarnessSpace.xs),
          HarnessPrimaryButton(
            key: const ValueKey('thread-reply-save'),
            label: 'Reply',
            icon: Icons.reply_rounded,
            expand: true,
            busy: controller.sending,
            onPressed: controller.sending ? null : onReply,
          ),
        ],
      ),
    );
  }
}
