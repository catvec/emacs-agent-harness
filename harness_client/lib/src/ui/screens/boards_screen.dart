import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/board.dart';
import '../../state/app_controller.dart';
import '../../services/harness_api.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import 'board_screen.dart';

/// The boards the harness keeps: one row each, newest first, and the way into
/// one.  A board is a document, not a session: opening one shows the canvas,
/// and nothing here starts a turn.
class BoardsScreen extends StatefulWidget {
  const BoardsScreen({super.key, required this.app, this.initial});

  final AppController app;

  /// The board to open as the page arrives, from a `harness:board/...` link
  /// or a `board/focused` request.
  final BoardPlace? initial;

  @override
  State<BoardsScreen> createState() => _BoardsScreenState();
}

class _BoardsScreenState extends State<BoardsScreen> {
  List<BoardSummary> boards = const [];
  bool loading = true;
  String? error;
  BoardPlace? _opened;

  /// The name being typed for a new board.
  final _newName = TextEditingController();

  HarnessApi? get _api => widget.app.harness;
  bool get _supported => _api?.can('board/list') ?? false;
  bool get _canCreate => _api?.can('board/create') ?? false;

  @override
  void initState() {
    super.initState();
    _opened = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(BoardsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.initial;
    if (next != null && !next.samePlace(_opened ?? const BoardPlace(board: '', diagram: ''))) {
      _opened = next;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(next));
    }
  }

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  /// A board of one's own: a name, and the board opens empty, with the
  /// first diagram the engine gives every board.
  Future<void> _newBoard() async {
    final api = _api;
    if (api == null || !_canCreate) return;
    _newName.clear();
    final named = await showHarnessSheet<bool>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          HarnessSpace.sm,
          HarnessSpace.sheetGutter,
          HarnessSpace.sheetGutter + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New board', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: HarnessSpace.sm),
            HarnessTextField(
              key: const ValueKey('board-new-name'),
              controller: _newName,
              hint: 'Name',
              autofocus: true,
            ),
            const SizedBox(height: HarnessSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HarnessTextButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                ),
                const SizedBox(width: HarnessSpace.sm),
                HarnessPrimaryButton(
                  key: const ValueKey('board-new-create'),
                  label: 'Create',
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!(named ?? false) || !mounted) return;
    final name = _newName.text.trim();
    // The id is the app's own name for the board, readable and unlikely to
    // collide: a board's identity is its id, and the engine refuses one
    // that is already here rather than emptying it.
    final id = 'b-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    try {
      await api.boardCreate(
        id,
        name.isEmpty ? 'board' : name,
        project: _projectForNewBoard(),
      );
    } on Object catch (failure) {
      if (!mounted) return;
      setState(() => error = '$failure');
      return;
    }
    if (!mounted) return;
    await _open(BoardPlace(board: id, diagram: ''));
  }

  /// The project a new board belongs to: the one board the page shows, or
  /// none when the list is of every project.  The app never guesses which
  /// project a board is for.
  String? _projectForNewBoard() {
    final projects = {
      for (final board in boards)
        if ((board.project ?? '').isNotEmpty) board.project!,
    };
    return projects.length == 1 ? projects.first : null;
  }

  Future<void> _load({bool showSpinner = true}) async {
    final api = _api;
    if (api == null || !_supported) {
      if (!mounted) return;
      setState(() {
        boards = const [];
        loading = false;
        error = null;
      });
      return;
    }
    if (showSpinner && mounted) setState(() => loading = true);
    try {
      final next = await api.boardList();
      if (!mounted) return;
      setState(() {
        boards = next;
        error = null;
      });
    } on Object catch (failure) {
      if (!mounted) return;
      setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _open(BoardPlace place) async {
    // A board named by a link is opened whether or not the list has it: the
    // link is the authority on where it goes.
    final summary = boards.where((board) => board.id == place.board).firstOrNull;
    await Navigator.of(context).push(
      harnessRoute(
        context,
        (context) => BoardScreen(
          app: widget.app,
          board: summary?.id ?? place.board,
          name: summary?.display,
          place: place,
        ),
      ),
    );
    if (mounted) await _load(showSpinner: false);
  }

  @override
  Widget build(BuildContext context) {
    return HarnessPage(
      title: 'Boards',
      subtitle: Text(
        [
          if (!_supported)
            'Unsupported'
          else if (boards.isNotEmpty)
            boards.length == 1 ? '1 board' : '${boards.length} boards',
        ].join(),
      ),
      actions: [
        if (_supported && _canCreate)
          HarnessIconButton(
            icon: Icons.add_rounded,
            label: 'New board',
            onPressed: () => unawaited(_newBoard()),
          ),
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: () => unawaited(_load()),
        ),
      ],
      body: Align(
        alignment: AlignmentDirectional.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.lg,
              HarnessSpace.gutter,
              HarnessSpace.xl,
            ),
            children: _body(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    if (!_supported) {
      return [
        const HarnessEmptyState(
          icon: Icons.grid_on_rounded,
          title: 'Unsupported',
          message: 'board/list · board/get',
        ),
      ];
    }
    if (loading && boards.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: HarnessSpace.xl),
          child: Center(child: HarnessActivity()),
        ),
      ];
    }
    if (error != null) {
      return [
        HarnessErrorBanner(message: error!),
      ];
    }
    if (boards.isEmpty) {
      return [
        HarnessEmptyState(
          icon: Icons.grid_on_rounded,
          title: 'No boards',
          message: 'No board in this harness',
          action: _canCreate
              ? HarnessPrimaryButton(
                  key: const ValueKey('board-empty-new'),
                  label: 'New board',
                  onPressed: () => unawaited(_newBoard()),
                )
              : null,
        ),
      ];
    }
    return [
      for (final board in boards) _row(board),
    ];
  }

  Widget _row(BoardSummary board) {
    final theme = Theme.of(context);
    final palette = BoardTheme.of(board.theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HarnessTap(
        key: ValueKey('board-row-${board.id}'),
        onTap: () => unawaited(_open(BoardPlace(board: board.id, diagram: ''))),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The board's own paper colour, at the size of a row's icon: a
              // board is drawn in its theme, and the list says which.
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.color('paper') ?? theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Center(
                  child: Container(
                    width: 16,
                    height: 12,
                    decoration: BoxDecoration(
                      color: palette.color('accent'),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The name and the revision share the row's first
                    // line, so the figures under them keep their width on
                    // a phone: a count that is cut says nothing.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            board.display,
                            style: HarnessText.rowTitle(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          [
                            'rev ${board.revision}',
                            if (board.updated != null)
                              relativeTime(board.updated),
                          ].join(' · '),
                          style: HarnessText.meta(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      board.figures,
                      style: HarnessText.caption(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (board.project case final project? when project.isNotEmpty)
                      Text(
                        projectName(project),
                        style: HarnessText.meta(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
