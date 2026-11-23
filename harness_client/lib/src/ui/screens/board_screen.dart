import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/board.dart';
import '../../state/app_controller.dart';
import '../../state/board_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/board_canvas.dart';
import '../widgets/connection_banner.dart';
import '../widgets/markdown_view.dart';

/// What a tap on the canvas does.  `select` is the hand; the others make one
/// object of that kind where the tap lands, and are the same ordinary
/// `create` the grammar has, never a client-side drawing of their own.
enum BoardTool {
  select('Select', null),
  note('Note', 'note'),
  shape('Shape', 'shape'),
  frame('Frame', 'frame'),
  label('Label', 'label'),
  ink('Ink', 'ink');

  const BoardTool(this.word, this.kind);

  /// The word on the tool, a noun like every label: it names the object the
  /// tool makes, not the act of making one.
  final String word;

  /// The object kind a tap makes, or null for the hand.
  final String? kind;
}

/// The freeform board: the canvas, the breadcrumb of the diagram walked into,
/// and the sheet of what is selected.
///
/// Pan is a drag, zoom the wheel or a pinch, and the keys are the ones
/// `docs/flutter-board.md` documents: the arrows move the selection (or the
/// selected objects), Tab cycles, Escape clears and Enter opens the links
/// sheet.  Every edit is a real patch, preview and commit; nothing here
/// re-lays the board out or invents a status.
class BoardScreen extends StatefulWidget {
  const BoardScreen({
    super.key,
    required this.app,
    required this.board,
    this.name,
    this.place,
    this.controller,
  });

  final AppController app;
  final String board;
  final String? name;

  /// The place a link or a `board/focused` event asked for.
  final BoardPlace? place;
  final BoardController? controller;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  late BoardController _controller;
  final _canvas = GlobalKey();
  final _pictures = BoardPictures();
  final _focus = FocusNode(debugLabel: 'board canvas');
  final _openLinks = GlobalKey();
  Offset _origin = Offset.zero;
  Offset _pan = Offset.zero;
  double _pinch = 1;
  Size _size = Size.zero;
  DateTime _wheelAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether the drawing has been framed once.  Only the first
  /// document is fitted; after that the viewport is the person's.
  bool _fitted = false;

  /// The tool the next tap on the canvas uses.  `select` is the hand: a tap
  /// picks what is there, and a drag moves it.
  BoardTool _tool = BoardTool.select;

  /// The object being dragged, and how far it has gone since the drag
  /// started.  The commit is one `set-transform` at the end, not a write
  /// per frame.
  String? _dragging;
  Offset _dragged = Offset.zero;

  /// The object being resized from its bottom-right handle, and its new size.
  String? _resizing;
  Size _resized = Size.zero;

  /// The points of ink being drawn, in canvas units.
  final List<(double, double)> _ink = [];

  /// The fields of the sheets a person writes in.  They live as long as the
  /// page: a sheet that is closing still holds its field, and a controller
  /// disposed under it would throw while it animates out.
  final _words = TextEditingController();
  final _name = TextEditingController();
  final _comment = TextEditingController();

  /// Whether the app had a connection when this page last looked: a board
  /// read while the connection was out is read again when it is back, and
  /// an edit whose answer was lost is settled by what the board holds then.
  bool _wasConnected = false;

  /// Whether the app has already been asked to check the connection for the
  /// failure the page is showing, so that one failure is asked about once.
  bool _askedToCheck = false;

  BoardController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        BoardController(
          widget.app.harness,
          boardId: widget.board,
          diagramId: widget.place?.diagram,
          objectId: widget.place?.object,
        );
    _controller.addListener(_changed);
    _controller.attach();
    widget.app.addListener(_appChanged);
    _wasConnected = widget.app.isConnected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_controller.load(showSpinner: false));
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(BoardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_appChanged);
      widget.app.addListener(_appChanged);
      _wasConnected = widget.app.isConnected;
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    _pictures.dispose();
    _focus.dispose();
    _words.dispose();
    _name.dispose();
    _comment.dispose();
    super.dispose();
  }

  /// The connection came back: read the board again, which may have changed
  /// while the page could not hear it, and which settles an edit whose
  /// answer was lost (see [BoardController.connectionLost]).  The page is a
  /// route over the shell, so nothing else reads for it.
  void _appChanged() {
    final connected = widget.app.isConnected;
    if (connected && !_wasConnected && !_controller.preview) {
      unawaited(_controller.refresh());
    }
    _wasConnected = connected;
    if (mounted) setState(() {});
  }

  /// Frame the drawing the first time it arrives, and not again: a person
  /// who has panned or zoomed keeps where they are, and a refresh of the
  /// board leaves the viewport alone.
  void _fitOnce() {
    if (_fitted || _size.isEmpty) return;
    _fitted = true;
    _controller.fit(size: _size);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final document = _controller.document;
    if (document != null) unawaited(_pictures.load(document, _changed));
    // A place on another board opens its own page rather than replacing this
    // one's: Back returns to the board the person was on.
    final next = _controller.takeFocusRequest();
    if (next != null) unawaited(_openBoard(next));
    // A read or a write the connection took with it: the app is asked
    // whether the connection is there.  A socket that died without a word is
    // found out now rather than when the next request times out, and the
    // page says the connection is being got back (its banner) instead of
    // showing the board's error.  One failure is asked about once; a read
    // that comes back arms the next one.
    if (!_controller.connectionLost) {
      _askedToCheck = false;
      return;
    }
    if (_askedToCheck) return;
    _askedToCheck = true;
    unawaited(widget.app.checkConnection());
  }

  Future<void> _openBoard(BoardPlace place) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      harnessRoute(
        context,
        (context) => BoardScreen(app: widget.app, board: place.board, place: place),
      ),
    );
    if (mounted) unawaited(_controller.refresh());
  }

  // ---- Drawing -----------------------------------------------------------

  Offset get _offset => Offset(_controller.viewportX, _controller.viewportY);

  // ---- Keys --------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final control = HardwareKeyboard.instance.isControlPressed;
    if (control || HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final step = boardNudgeStep * (shift ? 4 : 1);
    // The arrows move the selection, or the selected objects when there is
    // one; with nothing selected, they pan the canvas, which is what a
    // person pressing them at an empty board means.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final dx = key == LogicalKeyboardKey.arrowLeft
          ? -step
          : key == LogicalKeyboardKey.arrowRight
          ? step
          : 0.0;
      final dy = key == LogicalKeyboardKey.arrowUp
          ? -step
          : key == LogicalKeyboardKey.arrowDown
          ? step
          : 0.0;
      if (_controller.selection.isEmpty) {
        _controller.panBy(dx, dy);
      } else {
        unawaited(_controller.nudgeSelection(dx, dy));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _controller.cycleSelection(back: shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _controller.clearSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_controller.selectedObject == null) return KeyEventResult.ignored;
      final target = _openLinks.currentContext;
      if (target != null) {
        unawaited(showHarnessSheet<void>(
          context: target,
          builder: (context) => BoardLinksSheet(
            object: _controller.selectedObject!,
            onOpen: _openResource,
          ),
        ));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add) {
      _controller.zoomBy(boardZoomStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus) {
      _controller.zoomBy(1 / boardZoomStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit0) {
      _controller.fit(size: _size);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      unawaited(_controller.back());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // A wheel scrolls the canvas; with a zoom modifier (or a trackpad's
    // pinch, which arrives as a scroll with the control held) it zooms.
    final keyboard = HardwareKeyboard.instance;
    final zoom = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (zoom) {
      final now = DateTime.now();
      // One notch of a wheel arrives as several events; the wheel itself
      // sends fewer than 24 a second.
      if (now.difference(_wheelAt).inMilliseconds < 24) return;
      _wheelAt = now;
      _controller.zoomBy(event.scrollDelta.dy < 0 ? boardZoomStep : 1 / boardZoomStep);
      return;
    }
    _controller.panBy(event.scrollDelta.dx, event.scrollDelta.dy);
  }

  @override
  Widget build(BuildContext context) {
    final document = _controller.document;
    return HarnessPage(
      title: 'Board',
      subtitle: Text(_subtitle()),
      actions: [
        if (_controller.canGoBack)
          HarnessIconButton(
            icon: Icons.arrow_back_rounded,
            label: 'Back',
            onPressed: () => unawaited(_controller.back()),
          ),
        HarnessIconButton(
          icon: Icons.fit_screen_rounded,
          label: 'Fit',
          onPressed: () => _controller.fit(size: _size),
        ),
        if (_controller.canUndo && !_controller.preview)
          HarnessIconButton(
            icon: Icons.undo_rounded,
            label: 'Undo',
            onPressed: _controller.busy ? null : () => unawaited(_controller.undo()),
          ),
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: () => unawaited(_controller.refresh()),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The page is opened over the shell, whose own banner it covers:
          // a connection that goes while a board is open says so here.
          ConnectionBanner(app: widget.app),
          _header(context),
          _tools(context),
          if (_controller.error != null || _controller.actionError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                0,
                HarnessSpace.gutter,
                HarnessSpace.sm,
              ),
              child: HarnessErrorBanner(
                message: _controller.actionError ?? _controller.error!,
              ),
            ),
          Expanded(
            child: document == null
                ? _empty(context)
                : _canvasView(context, document),
          ),
          _selectionBar(context),
        ],
      ),
    );
  }

  String _subtitle() {
    final name = _controller.document?.display ?? widget.name ?? widget.board;
    final revision = _controller.document?.revision;
    return [
      name,
      if (revision != null) 'rev $revision',
      if (_controller.stale) 'Stale',
      if (_controller.notice case final notice? when notice.isNotEmpty) notice,
      if (_controller.loading) 'Loading',
    ].join(' · ');
  }

  Widget _empty(BuildContext context) {
    if (_controller.unsupported) {
      return const HarnessEmptyState(
        icon: Icons.grid_on_rounded,
        title: 'Unsupported',
        message: 'board/get',
      );
    }
    // A board that could not be read because the connection went is not a
    // board that is not there: the page waits for the connection, which its
    // banner says is being got back, rather than claiming there is none.
    if (_controller.connectionLost && _controller.document == null) {
      return const Center(child: HarnessActivity());
    }
    if (_controller.error != null) {
      return HarnessEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'No board',
        message: _controller.error!,
      );
    }
    return const Center(child: HarnessActivity());
  }

  /// The tools a person builds the diagram with: the hand, and the kinds of
  /// object a tap can put down.  A tool is a noun, and picking one changes
  /// what the next tap does -- nothing is drawn until the tap lands.
  Widget _tools(BuildContext context) {
    // A harness that cannot write a board gets no tools: a tap would make
    // nothing, and offering it would be a lie about the harness.
    if (!_controller.canWrite) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        0,
        HarnessSpace.gutter,
        HarnessSpace.xs,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tool in BoardTool.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: TextButton(
                  key: ValueKey('board-tool-${tool.name}'),
                  onPressed: _controller.busy
                      ? null
                      : () => setState(() => _tool = tool),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: _tool == tool
                        ? theme.colorScheme.primary.withValues(alpha: 0.14)
                        : null,
                    foregroundColor: _tool == tool
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  child: Text(tool.word),
                ),
              ),
            TextButton(
              key: const ValueKey('board-new-diagram'),
              onPressed: _controller.busy ? null : () => unawaited(_newDiagram()),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('New diagram'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newDiagram() async {
    final id = await _controller.addDiagram(name: 'detail');
    if (!mounted || id == null) return;
    await _controller.openDiagram(id);
  }

  /// The breadcrumb of the diagram walked into, its portals, and what the
  /// diagram holds.
  Widget _header(BuildContext context) {
    final document = _controller.document;
    final line = _controller.breadcrumb;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        HarnessSpace.sm,
      ),
      child: Wrap(
        spacing: HarnessSpace.sm,
        runSpacing: HarnessSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (document != null)
            Text(
              document.display,
              style: HarnessText.label(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          for (var index = 0; index < line.length; index++) ...[
            Text('›', style: HarnessText.meta(context)),
            InkWell(
              key: ValueKey('board-crumb-${line[index].id}'),
              onTap: index == line.length - 1
                  ? null
                  : () => unawaited(_controller.openDiagram(line[index].id)),
              child: Text(
                line[index].display,
                style: HarnessText.caption(context).copyWith(
                  color: index == line.length - 1
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.primary,
                  fontWeight: index == line.length - 1
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          for (final diagram in _controller.deeper)
            TextButton(
              key: ValueKey('board-portal-${diagram.id}'),
              onPressed: () => unawaited(_controller.openDiagram(diagram.id)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('▸ ${diagram.display}', style: HarnessText.caption(context)),
            ),
        ],
      ),
    );
  }

  Widget _canvasView(BuildContext context, BoardDocument document) {
    final theme = _controller.theme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_fitted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitOnce();
          });
        }
        // The drawing is set in the app's own type, like every other
        // word on the page: a board is not a foreign surface.  The
        // theme carries the look's family, and its fallbacks.
        final body = Theme.of(context).textTheme.bodyMedium;
        final painter = BoardCanvasPainter(
          document: document,
          theme: theme,
          selection: _controller.selection,
          pictures: _pictures,
          offset: _offset,
          scale: _controller.viewportZoom,
          fontFamily: body?.fontFamily,
          fontFallback: body?.fontFamilyFallback ?? const [],
        );
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Semantics(
            label: 'Board canvas',
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('board-canvas'),
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) {
                        final point = painter.toCanvas(details.localPosition, _size);
                        _tapAt(
                          point,
                          add: HardwareKeyboard.instance.isShiftPressed,
                        );
                        _focus.requestFocus();
                      },
                      // A finger has no Shift: a long press adds what is
                      // under it to the selection, or takes it away.
                      onLongPressStart: (details) {
                        final point = painter.toCanvas(details.localPosition, _size);
                        if (_tool != BoardTool.select) return;
                        _controller.selectAt(point.dx, point.dy, add: true);
                        _focus.requestFocus();
                      },
                      onScaleStart: (details) {
                        _origin = details.focalPoint;
                        _pan = _offset;
                        _pinch = _controller.viewportZoom;
                        _beginGesture(details.localFocalPoint, painter);
                      },
                      onScaleUpdate: (details) {
                        if (details.scale != 1) {
                          _controller.zoomBy(
                            (details.scale * _pinch) / _controller.viewportZoom,
                          );
                          return;
                        }
                        if (_dragging != null || _resizing != null || _ink.isNotEmpty) {
                          _dragTo(details.localFocalPoint, painter);
                          return;
                        }
                        final moved = details.focalPoint - _origin;
                        _controller
                          ..viewportX = _pan.dx - moved.dx / _controller.viewportZoom
                          ..viewportY = _pan.dy - moved.dy / _controller.viewportZoom;
                        _controller.notifyListeners();
                      },
                      onScaleEnd: (details) {
                        unawaited(_endGesture());
                      },
                      child: RepaintBoundary(
                        key: _canvas,
                        child: CustomPaint(
                          painter: painter,
                          size: Size.infinite,
                        ),
                      ),
                    ),
                  ),
                  if (_resizable != null)
                    _resizeHandle(context, painter, _resizable!),
                  if (_ink.isNotEmpty)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _InkTrail(points: _ink, painter: painter),
                        size: Size.infinite,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The selected object a resize handle is offered for: a single object
  /// whose geometry is a size, not a path's points.
  BoardObject? get _resizable {
    if (_tool != BoardTool.select) return null;
    final selected = _controller.selected;
    if (selected.length != 1) return null;
    final object = selected.first;
    if (object.locked) return null;
    return switch (object.shape.kind) {
      'rect' || 'ellipse' || 'image' => object,
      _ => null,
    };
  }

  Widget _resizeHandle(BuildContext context, BoardCanvasPainter painter, BoardObject object) {
    final (x, y, w, h) = object.box;
    final at = painter.toScreen(Offset(x + w, y + h), _size);
    return Positioned(
      left: at.dx - 12,
      top: at.dy - 12,
      child: GestureDetector(
        key: const ValueKey('board-resize'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          _resizing = object.id;
          _resized = Size(w, h);
        },
        onPanUpdate: (details) {
          if (_resizing == null) return;
          final scale = _controller.viewportZoom;
          setState(() {
            _resized = Size(
              math.max(24, _resized.width + details.delta.dx / scale),
              math.max(24, _resized.height + details.delta.dy / scale),
            );
          });
        },
        onPanEnd: (_) => unawaited(_endGesture()),
        child: Semantics(
          label: 'Resize',
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Authoring gestures ------------------------------------------------

  /// A tap: with the hand, pick what is under it; with a tool, make one
  /// object of that kind there.  A second finger, or a held Shift, adds to
  /// the selection instead of replacing it, which is how two ends of a
  /// connector are chosen.
  void _tapAt(Offset point, {bool add = false}) {
    if (_tool == BoardTool.select) {
      _controller.selectAt(point.dx, point.dy, add: add);
      return;
    }
    unawaited(_place(_tool, point));
  }

  Future<void> _place(BoardTool tool, Offset point) async {
    final kind = tool.kind;
    if (kind == null) return;
    final size = switch (tool) {
      BoardTool.frame => (w: 320.0, h: 200.0),
      BoardTool.note => (w: 200.0, h: 110.0),
      BoardTool.shape => (w: 160.0, h: 96.0),
      BoardTool.label => (w: 160.0, h: 30.0),
      _ => (w: 180.0, h: 96.0),
    };
    final ok = await _controller.createObject(
      kind: kind,
      x: point.dx,
      y: point.dy,
      name: _defaultName(tool),
      text: tool == BoardTool.note ? 'note' : '',
      w: size.w,
      h: size.h,
    );
    if (!mounted) return;
    if (ok) {
      // The new object is the one the person just put down: select it, so
      // its words and its handles are a tap away.
      final created = _controller.document?.layered.lastOrNull;
      if (created != null) _controller.select(created.id);
      setState(() => _tool = BoardTool.select);
    }
  }

  String _defaultName(BoardTool tool) => switch (tool) {
    BoardTool.note => 'note',
    BoardTool.shape => 'shape',
    BoardTool.frame => 'region',
    BoardTool.label => 'label',
    _ => '',
  };

  /// What a drag starts on: the resize handle is its own gesture, so here
  /// it is the object under the pointer, or ink, or nothing.
  void _beginGesture(Offset local, BoardCanvasPainter painter) {
    final point = painter.toCanvas(local, _size);
    if (_tool == BoardTool.ink) {
      _ink
        ..clear()
        ..add((point.dx, point.dy));
      return;
    }
    if (_tool != BoardTool.select) return;
    final hit = _objectAt(point);
    if (hit == null) return;
    _controller.select(hit.id);
    if (hit.locked) return;
    _dragging = hit.id;
    _dragged = Offset.zero;
  }

  void _dragTo(Offset local, BoardCanvasPainter painter) {
    final point = painter.toCanvas(local, _size);
    if (_ink.isNotEmpty) {
      setState(() => _ink.add((point.dx, point.dy)));
      return;
    }
    if (_dragging == null) return;
    final start = _origin;
    final moved = local - start;
    setState(() {
      _dragged = Offset(
        moved.dx / _controller.viewportZoom,
        moved.dy / _controller.viewportZoom,
      );
    });
  }

  Future<void> _endGesture() async {
    if (_ink.length >= 2) {
      final samples = List<(double, double)>.of(_ink);
      setState(_ink.clear);
      await _controller.drawInk(samples);
      return;
    }
    if (_ink.isNotEmpty) {
      setState(_ink.clear);
      return;
    }
    if (_resizing case final id?) {
      final size = _resized;
      setState(() {
        _resizing = null;
        _resized = Size.zero;
      });
      await _controller.resizeObject(id, size.width, size.height);
      return;
    }
    final id = _dragging;
    final by = _dragged;
    setState(() {
      _dragging = null;
      _dragged = Offset.zero;
    });
    if (id != null && (by.dx.abs() > 1 || by.dy.abs() > 1)) {
      await _controller.placeObject(id, by.dx, by.dy);
    }
  }

  BoardObject? _objectAt(Offset point) {
    final doc = _controller.document;
    if (doc == null) return null;
    for (final object in doc.layered.reversed) {
      if (object.hits(point.dx, point.dy, margin: 4)) return object;
    }
    return null;
  }

  /// What the selection is, and the way into its links: the bar a person
  /// reads without opening a sheet.
  Widget _selectionBar(BuildContext context) {
    final document = _controller.document;
    if (document == null) return const SizedBox.shrink();
    final object = _controller.selectedObject;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectionLine(document, object),
                  style: HarnessText.caption(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_controller.busy)
                const Padding(
                  padding: EdgeInsets.only(right: HarnessSpace.sm),
                  child: HarnessActivity(radius: 7),
                ),
            ],
          ),
          if (object != null) ...[
            Wrap(
              spacing: 2,
              children: [
                for (final action in _actions(context, object)) action,
                Tooltip(
                  message: 'Links',
                  child: TextButton.icon(
                    key: const ValueKey('board-links'),
                    onPressed: () => unawaited(showHarnessSheet<void>(
                      context: context,
                      builder: (context) => BoardLinksSheet(
                        object: object,
                        onOpen: _openResource,
                      ),
                    )),
                    icon: Icon(Icons.link_rounded, size: 18, color: theme.colorScheme.primary),
                    label: const Text('Links'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The actions a selection offers: edit its words, turn it, connect two of
  /// them, group them, drill down from one, discuss it in its task's review,
  /// and delete it.
  List<Widget> _actions(BuildContext context, BoardObject object) {
    if (!_controller.canWrite) return const [];
    final task = _taskOf(object);
    final many = _controller.selection.length >= 2;
    return [
      _action(context, 'Edit', 'board-edit', () => unawaited(_edit(object))),
      _action(
        context,
        'Rotate',
        'board-turn',
        () => unawaited(_controller.rotateObject(object.id, 90)),
        tooltip: 'Quarter turn clockwise',
      ),
      _action(
        context,
        'Connect',
        'board-connect',
        many ? () => unawaited(_connect()) : null,
        tooltip: 'Connect two selected objects',
      ),
      _action(
        context,
        'Group',
        'board-group',
        many ? () => unawaited(_controller.groupSelection()) : null,
        tooltip: 'Group two selected objects',
      ),
      if ((object.group ?? '').isNotEmpty)
        _action(
          context,
          'Ungroup',
          'board-ungroup',
          () => unawaited(_controller.ungroupSelection()),
          tooltip: 'Ungroup the members',
        ),
      _action(
        context,
        'Portal',
        'board-portal',
        _otherDiagrams.isEmpty ? null : () => unawaited(_portal(object)),
        tooltip: _otherDiagrams.isEmpty ? 'No other diagram' : 'Drill down from this object',
      ),
      _action(
        context,
        'Discuss',
        'board-discuss',
        task == null ? null : () => unawaited(_discuss(object)),
        tooltip: task == null ? 'No task' : 'Discuss in the task review',
      ),
      _action(
        context,
        'Request task',
        'board-request-task',
        _canRequestTask ? () => unawaited(_requestTask(object)) : null,
        tooltip: _canRequestTask ? 'Implementation task from the selection' : 'No project',
      ),
      _action(context, 'Delete', 'board-delete', () => unawaited(_delete(object))),
    ];
  }

  /// Whether a task can be asked for from here: the board is of a project,
  /// and the harness takes tasks.  A board of no project has nowhere to put
  /// one, and the action says so rather than guessing at a directory.
  bool get _canRequestTask =>
      (_controller.document?.project ?? '').isNotEmpty &&
      _controller.canRequestTask;

  /// An explicit request for an implementation task from the selection: the
  /// person writes what the task is, and the board, the diagram and the
  /// objects picked go with it.  Editing the drawing never makes a task.
  Future<void> _requestTask(BoardObject object) async {
    _words.text = '';
    final asked = await showHarnessSheet<bool>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.gutter + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New task', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              object.name.isEmpty ? object.id : object.name,
              style: HarnessText.meta(sheetContext),
            ),
            const SizedBox(height: HarnessSpace.sm),
            HarnessTextField(
              key: const ValueKey('board-task-prompt'),
              controller: _words,
              hint: 'Task',
              minLines: 3,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
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
                  key: const ValueKey('board-task-submit'),
                  label: 'Submit',
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!(asked ?? false)) return;
    final task = await _controller.requestTask(_words.text);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          task == null
              ? (_controller.actionError ?? 'Task submission failure')
              : 'Task · ${task.id}',
        ),
      ),
    );
  }

  /// The task an object belongs to: the one it marks, or the one a resource
  /// of it links.  A board does not guess at a task beyond that.
  String? _taskOf(BoardObject object) {
    if ((object.task ?? '').isNotEmpty) return object.task;
    for (final resource in object.resources) {
      if (resource.kind == 'task' && resource.ref.isNotEmpty) return resource.ref;
    }
    return null;
  }

  /// One action of the selection bar: a verb, and what it does.
  Widget _action(
    BuildContext context,
    String label,
    String key,
    VoidCallback? onPressed, {
    String? tooltip,
  }) {
    final button = TextButton(
      key: ValueKey(key),
      onPressed: _controller.busy ? null : onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  /// Edit one object's words: the text it says, and the name it is called by.
  Future<void> _edit(BoardObject object) async {
    _words.text = object.text;
    _name.text = object.name;
    final saved = await showHarnessSheet<bool>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Words', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: HarnessSpace.sm),
            HarnessTextField(
              key: const ValueKey('board-edit-text'),
              controller: _words,
              hint: 'Text',
              minLines: 3,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: HarnessSpace.sm),
            HarnessTextField(
              key: const ValueKey('board-edit-name'),
              controller: _name,
              hint: 'Name',
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
                  key: const ValueKey('board-edit-save'),
                  label: 'Save',
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (saved ?? false) {
      await _controller.setWords(object.id, text: _words.text, name: _name.text);
    }
  }

  Future<void> _connect() async {
    final selection = _controller.selection;
    if (selection.length < 2) return;
    await _controller.connect(selection[0], selection[1]);
  }

  /// The diagrams a portal from here could open: the board's others.
  List<BoardDiagram> get _otherDiagrams {
    final document = _controller.document;
    final here = _controller.diagram?.id ?? '';
    if (document == null) return const [];
    return [
      for (final diagram in document.diagrams)
        if (diagram.id != here) diagram,
    ];
  }

  /// Make the selected object a drill-down: a way from it into another
  /// diagram of the board.  Which one is the person's choice, never this
  /// client's guess.
  Future<void> _portal(BoardObject object) async {
    final choices = _otherDiagrams;
    if (choices.isEmpty) return;
    final target = await showHarnessSheet<String>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Drill down', style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              object.name.isEmpty ? object.id : object.name,
              style: HarnessText.meta(sheetContext),
            ),
            const SizedBox(height: HarnessSpace.sm),
            for (final diagram in choices)
              ListTile(
                key: ValueKey('board-portal-into-${diagram.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(diagram.display),
                onTap: () => Navigator.of(sheetContext).pop(diagram.id),
              ),
          ],
        ),
      ),
    );
    if (target == null || target.isEmpty) return;
    await _controller.addPortal(object.id, target);
  }

  Future<void> _delete(BoardObject object) async {
    await _controller.deleteObject(object.id);
  }

  /// Discuss the object in the review of the task it marks: a native thread
  /// of that review, not a comment store of the board's own.
  Future<void> _discuss(BoardObject object) async {
    final task = _taskOf(object);
    if (task == null || task.isEmpty) return;
    _comment.clear();
    final said = await showHarnessSheet<bool>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          HarnessSpace.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Discuss · ${object.name.isEmpty ? object.id : object.name}',
                style: HarnessText.sheetTitle(sheetContext)),
            const SizedBox(height: HarnessSpace.xs),
            Text(
              'Review thread · $task',
              style: HarnessText.meta(sheetContext),
            ),
            const SizedBox(height: HarnessSpace.sm),
            HarnessTextField(
              key: const ValueKey('board-discuss-text'),
              controller: _comment,
              hint: 'Comment',
              minLines: 3,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
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
                  key: const ValueKey('board-discuss-send'),
                  label: 'Send',
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if ((said ?? false) && _comment.text.trim().isNotEmpty) {
      await _controller.discuss(object.id, _comment.text.trim(), task: task);
    }
  }

  String _selectionLine(BoardDocument document, BoardObject? object) {
    if (object == null) {
      final objects = document.placed.length;
      final connections = _controller.relationships.length;
      return [
        objects == 1 ? '1 object' : '$objects objects',
        if (connections > 0)
          connections == 1 ? '1 connection' : '$connections connections',
        'No selection',
      ].join(' · ');
    }
    return [
      object.name.isEmpty ? object.id : object.name,
      object.kindLabel,
      object.roleLabel,
      if (_controller.selection.length > 1)
        '${_controller.selection.length} selected',
      if (object.locked) 'Locked',
      if (object.mirrored) 'Mirrored',
      if ((object.group ?? '').isNotEmpty) 'Grouped',
    ].join(' · ');
  }

  /// Open a resource's precise target through the app's own link opening: a
  /// `harness:` link goes to the surface it names, an address to the browser.
  Future<void> _openResource(BoardResource resource) async {
    final target = resource.target;
    if (target == null || target.isEmpty) return;
    if (target.startsWith('harness:board/')) {
      final uri = Uri.tryParse(target);
      if (uri == null) return;
      final place = BoardPlace.fromLink(uri);
      if (place.board == _controller.boardId) {
        await _controller.goTo(place);
      } else {
        await _openBoard(place);
      }
      return;
    }
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing on this device can open it: the sheet still names it.
    }
  }
}

/// What one object is: its name, kind and role, its words, the resources it
/// links with the state each one resolved to, and its task marker -- the one
/// object's precise place, never a list of things it might be.
class BoardLinksSheet extends StatelessWidget {
  const BoardLinksSheet({
    super.key,
    required this.object,
    required this.onOpen,
  });

  final BoardObject object;

  /// Opens a resource's precise target; null targets are not offered.
  final Future<void> Function(BoardResource resource) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marker = object.sourceStatus;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        HarnessSpace.sheetGutter,
        HarnessSpace.sm,
        HarnessSpace.sheetGutter,
        HarnessSpace.sheetGutter + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            object.name.isEmpty ? object.id : object.name,
            style: HarnessText.sheetTitle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip(context, object.kindLabel),
              _chip(context, object.roleLabel),
              if (object.locked) _chip(context, 'Locked'),
              if (object.mirrored) _chip(context, 'Mirrored'),
            ],
          ),
          if (object.text.isNotEmpty) ...[
            const SizedBox(height: HarnessSpace.lg),
            HarnessMarkdown(text: object.text, tight: true),
          ],
          const SizedBox(height: HarnessSpace.lg),
          Text('Links', style: HarnessText.label(context)),
          const SizedBox(height: HarnessSpace.sm),
          if (object.resources.isEmpty)
            Text('No resources', style: HarnessText.caption(context))
          else
            for (final resource in object.resources) _resourceRow(context, resource),
          const SizedBox(height: HarnessSpace.lg),
          Text('Task', style: HarnessText.label(context)),
          const SizedBox(height: HarnessSpace.sm),
          if (marker == null)
            Text('No marker', style: HarnessText.caption(context))
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    marker.label.isEmpty ? marker.stateLabel : marker.label,
                    style: HarnessText.body(context),
                  ),
                ),
                _chip(context, marker.stateLabel),
              ],
            ),
          const SizedBox(height: HarnessSpace.lg),
          Text(
            'Arrows · selection · move   Tab · cycle   Escape · clear   Enter · links',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resourceRow(BuildContext context, BoardResource resource) {
    final theme = Theme.of(context);
    final openable = resource.openable;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            openable ? Icons.link_rounded : Icons.link_off_rounded,
            size: 16,
            color: openable
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resource.display,
                  style: HarnessText.body(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (resource.note case final note? when note.isNotEmpty)
                  Text(
                    note,
                    style: HarnessText.meta(context),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _chip(context, resource.stateLabel),
        ],
      ),
    );
    if (!openable) return row;
    return InkWell(
      key: ValueKey('board-resource-${resource.kind}-${resource.ref}'),
      onTap: () => unawaited(onOpen(resource)),
      child: row,
    );
  }

  Widget _chip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(label, style: HarnessText.meta(context)),
    );
  }
}

/// The ink a finger is drawing right now, before it is a real path: the
/// same samples the commit will carry, drawn as they were made.
class _InkTrail extends CustomPainter {
  _InkTrail({required this.points, required this.painter});

  final List<(double, double)> points;
  final BoardCanvasPainter painter;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = painter.theme.color('ink') ?? const Color(0xFF25272C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final first = painter.toScreen(Offset(points.first.$1, points.first.$2), size);
    path.moveTo(first.dx, first.dy);
    for (final point in points.skip(1)) {
      final at = painter.toScreen(Offset(point.$1, point.$2), size);
      path.lineTo(at.dx, at.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _InkTrail old) =>
      old.points.length != points.length || old.painter != painter;
}
