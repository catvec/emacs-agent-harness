import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/workspace_speech.dart';
import '../../state/workspace_controller.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// The workspace's speech floor, as a band of the chat column: who speaks,
/// what waits, and the solo, hold and skip controls.
///
/// It is part of the page, not a card laid over it: one hairline above it,
/// the composer's own fill, and no margin, so it reads as the row of the
/// chat that answers "who is talking" and sits between the conversation and
/// the field.  The lines are the floor's, in the order the harness will
/// speak them; a thread the harness did not name is not drawn.  Every
/// control acts on the harness's record, so the panel never keeps a queue of
/// its own.
class WorkspaceSpeechPanel extends StatelessWidget {
  const WorkspaceSpeechPanel({
    super.key,
    required this.controller,
    this.compact = false,
    this.onShowThread,
  });

  final WorkspaceController controller;

  /// A phone's strip: the speaker and the count on one line, and the queue
  /// behind a sheet.  The wide band names each waiting thread in place.
  final bool compact;

  /// Open a thread the panel names.  Null keeps a name a name.
  final ValueChanged<String>? onShowThread;

  WorkspaceSpeech? get floor => controller.speech;

  @override
  Widget build(BuildContext context) {
    final floor = controller.speech;
    if (floor == null || !floor.hasSpeech) return const SizedBox.shrink();
    return compact ? _compact(context, floor) : _wide(context, floor);
  }

  /// The band above the composer on a tablet and a desktop.
  ///
  /// One speaker line and one line per waiting thread, in the order the
  /// harness will speak them, and every row's actions in the band's one
  /// right-hand column: the speaker's `Skip` and `Hold`, a waiting thread's
  /// `Solo` and a solo line's `Leave` all hold the same cell, so the column
  /// reads down the band instead of drifting with the width of the words
  /// beside it.
  Widget _wide(BuildContext context, WorkspaceSpeech floor) {
    final theme = Theme.of(context);
    return _Band(
      key: const Key('workspace-speech-panel'),
      color: theme.colorScheme.surfaceContainerLowest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final column = _actionColumn(
            context,
            _actionRows(floor),
            constraints.maxWidth,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _speakerRow(context, floor, column),
              if (floor.waiting.isNotEmpty) ...[
                const SizedBox(height: 2),
                for (final entry in floor.waiting)
                  _waitingRow(context, floor, entry, column),
              ],
              if (_soloNeedsItsOwnLine(floor)) _soloRow(context, floor, column),
            ],
          );
        },
      ),
    );
  }

  /// The thread holding the floor, its place in the words, and its controls.
  ///
  /// The thread's name is the row, so the band's first line already says who
  /// speaks: there is no heading above it to leave a gap, and the queue's
  /// size is a count on the same line rather than a heading of its own.
  Widget _speakerRow(
    BuildContext context,
    WorkspaceSpeech floor,
    double? column,
  ) {
    final theme = Theme.of(context);
    final entry = floor.speaking;
    final live = entry != null;
    final title = live
        ? (floor.hold ? 'Held · ${entry.threadTitle}' : entry.threadTitle)
        : (floor.hold ? 'Held' : 'Nothing speaking');
    final seconds = entry?.played;
    return _BandRow(
      column: column,
      leading: Row(
        children: [
          HarnessDot(
            color: floor.hold
                ? HarnessColors.amber
                : (live ? HarnessColors.moss : theme.colorScheme.outline),
            size: 7,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              key: const Key('workspace-speech-speaking'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.rowTitle(context).copyWith(
                fontSize: 13,
                color: floor.hold
                    ? HarnessColors.amber
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (seconds != null && seconds >= 1) ...[
            const SizedBox(width: 6),
            Text(
              '${seconds.round()}s',
              key: const Key('workspace-speech-played'),
              style: HarnessText.meta(context),
            ),
          ],
          if (floor.solo != null && !_soloNeedsItsOwnLine(floor)) ...[
            const SizedBox(width: 8),
            Text(
              'Solo · ${floor.soloTitle ?? 'Thread'}',
              key: const Key('workspace-speech-solo'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.caption(context)
                  .copyWith(color: HarnessColors.amber),
            ),
          ],
          if (floor.waiting.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              '${floor.waiting.length} waiting',
              key: const Key('workspace-speech-waiting-count'),
              style: HarnessText.caption(context),
            ),
          ],
        ],
      ),
      actions: [
        if (live)
          _Control(
            key: const Key('workspace-speech-skip'),
            label: 'Skip',
            tooltip: 'Speech · skip',
            onPressed: () => unawaited(controller.skipSpeech()),
          ),
        _Control(
          key: floor.hold
              ? const Key('workspace-speech-resume')
              : const Key('workspace-speech-hold'),
          label: floor.hold ? 'Resume' : 'Hold',
          tooltip: floor.hold ? 'Speech · resume' : 'Speech · hold',
          onPressed: () => unawaited(
            floor.hold ? controller.resumeSpeech() : controller.holdSpeech(),
          ),
        ),
      ],
    );
  }

  /// One waiting thread: its name, its words, and its own solo.
  ///
  /// The words a thread will say are under its name in the chat's own caption
  /// size; a thread a solo keeps back says so in the amber word beside its
  /// name rather than in a second line of its own.
  Widget _waitingRow(
    BuildContext context,
    WorkspaceSpeech floor,
    WorkspaceSpeechEntry entry,
    double? column,
  ) {
    final theme = Theme.of(context);
    final soloed = floor.solo == entry.thread;
    final title = entry.threadTitle.isEmpty ? 'Thread' : entry.threadTitle;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: _BandRow(
        alignment: CrossAxisAlignment.start,
        column: column,
        leading: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: HarnessDot(
                color: soloed
                    ? HarnessColors.amber
                    : theme.colorScheme.outlineVariant,
                size: 5,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: _ThreadName(
                          title: title,
                          key: Key('workspace-speech-waiting-${entry.id}'),
                          onTap: onShowThread == null
                              ? null
                              : () => onShowThread!(entry.thread),
                        ),
                      ),
                      if (entry.held != null && !soloed) ...[
                        const SizedBox(width: 6),
                        Text(
                          entry.held!,
                          key: Key('workspace-speech-held-${entry.id}'),
                          style: HarnessText.caption(context)
                              .copyWith(color: HarnessColors.amber),
                        ),
                      ],
                    ],
                  ),
                  if (entry.preview.isNotEmpty)
                    Text(
                      entry.preview,
                      key: Key('workspace-speech-preview-${entry.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (soloed)
            _Control(
              key: Key('workspace-speech-unsolo-${entry.id}'),
              label: 'Leave',
              tooltip: 'Speech · leave solo',
              onPressed: () => unawaited(controller.clearSolo()),
            )
          else
            _Control(
              key: Key('workspace-speech-solo-${entry.id}'),
              label: 'Solo',
              tooltip: 'Speech · solo',
              onPressed: () => unawaited(controller.soloSpeech(entry.thread)),
            ),
        ],
      ),
    );
  }

  /// Whether the solo needs a line of its own.
  ///
  /// A waiting row already offers the way out of a solo on its own thread, so
  /// the band adds a line only for a solo whose thread is not in the queue --
  /// a solo is never a state the person cannot leave.
  bool _soloNeedsItsOwnLine(WorkspaceSpeech floor) {
    if (floor.solo == null) return false;
    return !floor.waiting.any((entry) => entry.thread == floor.solo);
  }

  /// The solo, when no waiting thread already shows it: its name and the way
  /// out.
  Widget _soloRow(BuildContext context, WorkspaceSpeech floor, double? column) {
    return _BandRow(
      column: column,
      leading: Text(
        'Solo · ${floor.soloTitle ?? 'Thread'}',
        key: const Key('workspace-speech-solo-line'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HarnessText.caption(context)
            .copyWith(color: HarnessColors.amber),
      ),
      actions: [
        _Control(
          key: const Key('workspace-speech-unsolo'),
          label: 'Leave',
          tooltip: 'Speech · leave solo',
          onPressed: () => unawaited(controller.clearSolo()),
        ),
      ],
    );
  }

  /// A phone's strip: the speaker and the count on one line, and a sheet for
  /// the queue.  The waiting threads are never only a number: the sheet names
  /// each of them with its own solo.
  Widget _compact(BuildContext context, WorkspaceSpeech floor) {
    final theme = Theme.of(context);
    final speaking = floor.speaking;
    final solo = floor.solo;
    return Material(
      key: const Key('workspace-speech-strip'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => _showSheet(context, floor),
        canRequestFocus: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            6,
            HarnessSpace.sm,
            6,
          ),
          child: Row(
            children: [
              HarnessDot(
                color: floor.hold
                    ? HarnessColors.amber
                    : (speaking == null
                          ? theme.colorScheme.outline
                          : HarnessColors.moss),
                size: 7,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  speaking == null
                      ? (floor.hold ? 'Held' : 'Nothing speaking')
                      : (floor.hold
                            ? 'Held · ${speaking.threadTitle}'
                            : speaking.threadTitle),
                  key: const Key('workspace-speech-strip-state'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.rowTitle(context).copyWith(fontSize: 13),
                ),
              ),
              if (solo != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    solo == speaking?.thread
                        ? 'Solo'
                        : 'Solo · ${floor.soloTitle ?? 'Thread'}',
                    key: const Key('workspace-speech-strip-solo'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.caption(context)
                        .copyWith(color: HarnessColors.amber),
                  ),
                ),
              if (floor.waiting.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${floor.waiting.length} waiting',
                    key: const Key('workspace-speech-strip-waiting'),
                    style: HarnessText.caption(context),
                  ),
                ),
              if (speaking != null)
                _Control(
                  key: const Key('workspace-speech-strip-skip'),
                  label: 'Skip',
                  tooltip: 'Speech · skip',
                  onPressed: () => unawaited(controller.skipSpeech()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSheet(BuildContext context, WorkspaceSpeech floor) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) =>
            _SpeechSheet(controller: controller, onShowThread: onShowThread),
      ),
    );
  }
}

/// The band's action column, or null when the band is too narrow to
/// hold it.
///
/// The column is the widest row's actions -- the speaker's `Skip` and
/// `Hold`, a waiting thread's `Solo`, a solo line's `Leave` -- so one
/// width holds every row's controls and their right edge is the
/// band's.  A row with a single action is drawn at the column's end,
/// which puts `Solo` under `Hold` rather than under `Skip`.
///
/// A band too narrow to give the words most of its width falls back to
/// each row's own actions: they still end on the same edge, and the
/// words keep their room.
double? _actionColumn(
  BuildContext context,
  List<List<String>> rows,
  double available,
) {
  var cell = 0.0;
  for (final labels in rows) {
    for (final label in labels) {
      cell = math.max(cell, _Control.widthOf(context, label));
    }
  }
  // The widest row's actions must still leave the words most of the
  // band, or the column is dropped for each row's own.
  var widestRow = 0.0;
  for (final labels in rows) {
    widestRow = math.max(widestRow, cell * labels.length);
  }
  return widestRow <= available * _columnShare ? cell : null;
}

/// The most of the band the action column may take, leaving the rest
/// of the width to the thread names and their words.
const double _columnShare = 0.5;

/// Every row's actions, as the labels they carry: the speaker's line
/// first, then each waiting thread's, then the solo's own.
List<List<String>> _actionRows(WorkspaceSpeech floor) => [
  [if (floor.speaking != null) 'Skip', floor.hold ? 'Resume' : 'Hold'],
  for (final entry in floor.waiting)
    [floor.solo == entry.thread ? 'Leave' : 'Solo'],
  if (floor.solo != null &&
      !floor.waiting.any((entry) => entry.thread == floor.solo))
    ['Leave'],
];

/// Every row's actions on a phone's sheet, as the labels they carry.
List<List<String>> _sheetActionRows(WorkspaceSpeech? floor) => [
  [
    if (floor?.speaking != null) 'Skip',
    floor?.hold == true ? 'Resume' : 'Hold',
  ],
  for (final entry in floor?.waiting ?? const <WorkspaceSpeechEntry>[])
    [floor?.solo == entry.thread ? 'Leave' : 'Solo'],
  if (floor?.solo != null &&
      !floor!.waiting.any((entry) => entry.thread == floor.solo))
    ['Leave'],
];

/// One row of the band: what it says on the left, and its actions in the
/// band's one right-hand column.
///
/// The words take whatever the actions do not, and the actions are
/// [_Actions]: one column for the speaker's line, for every waiting
/// thread and for the solo's own line.  A long name gives way -- it
/// ellipsizes -- rather than moving the actions, so `Hold` and a
/// waiting thread's `Solo` share one right edge at every width and
/// text size.
class _BandRow extends StatelessWidget {
  const _BandRow({
    required this.leading,
    required this.actions,
    this.column,
    this.alignment = CrossAxisAlignment.center,
  });

  /// What the row says, filling the room before the column.
  final Widget leading;

  /// What the row offers, in the order they are drawn.
  final List<Widget> actions;

  /// The band's action column: the width every row's actions hold, so
  /// their right edge is the same on every row.  Null lets each row
  /// take the room its own actions need, which still ends on one edge.
  final double? column;

  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: alignment,
      children: [
        Expanded(child: leading),
        _Actions(column: column, children: actions),
      ],
    );
  }
}

/// A row's actions, at the row's end: the band's right-hand column.
///
/// Every action is one cell wide -- the widest label the band may show --
/// and the row is laid out from its end, so the last action of every row
/// holds the same cell: `Skip` and `Hold`, a waiting thread's `Solo` and
/// a solo line's `Leave` share both edges.  A row with one action puts it
/// in that last cell, so `Solo` sits under `Hold` and not under `Skip`.
class _Actions extends StatelessWidget {
  const _Actions({required this.children, this.column});

  final List<Widget> children;

  /// The width of one action, or null when the band is too narrow to
  /// hold a column and each row takes the room its own actions need.
  final double? column;

  @override
  Widget build(BuildContext context) {
    final cell = column;
    if (cell == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final child in children) SizedBox(width: cell, child: child),
      ],
    );
  }
}

/// The band's own surface: the composer's fill, one hairline above it, and
/// no outer margin, so it is a row of the page and not a card on it.
class _Band extends StatelessWidget {
  const _Band({super.key, required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          6,
          HarnessSpace.gutter,
          4,
        ),
        child: child,
      ),
    );
  }
}

/// The queue on a phone, as a sheet: every waiting thread, its place, and its
/// solo; the solo's own way out; and the controls that act on the floor.
class _SpeechSheet extends StatelessWidget {
  const _SpeechSheet({required this.controller, this.onShowThread});

  final WorkspaceController controller;
  final ValueChanged<String>? onShowThread;

  /// Whether the solo needs a line of its own here, as on the band:
  /// a waiting row already offers the way out of a solo on its own
  /// thread.
  bool _soloNeedsItsOwnLine(WorkspaceSpeech? floor) {
    if (floor?.solo == null) return false;
    return !floor!.waiting.any((entry) => entry.thread == floor.solo);
  }

  @override
  Widget build(BuildContext context) {
    final floor = controller.speech;
    final theme = Theme.of(context);
    // The sheet is a narrow column of the band's own rows, so its
    // actions hold the same right-hand column: the speaker's `Skip`
    // and `Hold`, each waiting thread's `Solo`, and the solo line's
    // `Leave` end on one edge.
    final rows = _sheetActionRows(floor);
    return LayoutBuilder(
      builder: (context, constraints) {
        final column = _actionColumn(
          context,
          rows,
          constraints.maxWidth - HarnessSpace.gutter * 2,
        );
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              0,
              HarnessSpace.gutter,
              HarnessSpace.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (floor == null || !floor.hasSpeech)
                  Text('Nothing to say', style: HarnessText.caption(context)),
                // One line for the floor: who speaks, and the two
                // controls that act on the words.  The sheet does
                // not say the speaker's name twice.
                _BandRow(
                  column: column,
                  leading: Row(
                    children: [
                      HarnessDot(
                        color: floor?.hold == true
                            ? HarnessColors.amber
                            : (floor?.speaking == null
                                  ? theme.colorScheme.outline
                                  : HarnessColors.moss),
                        size: 7,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          floor?.speaking == null
                              ? 'Nothing speaking'
                              : (floor!.hold
                                    ? 'Held · ${floor.speaking!.threadTitle}'
                                    : floor.speaking!.threadTitle),
                          key: const Key('workspace-speech-sheet-speaking'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.rowTitle(context).copyWith(
                            fontSize: 13,
                            color: floor?.hold == true
                                ? HarnessColors.amber
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    if (floor?.speaking != null)
                      _Control(
                        label: 'Skip',
                        tooltip: 'Speech · skip',
                        onPressed: () => unawaited(controller.skipSpeech()),
                      ),
                    _Control(
                      label: floor?.hold == true ? 'Resume' : 'Hold',
                      tooltip: floor?.hold == true
                          ? 'Speech · resume'
                          : 'Speech · hold',
                      onPressed: () => unawaited(
                        floor?.hold == true
                            ? controller.resumeSpeech()
                            : controller.holdSpeech(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HarnessSpace.sm),
                if (floor?.waiting.isNotEmpty ?? false) ...[
                  Text(
                    '${floor!.waiting.length} waiting',
                    key: const Key('workspace-speech-sheet-waiting'),
                    style: HarnessText.caption(context),
                  ),
                  for (final entry in floor.waiting)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _BandRow(
                        alignment: CrossAxisAlignment.start,
                        column: column,
                        leading: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              entry.threadTitle.isEmpty
                                  ? 'Thread'
                                  : entry.threadTitle,
                              key: Key(
                                'workspace-speech-sheet-thread-${entry.id}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HarnessText.rowTitle(context)
                                  .copyWith(fontSize: 13),
                            ),
                            if (entry.preview.isNotEmpty)
                              Text(
                                entry.preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HarnessText.caption(context),
                              ),
                          ],
                        ),
                        actions: [
                          if (floor.solo == entry.thread)
                            _Control(
                              label: 'Leave',
                              tooltip: 'Speech · leave solo',
                              onPressed: () =>
                                  unawaited(controller.clearSolo()),
                            )
                          else
                            _Control(
                              label: 'Solo',
                              tooltip: 'Speech · solo',
                              onPressed: () => unawaited(
                                controller.soloSpeech(entry.thread),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: HarnessSpace.sm),
                ],
                if (floor?.solo != null && !_soloNeedsItsOwnLine(floor)) ...[
                  _BandRow(
                    column: column,
                    leading: Text(
                      'Solo · ${floor!.soloTitle ?? 'Thread'}',
                      key: const Key('workspace-speech-sheet-solo'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context)
                          .copyWith(color: HarnessColors.amber),
                    ),
                    actions: [
                      _Control(
                        label: 'Leave',
                        tooltip: 'Speech · leave solo',
                        onPressed: () => unawaited(controller.clearSolo()),
                      ),
                    ],
                  ),
                  const SizedBox(height: HarnessSpace.sm),
                ],
                if (floor != null && floor.recent.isNotEmpty) ...[
                  Text('Recent', style: HarnessText.label(context)),
                  for (final entry in floor.recent.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${entry.outcomeWord}'
                        '${entry.why == null ? '' : ' · ${entry.why}'}'
                        ' · ${entry.threadTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.caption(context),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A waiting thread's name, which opens its conversation when the
/// screen gave the panel a way to.
class _ThreadName extends StatelessWidget {
  const _ThreadName({super.key, required this.title, required this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HarnessText.rowTitle(context)
          .copyWith(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
    );
    if (onTap == null) return text;
    return Semantics(
      button: true,
      label: title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: text,
        ),
      ),
    );
  }
}

/// One control of the panel, with its tooltip.
///
/// A row's action is a small button, never a bare word: its tap area keeps an
/// accessible height even where the label is short, and the semantic label is
/// the word the person sees.
class _Control extends StatelessWidget {
  const _Control({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  /// The least a tap target may be, at the smallest text size.
  static const double target = 36;

  /// How wide this control is drawn: its label in the style it uses,
  /// and the padding either side of it.
  ///
  /// The band's action column is measured with this, so the column is
  /// the buttons' own width at the text size in force, not a number
  /// guessed for one size.
  static double widthOf(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _style(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + _padding * 2;
    painter.dispose();
    return math.max(width, target);
  }

  /// The room the button leaves either side of its label.
  static const double _padding = 8;

  static TextStyle _style(BuildContext context) => HarnessText.meta(context)
      .copyWith(
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      tooltip: tooltip,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: target),
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, target),
            padding: const EdgeInsets.symmetric(horizontal: _padding),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label, maxLines: 1, style: _style(context)),
        ),
      ),
    );
  }
}
