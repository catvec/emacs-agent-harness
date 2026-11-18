import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/board.dart';
import '../models/task.dart';
import '../services/harness_api.dart';

/// What one walk into a diagram looked like: where the viewport was, what was
/// selected, and which diagram it was in.  Back puts it all back, because the
/// design asks Back to restore the viewport and the selection of the place a
/// person came from, not to leave them where the deeper diagram left them.
class BoardVisit {
  BoardVisit({
    required this.diagram,
    required this.x,
    required this.y,
    required this.zoom,
    required this.selection,
  });

  final String diagram;
  final double x;
  final double y;
  final double zoom;
  final List<String> selection;
}

/// The freeform board's state: the board it read, the diagram walked into
/// (with the breadcrumb its parents make), the viewport, the selection, and
/// the writes in flight.
///
/// Every write is a real `board/patch` (which validates), `board/preview`
/// (which renders the exact batch and diagnoses it), then `board/commit`
/// against the revision it read, under an idempotency key, so a retried call
/// after a lost answer commits once.  A `stale-revision` refusal reads the
/// board again and says so; it never retries the edit silently, and never
/// throws the person's move away without a word.
///
/// Nothing here re-lays the board out, invents a lifecycle, a status or a
/// collaborator, or draws a cursor nobody has.
class BoardController extends ChangeNotifier {
  BoardController(
    this._api, {
    required this.boardId,
    this.diagramId,
    this.objectId,
    this.preview = false,
    this.listen = true,
  });

  /// A controller with the sample drawing and no harness behind it, for the
  /// widget tests and the pictures.  Its writes change nothing.
  BoardController.preview({
    this.boardId = 'b-fieldnotes',
    this.diagramId,
    this.objectId,
  }) : _api = null,
       preview = true,
       listen = false {
    final opening = (diagramId ?? '').isEmpty ? 'd-overview' : diagramId!;
    document = BoardDocument.preview(diagram: opening);
    _walked.add(
      BoardVisit(
        diagram: document!.diagram?.id ?? 'd-overview',
        x: document!.diagram?.x ?? 0,
        y: document!.diagram?.y ?? 0,
        zoom: document!.diagram?.zoom ?? 1,
        selection: const [],
      ),
    );
    if ((objectId ?? '').isNotEmpty) selection = [objectId!];
  }

  final HarnessApi? _api;
  final String boardId;
  final String? diagramId;

  /// The object to land on, from a `harness:board/.../object/...` link or a
  /// `board/focused` request.
  final String? objectId;
  final bool preview;

  /// Whether to hear `board/changed` and `board/focused` from the harness.
  final bool listen;

  BoardDocument? document;
  bool loading = false;
  bool busy = false;
  String? error;

  /// What the last write or refusal said, in the engine's own words.  A
  /// stale refusal also says so in [stale] and [notice].
  String? actionError;

  /// The last warning a preview raised, kept until the next write.
  List<BoardDiagnostic> diagnostics = const [];

  /// Whether the harness refused a write because the board had moved, and
  /// the board has been read again since.
  bool stale = false;

  /// A short note about the last thing that happened, in noun phrases:
  /// `Stale · the board moved`, `Saved`, `Refused · hard-constraint`.
  String? notice;

  /// The diagram the person walked into, and the visits Back returns to.
  final List<BoardVisit> _walked = [];
  List<String> selection = const [];

  double viewportX = 0;
  double viewportY = 0;
  double viewportZoom = 1;

  StreamSubscription<AcpNotification>? _events;
  int _generation = 0;
  int _keys = 0;
  bool _disposed = false;

  /// The places a `board/focused` event asked for, newest last.  The screen
  /// drains this: the app opens the board a place names.
  final List<BoardPlace> focusRequests = [];

  /// The place the board opened at, once a link or an event asked for one.
  BoardPlace? landed;

  HarnessApi? get api => _api;

  BoardTheme get theme => document?.palette ?? BoardTheme.of('electric-commons');

  /// The diagram the screen draws: the one walked into, else the document's.
  BoardDiagram? get diagram {
    final doc = document;
    if (doc == null) return null;
    final id = _current;
    if (id.isEmpty) return doc.diagram;
    return doc.diagramOf(id) ?? doc.diagram;
  }

  String get _current {
    if (_walked.isNotEmpty) return _walked.last.diagram;
    return diagramId ?? document?.diagram?.id ?? '';
  }

  /// The diagram and its parent chain, root first: the breadcrumb.
  List<BoardDiagram> get breadcrumb => document?.lineOf(diagram?.id) ?? const [];

  /// The diagrams that portal from this one, which a person may walk into.
  List<BoardDiagram> get deeper {
    final doc = document;
    final here = diagram;
    if (doc == null || here == null) return const [];
    final children = doc.childrenOf(here.id);
    final portals = {
      for (final portal in here.portals) portal.$2,
    };
    return [
      for (final child in children)
        if (portals.contains(child.id)) child,
      for (final child in children)
        if (!portals.contains(child.id)) child,
    ];
  }

  /// The portals of the diagram on screen, as `(from, diagram)` pairs.
  List<(String, String)> get portals => diagram?.portals ?? const [];

  bool get canGoBack => _walked.length > 1;

  /// What the selection names, in the order it was selected.
  List<BoardObject> get selected => [
    for (final id in selection)
      if (document?.objectOf(id) case final object?) object,
  ];

  BoardObject? get selectedObject {
    final objects = selected;
    return objects.isEmpty ? null : objects.first;
  }

  /// The relationships of the diagram on screen.
  List<BoardRelationship> get relationships =>
      document?.connectionsIn(diagram?.id ?? '') ??
      const <BoardRelationship>[];

  /// Whether this client may ask the harness for boards at all, and whether
  /// it may write them.  An older harness reads and says what it cannot do.
  bool get unsupported => !preview && !(_api?.can('board/get') ?? false);
  bool get canPatch => preview || (_api?.can('board/patch') ?? false);
  bool get canPreview => preview || (_api?.can('board/preview') ?? false);
  bool get canCommit => preview || (_api?.can('board/commit') ?? false);
  bool get canUndo => preview || (_api?.can('board/undo') ?? false);
  bool get canFocus => !preview && (_api?.can('board/focus') ?? false);

  /// Whether the board can be changed at all: the whole write path is there.
  bool get canWrite => canPatch && canPreview && canCommit;

  /// Whether an implementation task can be asked for from the board.  A
  /// board that names no project has nowhere to put one.
  bool get canRequestTask =>
      preview || (_api?.can('task/submit') ?? false);

  /// Listen for `board/changed` and `board/focused` on the connection this
  /// controller talks over now.  A connection replaced under the page is the
  /// same harness, so the listener follows it.
  void attach() {
    final api = _api;
    if (preview || !listen || api == null) return;
    _events?.cancel();
    _events = api.notifications.listen(_onNotification);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    loading = false;
    busy = false;
    _events?.cancel();
    _events = null;
    super.dispose();
  }

  /// A read that comes back after the page is gone has nothing to say.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // ---- Reading -----------------------------------------------------------

  Future<void> load({bool showSpinner = true}) => _read(showSpinner: showSpinner);

  Future<void> refresh() => _read(showSpinner: false);

  Future<void> _read({required bool showSpinner}) async {
    if (_disposed) return;
    if (preview) {
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null) {
      error = 'offline';
      notifyListeners();
      return;
    }
    final mine = ++_generation;
    if (showSpinner) loading = true;
    error = null;
    notifyListeners();
    try {
      final next = await api.boardGet(
        boardId,
        diagram: _current.isEmpty ? null : _current,
        near: selection.isEmpty ? null : selection.first,
      );
      if (mine != _generation || _disposed) return;
      _adopt(next, walked: true);
    } on AcpException catch (failure) {
      if (mine != _generation || _disposed) return;
      error = failure.message;
    } catch (failure) {
      if (mine != _generation || _disposed) return;
      error = '$failure';
    } finally {
      if (mine == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Take an answer as what the page draws.  A read that is only a refresh
  /// keeps the diagram, the viewport and the selection the person has; the
  /// first one takes the document's own.
  void _adopt(BoardDocument next, {required bool walked}) {
    document = next;
    final place = next.diagram;
    if (_walked.isEmpty) {
      final here = place?.id ?? diagramId ?? '';
      _walked.add(
        BoardVisit(
          diagram: here,
          x: place?.x ?? 0,
          y: place?.y ?? 0,
          zoom: place?.zoom ?? 1,
          selection: const [],
        ),
      );
      viewportX = place?.x ?? 0;
      viewportY = place?.y ?? 0;
      viewportZoom = place?.zoom ?? 1;
      // A link or a focus request lands on an object, and selects it so the
      // person sees what they were sent to.
      final wanted = objectId ?? landed?.object;
      if ((wanted ?? '').isNotEmpty && next.objectOf(wanted) != null) {
        selection = [wanted!];
        _reveal(wanted);
      } else if (place != null && place.selection.isNotEmpty) {
        selection = [...place.selection];
      }
    }
    // A selection or a viewport whose diagram is gone is not the board's.
    final here = diagram;
    if (here != null) {
      selection = [
        for (final id in selection)
          if (next.objectOf(id) != null) id,
      ];
    }
    if (focusRequests.isNotEmpty) notifyListeners();
  }

  /// Keep the object on screen after landing on it: the viewport moves so
  /// that its box is inside the framed part of the canvas.
  void _reveal(String id) {
    final object = document?.objectOf(id);
    if (object == null) return;
    final (x, y, w, h) = object.box;
    viewportX = x + w / 2;
    viewportY = y + h / 2;
  }

  // ---- The diagram walked into -------------------------------------------

  /// Walk into [diagram], remembering where this one was so Back restores it.
  Future<void> openDiagram(String diagram) async {
    final doc = document;
    if (doc == null || doc.diagramOf(diagram) == null) return;
    if (diagram == _current) return;
    _walked.add(
      BoardVisit(
        diagram: _current,
        x: viewportX,
        y: viewportY,
        zoom: viewportZoom,
        selection: [...selection],
      ),
    );
    selection = const [];
    final place = doc.diagramOf(diagram);
    viewportX = place?.x ?? viewportX;
    viewportY = place?.y ?? viewportY;
    viewportZoom = place?.zoom ?? viewportZoom;
    await _read(showSpinner: true);
  }

  /// Back to the diagram, viewport and selection before this one.  The first
  /// visit stays: a board always has a place.
  Future<void> back() async {
    if (!canGoBack) return;
    _walked.removeLast();
    final visit = _walked.last;
    viewportX = visit.x;
    viewportY = visit.y;
    viewportZoom = visit.zoom;
    selection = [...visit.selection];
    stale = false;
    await _read(showSpinner: true);
  }

  /// Go to a place, by diagram and object, as a `harness:board/...` link or
  /// a `board/focused` event says.  Its ancestors become the breadcrumb.
  Future<void> goTo(BoardPlace place) async {
    final doc = document;
    if (doc == null) return;
    final wanted = place.diagram;
    if (wanted.isNotEmpty && doc.diagramOf(wanted) != null) {
      _walked
        ..clear()
        ..add(
          BoardVisit(
            diagram: wanted,
            x: viewportX,
            y: viewportY,
            zoom: viewportZoom,
            selection: const [],
          ),
        );
    }
    selection = const [];
    if ((place.object ?? '').isNotEmpty) {
      selection = [place.object!];
      if (doc.objectOf(place.object!) != null &&
          doc.objectOf(place.object!)!.diagram.isNotEmpty) {
        _walked
          ..clear()
          ..add(
            BoardVisit(
              diagram: doc.objectOf(place.object!)!.diagram,
              x: viewportX,
              y: viewportY,
              zoom: viewportZoom,
              selection: const [],
            ),
          );
        _reveal(place.object!);
      }
    }
    stale = false;
    await _read(showSpinner: true);
  }

  // ---- The viewport and the selection ------------------------------------

  /// Pan by ([dx], [dy]) in canvas units.
  void panBy(double dx, double dy) {
    viewportX += dx;
    viewportY += dy;
    notifyListeners();
  }

  /// Zoom about the middle of the canvas, within the limits a person can
  /// read.
  void zoomBy(double factor) {
    viewportZoom = (viewportZoom * factor).clamp(0.2, 4.0);
    notifyListeners();
  }

  /// Frame everything the diagram draws, in the space it is drawn in:
  /// the viewport moves to the middle of the drawing and zooms so the
  /// drawing fits, up to [fitMaxZoom].  A board larger than a phone is
  /// readable at once, and a small one is not blown up into a wall.
  /// [size] is the space the canvas has; without it the zoom is 1, which
  /// is the whole drawing only when it is the size of a window.
  void fit({Size? size}) {
    final doc = document;
    if (doc == null) return;
    final (x, y, w, h) = doc.bounds(diagram?.id);
    viewportX = x + w / 2;
    viewportY = y + h / 2;
    viewportZoom = size == null
        ? 1
        : math
              .min(size.width / w, size.height / h)
              .clamp(0.2, fitMaxZoom);
    notifyListeners();
  }

  /// Select one object, or nothing when [id] is empty.
  void select(String? id) {
    if ((id ?? '').isEmpty) {
      clearSelection();
      return;
    }
    selection = [id!];
    notifyListeners();
  }

  void clearSelection() {
    if (selection.isEmpty) return;
    selection = const [];
    notifyListeners();
  }

  /// Tab: the next object of the diagram, wrapping at the end.  A person
  /// without a selection starts at the first.
  void cycleSelection({bool back = false}) {
    final objects = document?.layered ?? const <BoardObject>[];
    if (objects.isEmpty) return;
    if (selection.isEmpty) {
      selection = [objects.first.id];
      notifyListeners();
      return;
    }
    final at = objects.indexWhere((object) => object.id == selection.first);
    final next = at < 0
        ? 0
        : (at + (back ? -1 : 1) + objects.length) % objects.length;
    selection = [objects[next].id];
    notifyListeners();
  }

  /// Select the object under a canvas point, or nothing.
  ///
  /// With [add], the object joins what is already selected, or leaves it
  /// when it was in it: that is how a person picks the two ends of a
  /// connector or the members of a group without a keyboard.
  void selectAt(double x, double y, {bool add = false}) {
    final doc = document;
    if (doc == null) return;
    for (final object in doc.layered.reversed) {
      if (object.hits(x, y, margin: 4)) {
        if (!add) {
          selection = [object.id];
        } else if (selection.contains(object.id)) {
          selection = [
            for (final other in selection)
              if (other != object.id) other,
          ];
        } else {
          selection = [...selection, object.id];
        }
        notifyListeners();
        return;
      }
    }
    if (!add) clearSelection();
  }

  // ---- Writing -----------------------------------------------------------

  /// Move the selected objects by ([dx], [dy]) canvas units, as one patch.
  /// Every write is bounded: the arrow keys move by a step a person can see,
  /// and the engine refuses a move past its budget by itself.
  Future<void> nudgeSelection(double dx, double dy) async {
    final objects = selected;
    final here = diagram?.id ?? '';
    if (objects.isEmpty || here.isEmpty) return;
    await write([
      for (final object in objects)
        {'op': 'move', 'id': object.id, 'diagram': here, 'dx': dx, 'dy': dy},
    ]);
  }

  // ---- Authoring ---------------------------------------------------------

  /// The shape of a new object of [kind], as the engine's grammar has it.
  /// A note and a component are a rect with a fill and a cap; a frame is a
  /// muted region; ink is a raw path; a label is words on their own.
  static Map<String, Object?> shapeFor(
    String kind, {
    double w = 180,
    double h = 96,
    List<(double, double)> points = const [],
    String text = '',
    double size = 18,
  }) {
    switch (kind) {
      case 'ellipse':
        return {'kind': 'ellipse', 'rx': w / 2, 'ry': h / 2};
      case 'label':
        return {'kind': 'text', 'text': text, 'size': size};
      case 'shape' || 'polygon':
        return points.isEmpty
            ? {'kind': 'rect', 'w': w, 'h': h}
            : {
                'kind': 'polygon',
                'points': [
                  for (final point in points) [point.$1, point.$2],
                ],
              };
      default:
        return {'kind': 'rect', 'w': w, 'h': h};
    }
  }

  /// The paint a new object of [kind] is made with: the roles a theme
  /// resolves, never a colour of this client's own.
  static Map<String, Object?> styleFor(String kind) {
    switch (kind) {
      case 'note':
        return {'fill': 'note', 'stroke': 'none'};
      case 'frame':
        return {'fill': 'frame', 'stroke': 'edge', 'cap': 'accent'};
      case 'label':
        return {'fill': 'ink'};
      case 'ink':
        return {'stroke': 'ink', 'fill': 'none'};
      case 'marker':
        return {'fill': 'danger'};
      case 'component':
        return {'fill': 'card', 'stroke': 'edge', 'cap': 'accent'};
      default:
        return {'fill': 'none', 'stroke': 'violet', 'strokeWidth': 2};
    }
  }

  /// Create one object where a person put it: one ordinary `create`, and
  /// every field of it a field `grammar.describe` names.
  Future<bool> createObject({
    required String kind,
    required double x,
    required double y,
    String name = '',
    String text = '',
    double w = 180,
    double h = 96,
    List<(double, double)> points = const [],
    String role = 'declared',
  }) async {
    final here = diagram?.id ?? '';
    if (here.isEmpty) return false;
    final ok = await write([
      {
        'op': 'create',
        'kind': kind,
        'diagram': here,
        'x': x,
        'y': y,
        if (name.isNotEmpty) 'name': name,
        if (text.isNotEmpty) 'text': text,
        'role': role,
        'shape': shapeFor(kind, w: w, h: h, points: points, text: text),
        'style': styleFor(kind),
      },
    ]);
    return ok;
  }

  /// Draw raw ink: the points a finger or a pointer went through, as one
  /// path.  The samples are kept as they were drawn, never smoothed.
  Future<bool> drawInk(List<(double, double)> samples) async {
    final here = diagram?.id ?? '';
    if (here.isEmpty || samples.length < 2) return false;
    final first = samples.first;
    return write([
      {
        'op': 'create',
        'kind': 'ink',
        'diagram': here,
        'x': 0,
        'y': 0,
        'role': 'declared',
        'shape': {
          'kind': 'path',
          'raw': true,
          'segments': [
            ['M', first.$1, first.$2],
            for (final sample in samples.skip(1)) ['L', sample.$1, sample.$2],
          ],
        },
        'style': {'stroke': 'ink', 'fill': 'none'},
      },
    ]);
  }

  /// Move one object by the drag's total translation, as one edit.
  Future<bool> placeObject(String id, double dx, double dy) async {
    final here = diagram?.id ?? '';
    final object = document?.objectOf(id);
    if (here.isEmpty || object == null) return false;
    if (dx == 0 && dy == 0) return false;
    final m = object.transform;
    return write([
      {
        'op': 'set-transform',
        'id': id,
        'diagram': here,
        'transform': [m.a, m.b, m.c, m.d, m.e + dx, m.f + dy],
      },
    ]);
  }

  /// Give one object a new size, keeping where its origin is.
  Future<bool> resizeObject(String id, double w, double h) async {
    final here = diagram?.id ?? '';
    final object = document?.objectOf(id);
    if (here.isEmpty || object == null || w <= 1 || h <= 1) return false;
    final shape = object.shape;
    final next = switch (shape.kind) {
      'ellipse' => {'kind': 'ellipse', 'rx': w / 2, 'ry': h / 2},
      'image' => {'kind': 'image', 'w': w, 'h': h, 'src': shape.src},
      'text' => {'kind': 'text', 'text': shape.text, 'size': shape.size},
      'path' => null,
      _ => {'kind': shape.kind.isEmpty ? 'rect' : shape.kind, 'w': w, 'h': h},
    };
    if (next == null) return false;
    return write([
      {'op': 'set-shape', 'id': id, 'diagram': here, 'shape': next},
    ]);
  }

  /// Set an object's words, and its name when [name] is given.
  Future<bool> setWords(String id, {required String text, String? name}) async {
    return write([
      {'op': 'set-text', 'id': id, 'text': text},
      if (name != null) {'op': 'set-name', 'id': id, 'name': name},
    ]);
  }

  /// Connect two objects by the sides that face each other.
  Future<bool> connect(String from, String to, {String label = ''}) async {
    final here = diagram?.id ?? '';
    final a = document?.objectOf(from);
    final b = document?.objectOf(to);
    if (here.isEmpty || a == null || b == null || from == to) return false;
    final (ax, ay, aw, ah) = a.box;
    final (bx, by, bw, bh) = b.box;
    final dx = (bx + bw / 2) - (ax + aw / 2);
    final dy = (by + bh / 2) - (ay + ah / 2);
    final horizontal = dx.abs() >= dy.abs();
    final (fromAnchor, toAnchor) = horizontal
        ? (dx >= 0 ? ('right', 'left') : ('left', 'right'))
        : (dy >= 0 ? ('bottom', 'top') : ('top', 'bottom'));
    return write([
      {
        'op': 'connect',
        'diagram': here,
        'kind': 'flow',
        'from': {'object': from, 'anchor': fromAnchor},
        'to': {'object': to, 'anchor': toAnchor},
        if (label.isNotEmpty) 'label': label,
      },
    ]);
  }

  /// Turn one object by [degrees] clockwise about its own middle: the
  /// ordinary `transform` of the grammar, about an explicit pivot.  A label
  /// is never turned over; the engine refuses a reflection of one, and a
  /// rotation leaves its words upright by itself.
  Future<bool> rotateObject(String id, double degrees) async {
    final here = diagram?.id ?? '';
    final object = document?.objectOf(id);
    if (here.isEmpty || object == null || degrees == 0) return false;
    final (x, y, w, h) = object.box;
    return write([
      {
        'op': 'transform',
        'id': id,
        'diagram': here,
        'kind': 'rotate',
        'angle': degrees,
        'pivot': [x + w / 2, y + h / 2],
      },
    ]);
  }

  /// Make the selected objects one group: a semantic membership, so the
  /// members keep their own ids, links and history.  It is not a frame and
  /// not a container: nothing is redrawn around them.
  Future<bool> groupSelection({String name = ''}) async {
    final here = diagram?.id ?? '';
    final ids = [
      for (final id in selection)
        if (document?.objectOf(id) != null) id,
    ];
    if (here.isEmpty || ids.length < 2) return false;
    return write([
      {
        'op': 'group',
        'diagram': here,
        'members': ids,
        if (name.isNotEmpty) 'name': name,
      },
    ]);
  }

  /// Dissolve the group of the selected object; its members stay, each with
  /// its own identity.
  Future<bool> ungroupSelection() async {
    final group = selectedObject?.group ?? '';
    if (group.isEmpty) return false;
    return write([
      {'op': 'ungroup', 'id': group},
    ]);
  }

  /// Remove an object, its views and the relationships that end at it.
  Future<bool> deleteObject(String id) async {
    final ok = await write([
      {'op': 'delete', 'id': id},
    ]);
    if (ok) {
      selection = [
        for (final other in selection)
          if (other != id) other,
      ];
    }
    return ok;
  }

  /// Add a diagram to the board: a detail of this one, when [child].
  Future<String?> addDiagram({String name = '', bool child = true}) async {
    final here = diagram?.id ?? '';
    final id = 'd-${DateTime.now().microsecondsSinceEpoch}';
    final ok = await write([
      {
        'op': 'diagram.add',
        'id': id,
        'name': name.isEmpty ? 'detail' : name,
        if (child && here.isNotEmpty) 'parent': here,
      },
    ]);
    return ok ? id : null;
  }

  /// Make a drill-down from [from] into [to]: the object leads into the
  /// other diagram.  The object keeps its one identity; only the way in is
  /// new.
  Future<bool> addPortal(String from, String to) async {
    final here = diagram?.id ?? '';
    if (here.isEmpty || from == to) return false;
    return write([
      {'op': 'diagram.portal', 'diagram': here, 'from': from, 'to': to},
    ]);
  }

  /// Take the portal that starts at [from] away again.
  Future<bool> removePortal(String from) async {
    final here = diagram?.id ?? '';
    if (here.isEmpty) return false;
    return write([
      {'op': 'diagram.portal', 'diagram': here, 'from': from, 'on': false},
    ]);
  }

  /// Ask the task a board place belongs to about it: a thread of that
  /// task's own review, anchored to the object at the revision on screen.
  /// The task is the one the object marks; a board does not guess at one.
  Future<bool> discuss(String objectId, String text, {String? task}) async {
    final here = diagram?.id ?? '';
    final api = _api;
    final object = document?.objectOf(objectId);
    final id = task ?? object?.task ?? '';
    if (preview || api == null || here.isEmpty || id.isEmpty) {
      actionError = id.isEmpty ? 'No task' : 'board/discuss is unavailable.';
      notice = id.isEmpty ? 'No task' : 'Unsupported';
      notifyListeners();
      return false;
    }
    try {
      await api.boardDiscuss(boardId, objectId, task: id, diagram: here, text: text);
      notice = 'Discussed';
      notifyListeners();
      return true;
    } on AcpException catch (failure) {
      actionError = BoardError.fromMessage(failure.message).message;
      notice = 'Refused';
      notifyListeners();
      return false;
    } catch (failure) {
      actionError = '$failure';
      notice = 'Refused';
      notifyListeners();
      return false;
    }
  }

  /// Send [ops] to the harness: a patch, a preview of the same batch, then a
  /// commit of that exact patch against the revision read, under a fresh
  /// idempotency key.
  Future<bool> write(List<Map<String, Object?>> ops) async {
    if (ops.isEmpty) return false;
    if (preview) {
      notice = 'Preview';
      notifyListeners();
      return true;
    }
    final api = _api;
    final doc = document;
    if (api == null || doc == null || !canWrite) {
      actionError = 'board/patch is unavailable.';
      notice = 'Unsupported';
      notifyListeners();
      return false;
    }
    busy = true;
    stale = false;
    actionError = null;
    diagnostics = const [];
    notice = null;
    notifyListeners();
    final here = diagram?.id;
    final expected = doc.revision;
    final key = _nextKey();
    try {
      // The patch validates the batch against the document as it is, and
      // answers the patch id and content hash the commit names exactly.
      final patch = await api.boardPatch(
        boardId,
        ops,
        diagram: here,
        scope: [for (final op in ops) if (op['id'] is String) op['id']! as String],
      );
      diagnostics = patch.diagnostics;
      // The preview renders that exact batch and diagnoses it; nothing
      // changes.  It is what a person sees before the commit lands.
      await api.boardPreview(
        boardId,
        ops,
        diagram: here,
        scope: [for (final op in ops) if (op['id'] is String) op['id']! as String],
      );
      final answer = await api.boardCommit(
        boardId,
        patch: patch.patch,
        hash: patch.hash,
        expected: expected,
        key: key,
        diagram: here,
        ops: ops,
        // The scope is part of what the patch's hash covers, so a commit
        // that leaves it out makes another patch than the one it names.
        scope: [for (final op in ops) if (op['id'] is String) op['id']! as String],
      );
      if (_disposed) return true;
      // A commit whose key was answered before changed nothing this time.
      if (answer.document case final next?) document = next;
      notice = answer.idempotent ? 'Saved · already committed' : 'Saved';
      busy = false;
      notifyListeners();
      return true;
    } on AcpException catch (failure) {
      if (_disposed) return false;
      final refusal = BoardError.fromMessage(failure.message);
      actionError = refusal.message;
      if (refusal.isStale) {
        // The read set moved.  Read the board again and say so: the person's
        // edit is not retried behind their back, and not lost without a word.
        stale = true;
        diagnostics = const [];
        busy = false;
        notice = 'Stale · the board moved';
        notifyListeners();
        await _read(showSpinner: false);
        return false;
      }
      diagnostics = const [];
      busy = false;
      notice = 'Refused · ${refusal.summary}';
      notifyListeners();
      return false;
    } catch (failure) {
      if (_disposed) return false;
      actionError = '$failure';
      busy = false;
      notice = 'Refused';
      notifyListeners();
      return false;
    }
  }

  /// Take back the newest commit of this board.
  Future<void> undo() async {
    if (preview) return;
    final api = _api;
    if (api == null || !canUndo) {
      actionError = 'board/undo is unavailable.';
      notifyListeners();
      return;
    }
    busy = true;
    actionError = null;
    notice = null;
    notifyListeners();
    try {
      final answer = await api.boardUndo(boardId);
      if (_disposed) return;
      if (answer.document case final next?) document = next;
      notice = answer.conflicts.isEmpty ? 'Undone' : 'Undone · conflicts';
    } on AcpException catch (failure) {
      if (_disposed) return;
      final refusal = BoardError.fromMessage(failure.message);
      actionError = refusal.message;
      notice = 'Refused · ${refusal.summary}';
    } catch (failure) {
      if (_disposed) return;
      actionError = '$failure';
      notice = 'Refused';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Ask a connected client to show this place: `board/focus`.  The answer
  /// says whether anybody was there to hear it.
  Future<BoardPlace?> focusOn({String? object}) async {
    if (preview) return null;
    final api = _api;
    final here = diagram?.id ?? '';
    if (api == null || !canFocus || here.isEmpty) {
      actionError = 'board/focus is unavailable.';
      notifyListeners();
      return null;
    }
    try {
      final place = await api.boardFocus(
        boardId,
        diagram: here,
        object: object ?? (selection.isEmpty ? null : selection.first),
      );
      notice = place.client ? 'Focus · client' : 'Focus · no client';
      notifyListeners();
      return place;
    } on AcpException catch (failure) {
      actionError = BoardError.fromMessage(failure.message).message;
      notice = 'Refused';
      notifyListeners();
      return null;
    }
  }

  /// Ask for an implementation task from the selection: a task of the
  /// board's own project, whose prompt names the board, the diagram and the
  /// objects picked.  Only an explicit request makes a task; an edit of the
  /// drawing never does, and a task made this way links back to the board.
  Future<HarnessTask?> requestTask(String prompt) async {
    final api = _api;
    final doc = document;
    final project = doc?.project ?? '';
    final here = diagram?.id ?? '';
    final picked = [
      for (final object in selected)
        object.name.isEmpty ? object.id : object.name,
    ];
    if (preview || api == null || !api.can('task/submit')) {
      actionError = 'task/submit is unavailable.';
      notice = 'Unsupported';
      notifyListeners();
      return null;
    }
    if (project.isEmpty) {
      actionError = 'No project';
      notice = 'No project';
      notifyListeners();
      return null;
    }
    if (picked.isEmpty) {
      actionError = 'No selection';
      notice = 'No selection';
      notifyListeners();
      return null;
    }
    final place = [
      'harness:board/$boardId',
      if (here.isNotEmpty) 'diagram/$here',
      if (selection.isNotEmpty) 'object/${selection.first}',
    ].join('/');
    final said = [
      prompt.trim().isEmpty ? 'Implement the selected part of the board.' : prompt.trim(),
      '',
      'Board · ${doc?.display ?? boardId}',
      'Place · $place',
      if (picked.isNotEmpty) 'Selected · ${picked.join(', ')}',
    ].join('\n');
    busy = true;
    actionError = null;
    notice = null;
    notifyListeners();
    try {
      final task = await api.submitTask(cwd: project, prompt: said);
      notice = 'Task · ${task.id}';
      return task;
    } on AcpException catch (failure) {
      actionError = failure.message;
      notice = 'Refused';
      return null;
    } catch (failure) {
      actionError = '$failure';
      notice = 'Refused';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _nextKey() {
    _keys++;
    return '$boardId/${DateTime.now().microsecondsSinceEpoch}/$_keys';
  }

  // ---- What the harness says while a board is open -----------------------

  void _onNotification(AcpNotification notification) {
    if (notification.method != '_harness/event') return;
    final event = asStringOr(notification.params['event'], '');
    if (event == 'board/changed') {
      final wire = asMap(
        asList(notification.params['args']).isEmpty
            ? null
            : asList(notification.params['args']).first,
      );
      if (asString(wire['board']) != boardId) return;
      // The commit this page just made already answered with the document;
      // another writer's did not, so the page reads again.
      if ((asString(wire['patch']) ?? '').isNotEmpty && !busy) {
        unawaited(_read(showSpinner: false));
      }
      return;
    }
    if (event == 'board/focused') {
      final wire = asMap(
        asList(notification.params['args']).isEmpty
            ? null
            : asList(notification.params['args']).first,
      );
      final place = BoardPlace.fromWire(wire);
      if (place.isEmpty) return;
      if (place.board == boardId) {
        landed = place;
        unawaited(goTo(place));
      } else {
        // A place on another board: the app opens it.  The screen drains
        // this list.
        focusRequests.add(place);
        notifyListeners();
      }
    }
  }

  /// The focus requests the screen has not opened yet.
  BoardPlace? takeFocusRequest() {
    if (focusRequests.isEmpty) return null;
    return focusRequests.removeAt(0);
  }
}

/// The step an arrow key moves a selection by, in canvas units: a distance a
/// person sees, and far inside the engine's movement budget.
const boardNudgeStep = 16.0;

/// How much one press of a zoom key changes the viewport's scale.
const boardZoomStep = 1.2;

/// The smallest and largest viewport scale this client offers.
const boardZoomLimits = (0.2, 4.0);

/// How far `Fit' magnifies a drawing smaller than the canvas.  A
/// diagram of two notes would otherwise fill a desktop in letters a
/// hand wide.
const fitMaxZoom = 1.6;

/// The scale [zoom] would have after [pressed] zooms, inside the limits.
double boardZoomed(double zoom, double factor) =>
    math.min(boardZoomLimits.$2, math.max(boardZoomLimits.$1, zoom * factor));
