import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../acp/acp_message.dart';
import '../../models/tool_catalogue.dart';
import '../../models/tool_runs.dart';
import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import 'markdown_view.dart';
import 'tool_card.dart';
import 'tool_run_card.dart';

class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.items,
    required this.showThinking,
    this.streaming = false,
    this.scrollTick = 0,
    this.tools = ToolCatalogue.empty,
    this.waiting = const {},
  });

  final List<TranscriptItem> items;
  final bool showThinking;
  final bool streaming;
  final int scrollTick;

  /// The harness's tools.  The calls of the ones on its allow list fold into
  /// runs, each under one summary line (see `segmentTranscript`); every other
  /// call is a card of its own.  Without them nothing folds.
  final ToolCatalogue tools;

  /// The ids of the calls that wait for the person to answer: a run never
  /// folds them away.
  final Set<String> waiting;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

/// One line of the list: an item of the transcript, or the summary of a run.
sealed class _Row {
  const _Row();
}

class _ItemRow extends _Row {
  const _ItemRow(this.item, this.previous, {this.nested = false});

  final TranscriptItem item;
  final TranscriptItem? previous;

  /// It is a call (or a thought) of a run that is open.
  final bool nested;
}

class _RunRow extends _Row {
  const _RunRow(this.run, this.open);

  final ToolRun run;
  final bool open;
}

class _TranscriptViewState extends State<TranscriptView> {
  final _scroll = ScrollController();
  bool _atBottom = true;
  int _lastCount = 0;
  int _lastLength = 0;

  /// The keys of the items of the runs the person opened.  A run is open
  /// when any of its items is in here, so that one stays as it was left when
  /// a call joins it, or a call that waited for an answer comes back to it
  /// and the runs are worked out again.
  final Set<String> _opened = <String>{};

  bool _isOpen(ToolRun run) =>
      run.members.any((member) => _opened.contains(member.key));

  /// The first call of the run the person has just opened, until it has been
  /// drawn and brought into view (see `ToolRunMember.reveal`).
  String? _revealing;

  void _toggle(ToolRun run) {
    final keys = [for (final member in run.members) member.key];
    setState(() {
      if (_isOpen(run)) {
        _opened.removeAll(keys);
      } else {
        _opened.addAll(keys);
        _revealing = run.members.first.key;
      }
    });
    // Once the calls are drawn it is done: a call that is built again later,
    // as the list is scrolled to it, is not brought into view again.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealing = null);
  }

  /// What the list shows, top to bottom: the items that stand alone, a
  /// summary line for each run, and under the summary of a run that is open,
  /// its calls.  The calls are rows of their own and not one tall row, so
  /// that the list builds only the ones that are near the screen.
  List<_Row> _rows() {
    final rows = <_Row>[];
    TranscriptItem? previous;
    for (final segment in segmentTranscript(
      widget.items,
      tools: widget.tools,
      waiting: widget.waiting,
    )) {
      switch (segment) {
        case ItemSegment(:final item):
          if (item.kind == TranscriptKind.thinking && !widget.showThinking) {
            continue;
          }
          rows.add(_ItemRow(item, previous));
          previous = item;
        case RunSegment(:final run):
          final open = _isOpen(run);
          rows.add(_RunRow(run, open));
          if (open) {
            for (final member in run.members) {
              // Thoughts are shown only when the person asked for them, and
              // one that says nothing has nothing to show.
              if (member.isThinking &&
                  (!widget.showThinking || member.text.trim().isEmpty)) {
                continue;
              }
              rows.add(_ItemRow(member, null, nested: true));
            }
          }
          previous = run.members.last;
      }
    }
    return rows;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lastCount = widget.items.length;
    _lastLength = _totalLength();
    // A conversation opens on its latest message, as one that is read as it
    // goes does: not on its first, which a long one has far behind it.
    if (widget.items.isNotEmpty) _jumpToBottom();
  }

  @override
  void didUpdateWidget(TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.items.length;
    final length = _totalLength();
    if (widget.scrollTick != oldWidget.scrollTick) {
      _jumpToBottom();
    } else if ((count != _lastCount || length != _lastLength) && _atBottom) {
      _jumpToBottom();
    }
    _lastCount = count;
    _lastLength = length;
  }

  int _totalLength() {
    var total = 0;
    for (final item in widget.items) {
      total += item.text.length;
    }
    return total;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 120;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _jumpToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(target);
        _settleAtBottom();
      }
    });
  }

  /// A list lays out what is near the screen, so how long it is stays a
  /// guess until its end has been laid out: after a jump to the bottom, look
  /// again, and go on to the end it really has, until it stops moving.
  void _settleAtBottom([int again = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if ((target - _scroll.position.pixels).abs() < 1) return;
      _scroll.jumpTo(target);
      if (again > 0) _settleAtBottom(again - 1);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows();
    if (rows.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HarnessMark(
                size: 44,
                color: theme.colorScheme.primary.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 16),
              Text(
                'The line is open',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Text(
                  'Send a message to start. You will see the agent’s thoughts, '
                  'tool calls and requests as they happen.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        ListView.builder(
          key: const ValueKey('transcript-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.only(top: 6, bottom: 14),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            switch (rows[index]) {
              case _RunRow(:final run, :final open):
                return ToolRunCard(
                  key: ValueKey('run-${run.key}'),
                  run: run,
                  open: open,
                  showThinking: widget.showThinking,
                  onToggle: () => _toggle(run),
                );
              case _ItemRow(:final item, :final previous, :final nested):
                final entry = TranscriptEntry(
                  key: ValueKey(item.key),
                  item: item,
                  previous: previous,
                  isLast: index == rows.length - 1,
                  showThinking: widget.showThinking,
                  streaming: widget.streaming,
                );
                return nested
                    ? ToolRunMember(
                        reveal: item.key == _revealing,
                        child: entry,
                      )
                    : entry;
            }
          },
        ),
        if (!_atBottom)
          Positioned(
            right: 14,
            bottom: 10,
            child: Semantics(
              button: true,
              label: 'Jump to latest',
              child: GestureDetector(
                onTap: () {
                  setState(() => _atBottom = true);
                  _jumpToBottom(animate: true);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Latest',
                        style: HarnessText.meta(context).copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class TranscriptEntry extends StatelessWidget {
  const TranscriptEntry({
    super.key,
    required this.item,
    required this.previous,
    required this.isLast,
    required this.showThinking,
    required this.streaming,
  });

  final TranscriptItem item;
  final TranscriptItem? previous;
  final bool isLast;
  final bool showThinking;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final grouped = previous != null && _sameSpeaker(previous!, item);
    switch (item.kind) {
      case TranscriptKind.user:
        return _UserBubble(item: item, grouped: grouped);
      case TranscriptKind.assistant:
        return _AssistantMessage(
          item: item,
          grouped: grouped,
          streaming: streaming,
        );
      case TranscriptKind.thinking:
        if (!showThinking) return const SizedBox.shrink();
        return _ThinkingBlock(item: item);
      case TranscriptKind.tool:
        final tool = item.tool;
        if (tool == null) return const SizedBox.shrink();
        return ToolCard(tool: tool);
      case TranscriptKind.hint:
        return _HintLine(text: item.text);
      case TranscriptKind.compaction:
        return _DividerNote(
          icon: Icons.compress_rounded,
          text: item.text.trim().isEmpty ? 'Context compacted' : item.text,
        );
      case TranscriptKind.plan:
        return _PlanMessage(item: item);
      case TranscriptKind.unknown:
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
          child: Text(
            item.text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
    }
  }

  bool _sameSpeaker(TranscriptItem a, TranscriptItem b) {
    if (a.kind != b.kind) return false;
    if (a.kind == TranscriptKind.user) return false;
    if (a.kind == TranscriptKind.tool) return false;
    return true;
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.item, required this.grouped});
  final TranscriptItem item;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cupertino = HarnessStyle.isCupertino(context);
    final sender = item.sender ?? 'You';
    final fromSomeoneElse = sender != 'You';
    final bubbleColor = cupertino
        ? (fromSomeoneElse
              ? CupertinoColors.secondarySystemBackground.resolveFrom(context)
              : CupertinoTheme.of(context).primaryColor)
        : (fromSomeoneElse
              ? theme.colorScheme.surfaceContainerHigh
              : theme.colorScheme.primaryContainer);
    final textColor = cupertino
        ? (fromSomeoneElse
              ? CupertinoColors.label.resolveFrom(context)
              : CupertinoColors.white)
        : (fromSomeoneElse
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onPrimaryContainer);
    return Padding(
      padding: EdgeInsets.fromLTRB(18, grouped ? 2 : 12, 14, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!grouped)
            Padding(
              padding: const EdgeInsets.only(right: 4, bottom: 4),
              child: Text(
                sender,
                style: HarnessText.meta(context).copyWith(
                  color: fromSomeoneElse
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth:
                  MediaQuery.sizeOf(context).width * (cupertino ? 0.78 : 0.82),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: const Radius.circular(18),
                  bottomRight: Radius.circular(grouped ? 18 : 6),
                ),
              ),
              child: SelectableText(
                item.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  height: 1.4,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.item,
    required this.grouped,
    required this.streaming,
  });

  final TranscriptItem item;
  final bool grouped;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = asStringOr(asMap(item.node?['meta'])['model'], '');
    final label = item.sender ?? 'Harness';
    return Padding(
      padding: EdgeInsets.fromLTRB(18, grouped ? 2 : 14, 18, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!grouped)
            Row(
              children: [
                HarnessMark(size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: HarnessText.meta(context)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                if (model.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  // The model's name gives way, not the sender's.
                  Flexible(
                    child: Text(
                      modelName(model),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.meta(context).copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          if (item.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: HarnessMarkdown(text: item.text),
            ),
          if (item.streaming)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: _BlinkingCaret(),
            ),
        ],
      ),
    );
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: 8,
        height: 14,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary
              .withValues(alpha: 0.25 + _controller.value * 0.55),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.item});
  final TranscriptItem item;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    _open = widget.item.streaming;
  }

  @override
  void didUpdateWidget(_ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.streaming && !oldWidget.item.streaming) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.item.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 4),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HarnessTap(
              onTap: () => setState(() => _open = !_open),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        widget.item.streaming ? 'Thinking…' : 'Thought',
                        style: HarnessText.meta(context)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ),
              crossFadeState: _open
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text.rich(
            TextSpan(
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextSpan(text: text),
              ],
            ),
            textAlign: TextAlign.center,
            style: HarnessText.caption(context)
                .copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      ),
    );
  }
}

class _DividerNote extends StatelessWidget {
  const _DividerNote({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          Flexible(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(
                          icon,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextSpan(text: text),
                  ],
                ),
                textAlign: TextAlign.center,
                style: HarnessText.caption(context),
              ),
            ),
          ),
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}

class _PlanMessage extends StatelessWidget {
  const _PlanMessage({required this.item});
  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 7),
                Text(
                  'Plan',
                  style: HarnessText.meta(context).copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            HarnessMarkdown(text: item.text, compact: true),
          ],
        ),
      ),
    );
  }
}
