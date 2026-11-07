import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/review.dart';
import '../../state/review_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';
import 'review_style.dart';

/// The changes of one file, line by line, with the threads on them.
///
/// On a phone the unified diff is the one that is read: each line carries
/// the numbers it has on both sides of the change and a `+`, `-` or space
/// that says what it is, so nothing depends on a colour.  Code wider than
/// the phone is panned by its own row and every row follows, or wrapped
/// when the reviewer asks ([ReviewController.wrapLines]); on a wide screen
/// a split view is offered too ([ReviewController.splitView]).
///
/// A comment is made on a line or a range: *Select lines*, then a tap for
/// the first line and another for the last, or a long press anywhere.  The
/// comment keeps its place as a unified-diff excerpt and the revision of the
/// diff it was read at, and the file's threads are drawn under their line.
class ReviewDiffView extends StatefulWidget {
  const ReviewDiffView({
    super.key,
    required this.controller,
    required this.file,
    required this.revision,
    required this.onOpenThread,
    required this.onComment,
    this.focusThreadId,
  });

  final ReviewController controller;
  final ChangedFile file;

  /// The revision the page shows.  The lines on screen are a revision's:
  /// when this changes, the old lines are not kept under the new name.
  final String? revision;
  final ValueChanged<ReviewThread> onOpenThread;

  /// A comment on [start]..[end] of [side] of the file, in [diff]: the
  /// diff whose lines were selected.
  final void Function(String side, int start, int end, ReviewFileDiff diff)
  onComment;

  /// A thread to bring into sight when the file opens.
  final String? focusThreadId;

  @override
  State<ReviewDiffView> createState() => _ReviewDiffViewState();
}

enum _RowKind { hunk, line, threads }

class _Row {
  const _Row.hunk(this.hunk)
    : kind = _RowKind.hunk,
      line = null,
      lineIndex = 0,
      threads = const [];

  const _Row.line(this.hunk, this.line, this.lineIndex)
    : kind = _RowKind.line,
      threads = const [];

  const _Row.threads(this.hunk, this.threads)
    : kind = _RowKind.threads,
      line = null,
      lineIndex = 0;

  final _RowKind kind;
  final DiffHunk? hunk;
  final DiffLine? line;
  final int lineIndex;
  final List<ReviewThread> threads;
}

class _ReviewDiffViewState extends State<ReviewDiffView> {
  late ScrollController _vertical;
  final ValueNotifier<double> _horizontal = ValueNotifier<double>(0);

  ReviewFileDiff? _diff;
  List<_Row> _rows = const [];
  List<double> _offsets = const [];
  bool _loading = false;
  String? _error;
  int _hunk = 0;
  int? _anchor;
  int? _end;
  bool _selecting = false;
  bool _reloadScheduled = false;
  int _loadToken = 0;
  String? _loadedPath;
  String? _loadedRevision;
  String? _focusedThread;

  @override
  void initState() {
    super.initState();
    _vertical = ScrollController(
      initialScrollOffset:
          widget.controller.scrollOffsets[widget.file.path] ?? 0,
    );
    _vertical.addListener(_onScroll);
    // The controller is listened to by the page this diff is on, and a
    // request made here would notify it in the middle of this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(ReviewDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final otherFile = oldWidget.file.path != widget.file.path;
    final otherRevision = !otherFile && oldWidget.revision != widget.revision;
    if (otherFile) {
      widget.controller.saveScrollOffset(
        oldWidget.file.path,
        _vertical.hasClients ? _vertical.offset : 0,
      );
    }
    if (otherFile || otherRevision) {
      _loadedPath = null;
      _loadedRevision = null;
      _diff = null;
      _rows = const [];
      _offsets = const [];
      _anchor = null;
      _end = null;
      _focusedThread = null;
      _loading = true;
      // The controller is listened to by the page this diff is on, and a
      // request made here would notify it in the middle of this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    } else if (oldWidget.focusThreadId != widget.focusThreadId) {
      _focusThread();
    }
  }

  @override
  void dispose() {
    widget.controller.saveScrollOffset(
      widget.file.path,
      _vertical.hasClients ? _vertical.offset : 0,
    );
    _vertical.removeListener(_onScroll);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  double _lineHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12);
    return math.max(32, scale * 1.45 + 14);
  }

  double _threadHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12);
    return math.max(68, scale * 3.2 + 26);
  }

  Future<void> _load() async {
    if (!mounted) return;
    final token = ++_loadToken;
    final path = widget.file.path;
    final wanted = widget.revision ?? widget.controller.changes?.revision;
    final cached =
        widget.controller.cachedDiffAt(path, wanted) ??
        widget.controller.cachedDiff(path);
    if (cached != null &&
        (wanted == null ||
            cached.revision == null ||
            cached.revision == wanted)) {
      _take(cached);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final diff = await widget.controller.diffFor(path);
      if (!mounted || token != _loadToken || widget.file.path != path) {
        return;
      }
      final shown = widget.revision ?? widget.controller.changes?.revision;
      if (shown != null && diff.revision != null && diff.revision != shown) {
        // The page moved on while this answer was out.  The build will ask
        // for the revision it shows; do not put these lines on it.
        setState(() => _loading = false);
        return;
      }
      _take(diff);
    } on ReviewStale {
      if (!mounted || token != _loadToken) return;
      setState(() => _loading = false);
      // A reconnect or a load invalidated the read without changing the
      // revision: ask again for what is still shown.
      if (!widget.controller.isDisposed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && token == _loadToken) _load();
        });
      }
    } catch (failure) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  void _take(ReviewFileDiff diff) {
    setState(() {
      _diff = diff;
      _loadedPath = diff.path;
      _loadedRevision = diff.revision;
      _loading = false;
      _error = null;
      _hunk = widget.controller.hunkIndexFor(widget.file.path);
      _rows = _buildRows(diff);
      _offsets = const [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToHunk(_hunk, animate: false);
      _focusThread();
    });
  }

  List<_Row> _buildRows(ReviewFileDiff diff) {
    final threads = widget.controller.threadsForFile(
      widget.file.path,
      revision: diff.revision ?? _loadedRevision,
      oldPath: diff.oldPath ?? widget.file.oldPath,
    );
    final placed = <String>{};
    final rows = <_Row>[];
    for (final hunk in diff.hunks) {
      rows.add(_Row.hunk(hunk));
      final here = <String, List<ReviewThread>>{};
      for (final thread in threads) {
        final location = thread.location;
        if (location == null || location.line == null) continue;
        if (!hunk.contains(location.side, location.endLine ?? location.line!) &&
            !hunk.contains(location.side, location.line!)) {
          continue;
        }
        final key = '${location.side}:${location.endLine ?? location.line}';
        here.putIfAbsent(key, () => []).add(thread);
      }
      final placedHere = <String>{};
      for (var index = 0; index < hunk.lines.length; index++) {
        final line = hunk.lines[index];
        rows.add(_Row.line(hunk, line, index));
        for (final side in const ['new', 'old']) {
          final number = line.numberOn(side);
          if (number == null) continue;
          final key = '$side:$number';
          final found = here[key];
          if (found == null || placedHere.contains(key)) continue;
          placedHere.add(key);
          for (final thread in found) {
            placed.add(thread.id);
            rows.add(_Row.threads(hunk, [thread]));
          }
        }
      }
      // A thread whose line the diff no longer holds stays under its hunk.
      for (final entry in here.entries) {
        if (placedHere.contains(entry.key)) continue;
        for (final thread in entry.value) {
          if (!placed.add(thread.id)) continue;
          rows.add(_Row.threads(hunk, [thread]));
        }
      }
    }
    // A thread on the change as a whole, or one whose hunk is gone, is
    // still the file's if it names it: under the last hunk, one line.
    for (final thread in threads) {
      if (placed.add(thread.id)) {
        rows.add(
          _Row.threads(diff.hunks.isEmpty ? null : diff.hunks.last, [thread]),
        );
      }
    }
    return rows;
  }

  void _computeOffsets(BuildContext context) {
    if (widget.controller.wrapLines) {
      _offsets = const [];
      return;
    }
    final line = _lineHeight(context);
    final thread = _threadHeight(context);
    final offsets = <double>[0];
    for (final row in _rows) {
      offsets.add(
        offsets.last +
            switch (row.kind) {
              _RowKind.line => line,
              _RowKind.hunk => line + 8,
              _RowKind.threads => thread,
            },
      );
    }
    _offsets = offsets;
  }

  void _onScroll() {
    if (!_vertical.hasClients) return;
    widget.controller.saveScrollOffset(widget.file.path, _vertical.offset);
    final next = _hunkAt(_vertical.offset);
    if (next != _hunk) {
      setState(() => _hunk = next);
      widget.controller.saveHunkIndex(widget.file.path, next);
    }
  }

  int _hunkAt(double offset) {
    if (_rows.isEmpty) return 0;
    if (widget.controller.wrapLines || _offsets.length != _rows.length + 1) {
      final hunks = _diff?.hunks.length ?? 0;
      if (hunks == 0) return 0;
      final max = _vertical.hasClients
          ? _vertical.position.maxScrollExtent
          : 0.0;
      if (max <= 0) return 0;
      final ratio = (offset / max).clamp(0.0, 1.0);
      return (ratio * (hunks - 1)).round().clamp(0, hunks - 1);
    }
    for (var i = 0; i < _rows.length; i++) {
      if (_offsets[i + 1] > offset) {
        return _rows[i].hunk?.index ?? _hunk;
      }
    }
    return _rows.last.hunk?.index ?? _hunk;
  }

  void _jumpToHunk(int index, {bool animate = true}) {
    final hunks = _diff?.hunks ?? const <DiffHunk>[];
    if (hunks.isEmpty || !_vertical.hasClients) return;
    final target = index.clamp(0, hunks.length - 1);
    double offset;
    if (!widget.controller.wrapLines && _offsets.length == _rows.length + 1) {
      final row = _rows.indexWhere(
        (row) => row.kind == _RowKind.hunk && row.hunk?.index == target,
      );
      offset = row < 0 ? _vertical.offset : _offsets[row];
    } else {
      final max = _vertical.position.maxScrollExtent;
      offset = hunks.length <= 1 ? 0 : max * (target / (hunks.length - 1));
    }
    if (animate) {
      _vertical.animateTo(
        offset.clamp(0.0, _vertical.position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _vertical.jumpTo(offset.clamp(0.0, _vertical.position.maxScrollExtent));
    }
    setState(() => _hunk = target);
    widget.controller.saveHunkIndex(widget.file.path, target);
  }

  void _focusThread() {
    final id = widget.focusThreadId;
    if (id == null || id == _focusedThread) return;
    _focusedThread = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = _rows.indexWhere(
        (row) =>
            row.kind == _RowKind.threads &&
            row.threads.any((thread) => thread.id == id),
      );
      if (index < 0 || !_vertical.hasClients) return;
      if (!widget.controller.wrapLines && _offsets.length == _rows.length + 1) {
        _vertical.animateTo(
          _offsets[index].clamp(0.0, _vertical.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _startSelection(int row) {
    setState(() {
      _selecting = true;
      _anchor = row;
      _end = row;
    });
    HapticFeedback.selectionClick();
  }

  void _extendSelection(int row) {
    setState(() => _end = row);
  }

  bool _isSelected(int row) {
    final anchor = _anchor;
    final end = _end;
    if (anchor == null || end == null) return false;
    final low = math.min(anchor, end);
    final high = math.max(anchor, end);
    return row >= low && row <= high;
  }

  List<_Row> _selectedLineRows() {
    final anchor = _anchor;
    final end = _end;
    if (anchor == null || end == null) return const [];
    final low = math.min(anchor, end);
    final high = math.max(anchor, end);
    return [
      for (var i = low; i <= high && i < _rows.length; i++)
        if (_rows[i].kind == _RowKind.line) _rows[i],
    ];
  }

  String _selectionLabel() {
    final rows = _selectedLineRows();
    if (rows.isEmpty) return 'Line';
    final numbers = <int>{};
    for (final row in rows) {
      final number = row.line?.newLine ?? row.line?.oldLine;
      if (number != null) numbers.add(number);
    }
    if (numbers.isEmpty) return 'Line';
    final low = numbers.reduce(math.min);
    final high = numbers.reduce(math.max);
    return low == high ? 'Line $low' : 'Lines $low–$high';
  }

  void _cancelSelection() {
    setState(() {
      _selecting = false;
      _anchor = null;
      _end = null;
    });
  }

  void _commentSelection() {
    final rows = _selectedLineRows();
    if (rows.isEmpty) {
      _cancelSelection();
      return;
    }
    final last = rows.lastWhere((row) => row.line != null);
    final line = last.line!;
    final side = line.newLine != null ? 'new' : 'old';
    final numbers = <int>[
      for (final row in rows)
        if (row.line?.numberOn(side) case final number?) number,
    ];
    if (numbers.isEmpty) {
      _cancelSelection();
      return;
    }
    final diff = _diff;
    if (diff == null) {
      _cancelSelection();
      return;
    }
    widget.onComment(side, numbers.first, numbers.last, diff);
    _cancelSelection();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final path = widget.file.path;
        if (_loadedPath != path) {
          // The file changed under the view (the page rebuilt for another
          // one): read it.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _loadedPath != path) _load();
          });
        }
        final shown = widget.controller.changes?.revision;
        if (_diff != null &&
            shown != null &&
            _loadedRevision != null &&
            shown != _loadedRevision &&
            !_reloadScheduled) {
          _reloadScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _reloadScheduled = false;
            if (!mounted) return;
            _diff = null;
            _rows = const [];
            _load();
          });
        }
        _computeOffsets(context);
        return Column(
          children: [
            _toolbar(context),
            if (_loading && _diff == null)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HarnessActivity(radius: 10),
                      SizedBox(height: HarnessSpace.sm),
                      Text('Loading diff'),
                    ],
                  ),
                ),
              )
            else if (_error != null && _diff == null)
              Expanded(child: _failed(context))
            else if (_diff == null)
              const Expanded(child: Center(child: Text('No diff')))
            else
              Expanded(child: _body(context, _diff!)),
            if (_selecting) _selectionBar(context),
          ],
        );
      },
    );
  }

  Widget _toolbar(BuildContext context) {
    final hunks = _diff?.hunks ?? const <DiffHunk>[];
    final wide = MediaQuery.sizeOf(context).width >= 700;
    // At a large text size the words are wider than the phone: "Hunk 1/2"
    // keeps its place in a third of the room, and the arrows do the rest.
    final compact = MediaQuery.textScalerOf(context).scale(13) > 16;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          HarnessIconButton(
            key: const ValueKey('diff-select-lines'),
            icon: Icons.format_list_numbered_rounded,
            label: 'Select lines',
            selected: _selecting,
            onPressed: () {
              if (_selecting) {
                _cancelSelection();
              } else {
                final first = _rows.indexWhere(
                  (row) => row.kind == _RowKind.line,
                );
                if (first >= 0) _startSelection(first);
              }
            },
          ),
          HarnessIconButton(
            key: const ValueKey('diff-wrap'),
            icon: Icons.wrap_text_rounded,
            label: widget.controller.wrapLines ? 'No wrap' : 'Wrap lines',
            selected: widget.controller.wrapLines,
            onPressed: () =>
                widget.controller.setWrapLines(!widget.controller.wrapLines),
          ),
          if (wide)
            HarnessIconButton(
              key: const ValueKey('diff-split'),
              icon: Icons.view_column_outlined,
              label: widget.controller.splitView
                  ? 'Unified view'
                  : 'Split view',
              selected: widget.controller.splitView,
              onPressed: () =>
                  widget.controller.setSplitView(!widget.controller.splitView),
            ),
          const Spacer(),
          if (hunks.length > 1) ...[
            HarnessIconButton(
              key: const ValueKey('diff-hunk-previous'),
              icon: Icons.keyboard_arrow_up_rounded,
              label: 'Previous hunk',
              onPressed: _hunk <= 0 ? null : () => _jumpToHunk(_hunk - 1),
            ),
            Text(
              compact
                  ? '${_hunk + 1}/${hunks.length}'
                  : 'Hunk ${_hunk + 1}/${hunks.length}',
              key: const ValueKey('diff-hunk-label'),
              style: HarnessText.meta(context),
            ),
            HarnessIconButton(
              key: const ValueKey('diff-hunk-next'),
              icon: Icons.keyboard_arrow_down_rounded,
              label: 'Next hunk',
              onPressed: _hunk >= hunks.length - 1
                  ? null
                  : () => _jumpToHunk(_hunk + 1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _failed(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HarnessSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: HarnessSpace.sm),
            Text('Diff unavailable', style: HarnessText.rowTitle(context)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.md),
            HarnessTextButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: () {
                setState(() {
                  _error = null;
                  _loading = true;
                });
                _load();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ReviewFileDiff diff) {
    if (diff.binary) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HarnessSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: HarnessSpace.sm),
              Text('Binary file', style: HarnessText.rowTitle(context)),
              const SizedBox(height: HarnessSpace.xs),
              Text('No text diff', style: HarnessText.caption(context)),
            ],
          ),
        ),
      );
    }
    if (diff.hunks.isEmpty) {
      return Center(
        child: Text(
          'No changes in this file',
          style: HarnessText.caption(context),
        ),
      );
    }
    if (widget.controller.splitView &&
        MediaQuery.sizeOf(context).width >= 700) {
      return _splitBody(context, diff);
    }
    return _unifiedBody(context, diff);
  }

  Widget _unifiedBody(BuildContext context, ReviewFileDiff diff) {
    final wrap = widget.controller.wrapLines;
    final list = ListView.builder(
      key: const ValueKey('review-diff'),
      controller: _vertical,
      padding: EdgeInsets.zero,
      itemCount: _rows.length,
      itemBuilder: (context, index) => _rowWidget(context, index),
    );
    if (wrap) return list;
    return list;
  }

  Widget _rowWidget(BuildContext context, int index) {
    final row = _rows[index];
    switch (row.kind) {
      case _RowKind.hunk:
        return _hunkRow(context, row.hunk!);
      case _RowKind.threads:
        return _threadRow(context, row);
      case _RowKind.line:
        return _lineRow(context, index, row);
    }
  }

  Widget _hunkRow(BuildContext context, DiffHunk hunk) {
    final height = _lineHeight(context) + 8;
    return Semantics(
      header: true,
      label:
          'Hunk ${hunk.index + 1} of ${_diff?.hunks.length ?? 1}, '
          '${hunk.additions} lines added, ${hunk.deletions} lines deleted',
      child: Container(
        key: ValueKey('diff-hunk-${hunk.index}'),
        width: double.infinity,
        constraints: BoxConstraints(minHeight: height),
        padding: const EdgeInsets.symmetric(
          horizontal: HarnessSpace.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: ReviewStyle.hunkTint(context),
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hunk.header,
                maxLines: 2,
                style: HarnessText.mono(context).copyWith(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hunk.additions > 0)
              Text(
                '+${hunk.additions}',
                style: HarnessText.meta(context).copyWith(
                  color: ReviewStyle.additionInk(context),
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (hunk.additions > 0 && hunk.deletions > 0)
              const SizedBox(width: 6),
            if (hunk.deletions > 0)
              Text(
                '−${hunk.deletions}',
                style: HarnessText.meta(context).copyWith(
                  color: ReviewStyle.deletionInk(context),
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _lineRow(BuildContext context, int index, _Row row) {
    final line = row.line!;
    final wrap = widget.controller.wrapLines;
    final selected = _isSelected(index);
    final anchor = _selecting && _anchor == index;
    final background = line.isAdded
        ? ReviewStyle.additionTint(context)
        : line.isDeleted
        ? ReviewStyle.deletionTint(context)
        : Colors.transparent;
    final ink = line.isAdded
        ? ReviewStyle.additionInk(context)
        : line.isDeleted
        ? ReviewStyle.deletionInk(context)
        : Theme.of(context).colorScheme.onSurface;
    final numberWidth = math.max(
      40.0,
      MediaQuery.textScalerOf(context).scale(12) * 2.4,
    );
    final prefix = line.prefix;
    final code = Text(
      line.text.isEmpty ? ' ' : line.text,
      maxLines: wrap ? null : 1,
      softWrap: wrap,
      style: HarnessText.mono(context).copyWith(color: ink),
    );
    final rowBody = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _number(context, line.oldLine, numberWidth, background),
        _number(context, line.newLine, numberWidth, background),
        Container(
          width: 18,
          padding: const EdgeInsets.only(top: 1),
          child: Text(
            prefix,
            textAlign: TextAlign.center,
            style: HarnessText.mono(context).copyWith(
              color: line.isContext ? ReviewStyle.gutterInk(context) : ink,
              fontWeight: line.isContext ? FontWeight.w400 : FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: wrap
              ? Padding(
                  padding: const EdgeInsets.only(right: HarnessSpace.lg),
                  child: code,
                )
              : _SyncedScroll(
                  group: _horizontal,
                  child: Padding(
                    padding: const EdgeInsets.only(right: HarnessSpace.lg),
                    child: code,
                  ),
                ),
        ),
      ],
    );
    final content = Container(
      key: ValueKey(
        'diff-line-${line.newLine ?? 'o${line.oldLine ?? 0}'}-${line.kind.name}',
      ),
      width: double.infinity,
      constraints: BoxConstraints(minHeight: _lineHeight(context)),
      decoration: BoxDecoration(
        color: selected
            ? Color.alphaBlend(ReviewStyle.selectionTint(context), background)
            : background,
        border: anchor
            ? Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
              )
            : null,
      ),
      padding: EdgeInsets.symmetric(vertical: wrap ? 3 : 0),
      child: rowBody,
    );
    return Semantics(
      container: true,
      label: line.semanticsLabel(row.lineIndex),
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _startSelection(index),
        onTap: _selecting ? () => _extendSelection(index) : null,
        child: content,
      ),
    );
  }

  Widget _number(
    BuildContext context,
    int? number,
    double width,
    Color background,
  ) {
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.only(right: 4),
      alignment: Alignment.topRight,
      child: Text(
        number == null ? '' : '$number',
        style: HarnessText.mono(context)
            .copyWith(fontSize: 11, color: ReviewStyle.gutterInk(context)),
      ),
    );
  }

  Widget _threadRow(BuildContext context, _Row row) {
    final height = _threadHeight(context);
    return Container(
      key: ValueKey('diff-threads-${row.threads.first.id}'),
      constraints: BoxConstraints(minHeight: height),
      margin: const EdgeInsets.fromLTRB(HarnessSpace.sm, 4, HarnessSpace.sm, 6),
      child: Column(
        children: [
          for (final thread in row.threads) _threadMarker(context, thread),
        ],
      ),
    );
  }

  Widget _threadMarker(BuildContext context, ReviewThread thread) {
    final color = ReviewStyle.threadColor(context, thread);
    final location = thread.location;
    final replies = thread.comments.length;
    final revision = thread.revision;
    final shown = _loadedRevision ?? widget.controller.changes?.revision;
    final earlier = revision != null && shown != null && revision != shown;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        label:
            'Thread on ${location?.label ?? 'the change'}, '
            '${ReviewStyle.threadLabel(thread)}, '
            '$replies ${replies == 1 ? 'reply' : 'replies'}',
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: BorderSide(color: color.withValues(alpha: 0.45)),
          ),
          child: InkWell(
            onTap: () => widget.onOpenThread(thread),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              ReviewStyle.threadLabel(thread),
                              style: HarnessText.meta(context).copyWith(
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              replies == 1 ? '1 reply' : '$replies replies',
                              style: HarnessText.meta(context),
                            ),
                            if (earlier)
                              Text(
                                'Earlier revision',
                                style: HarnessText.meta(context),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          thread.excerpt,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HarnessText.body(context)
                              .copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionBar(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          border: Border(top: BorderSide(color: theme.colorScheme.outline)),
        ),
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.md,
          HarnessSpace.sm,
          HarnessSpace.sm,
          HarnessSpace.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selectionLabel(),
                style: HarnessText.subtitle(context).copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            HarnessTextButton(
              label: 'Cancel',
              dense: true,
              onPressed: _cancelSelection,
            ),
            HarnessPrimaryButton(
              key: const ValueKey('diff-comment-selection'),
              label: 'Comment',
              icon: Icons.mode_comment_outlined,
              onPressed: _commentSelection,
            ),
          ],
        ),
      ),
    );
  }

  // ---- Split view --------------------------------------------------------

  Widget _splitBody(BuildContext context, ReviewFileDiff diff) {
    final split = splitHunks(diff.hunks);
    return ListView.builder(
      key: const ValueKey('review-diff-split'),
      controller: _vertical,
      padding: EdgeInsets.zero,
      itemCount: split.fold<int>(
        0,
        (total, hunk) => total + 1 + hunk.rows.length,
      ),
      itemBuilder: (context, index) {
        var left = index;
        for (final hunk in split) {
          if (left == 0) return _splitHunkHeader(context, hunk.hunk);
          left -= 1;
          if (left < hunk.rows.length) {
            return _splitRow(context, hunk.rows[left]);
          }
          left -= hunk.rows.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _splitHunkHeader(BuildContext context, DiffHunk hunk) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HarnessSpace.sm,
        vertical: 4,
      ),
      color: ReviewStyle.hunkTint(context),
      child: Text(
        hunk.header,
        style: HarnessText.mono(context).copyWith(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _splitRow(BuildContext context, SplitRow row) {
    final numberWidth = math.max(
      34.0,
      MediaQuery.textScalerOf(context).scale(12) * 2.2,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _splitCell(context, row.oldLine, 'old', numberWidth)),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(child: _splitCell(context, row.newLine, 'new', numberWidth)),
        ],
      ),
    );
  }

  Widget _splitCell(
    BuildContext context,
    DiffLine? line,
    String side,
    double numberWidth,
  ) {
    if (line == null) {
      return const SizedBox.shrink();
    }
    final background = line.isAdded
        ? ReviewStyle.additionTint(context)
        : line.isDeleted
        ? ReviewStyle.deletionTint(context)
        : Colors.transparent;
    final ink = line.isAdded
        ? ReviewStyle.additionInk(context)
        : line.isDeleted
        ? ReviewStyle.deletionInk(context)
        : Theme.of(context).colorScheme.onSurface;
    final index = _rows.indexWhere(
      (row) => row.kind == _RowKind.line && row.line == line,
    );
    return Semantics(
      container: true,
      label: line.semanticsLabel(0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: index < 0 ? null : () => _startSelection(index),
        onTap: _selecting && index >= 0 ? () => _extendSelection(index) : null,
        child: Container(
          color: background,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: numberWidth,
                child: Text(
                  '${line.numberOn(side) ?? ''}',
                  textAlign: TextAlign.right,
                  style: HarnessText.mono(context).copyWith(
                    fontSize: 11,
                    color: ReviewStyle.gutterInk(context),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _SyncedScroll(
                  group: _horizontal,
                  child: Text(
                    '${line.prefix}${line.text}',
                    style: HarnessText.mono(context).copyWith(color: ink),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One code row's horizontal position, kept with every other visible row's.
///
/// Each line is its own scroll view, so a long line pans and the rows that
/// are on screen pan with it.  Off-screen rows take the position when they
/// are built.
class _SyncedScroll extends StatefulWidget {
  const _SyncedScroll({required this.group, required this.child});

  final ValueNotifier<double> group;
  final Widget child;

  @override
  State<_SyncedScroll> createState() => _SyncedScrollState();
}

class _SyncedScrollState extends State<_SyncedScroll> {
  late ScrollController _controller;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(initialScrollOffset: widget.group.value);
    _controller.addListener(_toGroup);
    widget.group.addListener(_fromGroup);
  }

  @override
  void dispose() {
    _controller.removeListener(_toGroup);
    widget.group.removeListener(_fromGroup);
    _controller.dispose();
    super.dispose();
  }

  void _toGroup() {
    if (_applying) return;
    if ((widget.group.value - _controller.offset).abs() > 0.5) {
      widget.group.value = _controller.offset;
    }
  }

  void _fromGroup() {
    if (!_controller.hasClients) return;
    final target = widget.group.value.clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if ((_controller.offset - target).abs() <= 0.5) return;
    _applying = true;
    _controller.jumpTo(target);
    _applying = false;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _controller,
      physics: const ClampingScrollPhysics(),
      child: widget.child,
    );
  }
}
