/// A freeform agent board: a shared canvas of notes, ink, shapes,
/// architecture diagrams, connectors and linked resources.
///
/// Everything here is read from the wire (`board/list`, `board/get`, the
/// patch answer, `board/focus`) and drawn from that alone: the document is
/// the board, and a client has no second model of it.  Geometry is numeric
/// and placed already -- an object's `transform` is an SVG-order affine
/// matrix `[a b c d e f]`, `box` is where that puts its shape, and a
/// relationship's `fromPoint` and `toPoint` are canvas coordinates.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart' show Color;

import '../acp/acp_message.dart';
import 'session.dart' show parseTime;


/// The palette roles a style may name.  A theme resolves each to a colour;
/// a literal `#rrggbb` is allowed in place of a role.
const boardColorRoles = [
  'none',
  'paper',
  'ink',
  'frame',
  'edge',
  'card',
  'muted',
  'group',
  'accent',
  'accent-soft',
  'note',
  'note-soft',
  'violet',
  'danger',
];

/// The object kinds the grammar holds, and the words the client shows.
const boardObjectKinds = {
  'note': 'Note',
  'component': 'Component',
  'label': 'Label',
  'frame': 'Frame',
  'marker': 'Marker',
  'shape': 'Shape',
  'ink': 'Ink',
  'path': 'Path',
  'image': 'Image',
  'group': 'Group',
  'connector': 'Connector',
};

/// The roles an object's or a relationship's claim may have: what was seen,
/// what was stated, what is proposed and what nobody knows yet.
const boardEvidenceRoles = ['observed', 'declared', 'proposed', 'unknown'];

/// The resource kinds an object or a relationship may link.
const boardResourceKinds = [
  'task',
  'message',
  'call',
  'thread',
  'diagram',
  'board',
  'document',
  'symbol',
  'screen',
];

/// A theme: a palette, not another capability.  Every role a theme fills is
/// one [boardColorRoles] names, so a theme can never draw what an edit could
/// not build.  The three are the engine's own (`harness-board-themes`).
class BoardTheme {
  const BoardTheme(this.name, this.palette);

  /// A theme from `board/grammar`'s `themes`: a name and the palette roles
  /// it fills, written as `#rrggbb`.
  factory BoardTheme.fromWire(JsonMap wire) {
    final palette = asMap(wire['palette']);
    return BoardTheme(asStringOr(wire['name'], 'electric-commons'), {
      for (final entry in palette.entries)
        if (parseHexColor(asString(entry.value)) case final color?)
          entry.key: color,
    });
  }

  /// The three palettes, exactly as `harness-board-themes` resolves them.
  static const electricCommons = {
    'paper': 0xFFF5F5F0,
    'ink': 0xFF25272C,
    'frame': 0xFFE8E8EF,
    'edge': 0xFF55545F,
    'card': 0xFFFFFEF7,
    'muted': 0xFF4D5058,
    'accent': 0xFFC5FF54,
    'accent-soft': 0xFFE8FFB0,
    'note': 0xFFFFC4D2,
    'note-soft': 0xFFFFE4EA,
    'violet': 0xFFB3A0FF,
    'danger': 0xFFFF6589,
    'group': 0xFFECEEE7,
  };
  static const openLabels = {
    'paper': 0xFFFBFBF8,
    'ink': 0xFF20232A,
    'frame': 0xFFEEEEF2,
    'edge': 0xFF52525C,
    'card': 0xFFFFFEF7,
    'muted': 0xFF5B5E66,
    'accent': 0xFFC5FF54,
    'accent-soft': 0xFFEEFDC8,
    'note': 0xFFFFD3DC,
    'note-soft': 0xFFFFE9EE,
    'violet': 0xFFBCAEFF,
    'danger': 0xFFFF6589,
    'group': 0xFFF0F1EB,
  };
  static const nightCommons = {
    'paper': 0xFF17191D,
    'ink': 0xFFF0F1E8,
    'frame': 0xFF25282F,
    'edge': 0xFF6F7280,
    'card': 0xFF30343C,
    'muted': 0xFFC8CBD0,
    'accent': 0xFFC4F46B,
    'accent-soft': 0xFF3D4F2A,
    'note': 0xFF522D40,
    'note-soft': 0xFF3C2431,
    'violet': 0xFFB6A2FF,
    'danger': 0xFFFF6E8E,
    'group': 0xFF22252B,
  };

  static const themes = {
    'electric-commons': electricCommons,
    'open-labels': openLabels,
    'night-commons': nightCommons,
  };

  final String name;

  /// Role to colour, as the wire carries it: `{"paper": "#f5f5f0", ...}`.
  final Map<String, Color> palette;

  /// The palette of a theme by name, the first one when the name is not one
  /// this client knows (an older client, a newer theme).
  static BoardTheme of(String name) {
    final palette = themes[name] ?? electricCommons;
    return BoardTheme(name, {
      for (final entry in palette.entries)
        entry.key: Color(entry.value),
    });
  }

  /// The colour a style role means here, or null for `none` and for a role
  /// this theme does not fill.
  Color? color(String? role) {
    if (role == null || role == 'none' || role.isEmpty) return null;
    return palette[role] ?? parseHexColor(role);
  }

  /// Whether the theme is dark, which a client may want for its own chrome.
  bool get dark {
    final paper = palette['paper'];
    if (paper == null) return false;
    return paper.computeLuminance() < 0.4;
  }

  @override
  bool operator ==(Object other) => other is BoardTheme && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// `#rrggbb` or `#rrggbbaa` as a colour, or null.
Color? parseHexColor(String? value) {
  if (value == null) return null;
  final text = value.startsWith('#') ? value.substring(1) : value;
  if (text.length != 6 && text.length != 8) return null;
  final parsed = int.tryParse(text, radix: 16);
  if (parsed == null) return null;
  return Color(text.length == 6 ? 0xFF000000 | parsed : parsed);
}

/// The colour of a style role on a board, `#rrggbb` included.
Color boardColor(String? role, BoardTheme theme) {
  return theme.color(role) ?? const Color(0x00000000);
}

/// One entry of `board/list`: what a list of boards shows without reading
/// the document.
class BoardSummary {
  const BoardSummary({
    required this.id,
    this.name = '',
    this.project,
    this.theme = 'electric-commons',
    this.revision = 0,
    this.updated,
    this.diagrams = 0,
    this.objects = 0,
    this.markers = 0,
  });

  factory BoardSummary.fromWire(JsonMap wire) => BoardSummary(
    id: asStringOr(wire['id'], ''),
    name: asStringOr(wire['name'], ''),
    project: asString(wire['project']),
    theme: asStringOr(wire['theme'], 'electric-commons'),
    revision: asInt(wire['revision']) ?? 0,
    updated: parseTime(wire['updated']),
    diagrams: asInt(wire['diagrams']) ?? 0,
    objects: asInt(wire['objects']) ?? 0,
    markers: asInt(wire['markers']) ?? 0,
  );

  final String id;
  final String name;
  final String? project;
  final String theme;
  final int revision;
  final DateTime? updated;
  final int diagrams;
  final int objects;
  final int markers;

  /// What the list calls the board: its name, or its id when it has none.
  String get display => name.isEmpty ? id : name;

  /// `2 diagrams · 15 objects · 1 marker`.
  String get figures => [
    diagrams == 1 ? '1 diagram' : '$diagrams diagrams',
    objects == 1 ? '1 object' : '$objects objects',
    if (markers > 0) markers == 1 ? '1 marker' : '$markers markers',
  ].join(' · ');
}

/// An affine matrix in SVG order: `matrix(a b c d e f)`, applied as
/// `x' = a·x + c·y + e`, `y' = b·x + d·y + f`.
class BoardMatrix {
  const BoardMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  factory BoardMatrix.fromWire(Object? value) {
    final numbers = [for (final item in asList(value)) asDouble(item) ?? 0];
    if (numbers.length < 6) return identity;
    return BoardMatrix(
      numbers[0],
      numbers[1],
      numbers[2],
      numbers[3],
      numbers[4],
      numbers[5],
    );
  }

  static const identity = BoardMatrix(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  /// The determinant: negative means the matrix turns a shape over.
  double get determinant => a * d - b * c;

  /// Whether the matrix mirrors the shape it places.
  bool get mirrored => determinant < 0;

  /// Where the matrix puts the local point ([x], [y]).
  (double, double) apply(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);

  List<double> get wire => [a, b, c, d, e, f];

  @override
  String toString() => 'matrix(${wire.join(' ')})';

  @override
  bool operator ==(Object other) {
    if (other is! BoardMatrix) return false;
    return other.a == a &&
        other.b == b &&
        other.c == c &&
        other.d == d &&
        other.e == e &&
        other.f == f;
  }

  @override
  int get hashCode => Object.hash(a, b, c, d, e, f);
}

/// One segment of a finite path: `["M", x, y]`, `["L", x, y]`,
/// `["C", x1, y1, x2, y2, x, y]`, `["Q", x1, y1, x, y]` or `["Z"]`.
class BoardPathSegment {
  const BoardPathSegment(this.command, this.numbers);

  factory BoardPathSegment.fromWire(Object? value) {
    final items = asList(value);
    if (items.isEmpty) return const BoardPathSegment('Z', []);
    return BoardPathSegment(
      asStringOr(items.first, 'Z').toUpperCase(),
      [
        for (final number in items.skip(1)) asDouble(number) ?? 0,
      ],
    );
  }

  final String command;
  final List<double> numbers;

  List<Object?> get wire => [command, ...numbers];
}

/// The primitive geometry of a view: what a renderer draws before the
/// view's matrix places it.
class BoardShape {
  const BoardShape({
    this.kind = '',
    this.w = 0,
    this.h = 0,
    this.rx = 0,
    this.ry = 0,
    this.points = const [],
    this.segments = const [],
    this.text = '',
    this.size = 18,
    this.src,
    this.name,
    this.raw = false,
    this.closed = false,
  });

  factory BoardShape.fromWire(JsonMap wire) {
    if (wire.isEmpty) return const BoardShape(kind: '');
    return BoardShape(
      kind: asStringOr(wire['kind'], ''),
      w: asDouble(wire['w']) ?? 0,
      h: asDouble(wire['h']) ?? 0,
      rx: asDouble(wire['rx']) ?? 0,
      ry: asDouble(wire['ry']) ?? 0,
      points: [
        for (final point in asList(wire['points']))
          if (asList(point) case final pair when pair.length >= 2)
            (asDouble(pair[0]) ?? 0, asDouble(pair[1]) ?? 0),
      ],
      segments: [
        for (final segment in asList(wire['segments']))
          BoardPathSegment.fromWire(segment),
      ],
      text: asStringOr(wire['text'], ''),
      size: asDouble(wire['size']) ?? 18,
      src: asString(wire['src']),
      name: asString(wire['name']),
      raw: asBool(wire['raw']),
      closed: asBool(wire['closed']),
    );
  }

  static const none = BoardShape(kind: '');
  static const emptyPolygon = [(0.0, 0.0)];

  final String kind;
  final double w;
  final double h;
  final double rx;
  final double ry;
  final List<(double, double)> points;
  final List<BoardPathSegment> segments;
  final String text;
  final double size;

  /// An image's file or data URI: what a client shows.
  final String? src;
  final String? name;

  /// Raw ink: drawn as its own polyline, never smoothed.
  final bool raw;
  final bool closed;

  bool get isEmpty => kind.isEmpty;

  /// The local bounding box of the shape, before the view's matrix.
  (double, double, double, double) get localBox {
    switch (kind) {
      case 'rect' || 'image':
        return (0, 0, w, h);
      case 'ellipse':
        return (-rx, -ry, rx * 2, ry * 2);
      case 'text':
        // The box of the words is estimated from their size; a text shape
        // has no width of its own on the wire.
        final lines = text.isEmpty ? const [] : text.split('\n');
        var widest = 0.0;
        for (final line in lines) {
          widest = math.max(widest, boardTextWidth(line, size));
        }
        return (0, 0, widest, size * 1.3 * math.max(1, lines.length));
      case 'polygon':
        return _boxOf(points);
      case 'path':
        final points = <(double, double)>[];
        for (final segment in segments) {
          final numbers = segment.numbers;
          for (var i = 0; i + 1 < numbers.length; i += 2) {
            points.add((numbers[i], numbers[i + 1]));
          }
        }
        return _boxOf(points);
      default:
        return (0, 0, 0, 0);
    }
  }

  static (double, double, double, double) _boxOf(List<(double, double)> points) {
    if (points.isEmpty) return (0, 0, 0, 0);
    var minX = points.first.$1;
    var minY = points.first.$2;
    var maxX = minX;
    var maxY = minY;
    for (final point in points) {
      minX = math.min(minX, point.$1);
      minY = math.min(minY, point.$2);
      maxX = math.max(maxX, point.$1);
      maxY = math.max(maxY, point.$2);
    }
    return (minX, minY, maxX - minX, maxY - minY);
  }
}

/// A view's paint: roles a theme resolves, plus the numbers a renderer
/// draws with.  An unknown key is refused by the engine, so this reads the
/// ones the grammar has and leaves the rest out.
class BoardStyle {
  const BoardStyle({
    this.fill,
    this.stroke,
    this.cap,
    this.textColor,
    this.strokeWidth,
    this.dash,
    this.fontSize,
    this.capHeight,
    this.fontWeight,
  });

  factory BoardStyle.fromWire(JsonMap wire) => BoardStyle(
    fill: asString(wire['fill']),
    stroke: asString(wire['stroke']),
    cap: asString(wire['cap']),
    textColor: asString(wire['textColor'] ?? wire['text-color']),
    strokeWidth: asDouble(wire['strokeWidth'] ?? wire['stroke-width']),
    dash: asString(wire['dash']),
    fontSize: asDouble(wire['fontSize'] ?? wire['font-size']),
    capHeight: asDouble(wire['capHeight'] ?? wire['cap-height']),
    fontWeight: asInt(wire['fontWeight'] ?? wire['font-weight']),
  );

  static const none = BoardStyle();

  final String? fill;
  final String? stroke;
  final String? cap;
  final String? textColor;
  final double? strokeWidth;

  /// The dash pattern as the engine writes it: `"6 5"`.
  final String? dash;
  final double? fontSize;
  final double? capHeight;
  final int? fontWeight;

  bool get isEmpty =>
      fill == null &&
      stroke == null &&
      cap == null &&
      textColor == null &&
      strokeWidth == null &&
      dash == null &&
      fontSize == null &&
      capHeight == null &&
      fontWeight == null;

  List<double> get dashPattern => [
    for (final part in (dash ?? '').split(RegExp(r'[ ,]+')))
      if (double.tryParse(part) case final value?) value,
  ];
}

/// A resource an object or a relationship links, with the state it resolved
/// to now.  A precise link is never replaced by a generic one: a message
/// that is not there reads `missing`, not the task's page.
class BoardResource {
  const BoardResource({
    this.kind = '',
    this.ref = '',
    this.label = '',
    this.role,
    this.state = 'unavailable',
    this.note,
    this.name,
    this.column,
    this.taskState,
    this.roleName,
    this.excerpt,
    this.tool,
    this.status,
    this.comments = 0,
    this.target,
    this.updated,
  });

  factory BoardResource.fromWire(JsonMap wire) => BoardResource(
    kind: asStringOr(wire['kind'], ''),
    ref: asStringOr(wire['ref'], ''),
    label: asStringOr(wire['label'], ''),
    role: asString(wire['role']),
    state: asStringOr(wire['state'], 'unavailable'),
    note: asString(wire['note']),
    name: asString(wire['name']),
    column: asString(wire['column']),
    taskState: asString(wire['task-state'] ?? wire['taskState']),
    roleName: asString(wire['role-name'] ?? wire['roleName']),
    excerpt: asString(wire['excerpt']),
    tool: asString(wire['tool']),
    status: asString(wire['status']),
    comments: asInt(wire['comments']) ?? 0,
    target: asString(wire['target']),
    updated: parseTime(wire['updated']),
  );

  final String kind;
  final String ref;
  final String label;
  final String? role;

  /// `resolved`, `stale`, `unsupported`, `missing`, `unavailable` or
  /// `declared` (static evidence, which is not a live thing).
  final String state;
  final String? note;
  final String? name;
  final String? column;
  final String? taskState;
  final String? roleName;
  final String? excerpt;
  final String? tool;
  final String? status;
  final int comments;

  /// A `harness:` link to the precise target, when the engine resolved one.
  final String? target;
  final DateTime? updated;

  bool get resolved => state == 'resolved';

  /// Whether this client can open it: only a resolved link has a target,
  /// and only a `harness:` or `http(s)` target opens outside the app.
  bool get openable =>
      (target ?? '').isNotEmpty &&
      (target!.startsWith('harness:') ||
          target!.startsWith('http://') ||
          target!.startsWith('https://'));

  /// What the row says of the state, in a noun phrase: `Resolved`,
  /// `Stale`, `Unsupported`, `Missing`, `Unavailable`, `Declared`.
  String get stateLabel => switch (state) {
    'resolved' => 'Resolved',
    'stale' => 'Stale',
    'unsupported' => 'Unsupported',
    'missing' => 'Missing',
    'unavailable' => 'Unavailable',
    'declared' => 'Declared',
    _ => state.isEmpty ? 'Unavailable' : state,
  };

  /// What the link is, as the sheet names it: its label, or its kind and ref.
  String get display => label.isNotEmpty
      ? label
      : (ref.isEmpty ? kind : '$kind · $ref');
}

/// A task marker's real source status: what the task says now, or that
/// there is no task board to say.  Nothing here invents activity.
class BoardSourceStatus {
  const BoardSourceStatus({
    this.status = '',
    this.label = '',
    this.column,
    this.state,
    this.id,
    this.session,
    this.updated,
  });

  factory BoardSourceStatus.fromWire(JsonMap wire) => BoardSourceStatus(
    status: asStringOr(wire['status'], ''),
    label: asStringOr(wire['label'], ''),
    column: asString(wire['column']),
    state: asString(wire['state']),
    id: asString(wire['id']),
    session: asString(wire['session']),
    updated: parseTime(wire['updated']),
  );

  final String status;
  final String label;
  final String? column;
  final String? state;
  final String? id;
  final String? session;
  final DateTime? updated;

  /// `resolved`, `missing` or `unsupported`.
  String get stateLabel => switch (status) {
    'resolved' => 'Resolved',
    'missing' => 'Missing',
    'unsupported' => 'Unsupported',
    _ => status.isEmpty ? 'Unavailable' : status,
  };
}

/// One object of a board, drawn in one diagram: its semantic identity, its
/// text, its resources and its representation -- shape, matrix, style,
/// anchors and layer.
class BoardObject {
  const BoardObject({
    required this.id,
    this.kind = '',
    this.name = '',
    this.text = '',
    this.role = 'unknown',
    this.locked = false,
    this.group,
    this.resources = const [],
    this.task,
    this.diagram = '',
    this.shape = BoardShape.none,
    this.transform = BoardMatrix.identity,
    this.style = BoardStyle.none,
    this.anchors = const {},
    this.z = 0,
    this.box = (0.0, 0.0, 0.0, 0.0),
    this.origin = (0.0, 0.0),
    this.diagrams = const [],
    this.mirrored = false,
    this.sourceStatus,
  });

  factory BoardObject.fromWire(JsonMap wire) {
    final box = [for (final item in asList(wire['box'])) asDouble(item) ?? 0];
    final origin = [for (final item in asList(wire['origin'])) asDouble(item) ?? 0];
    final transform = BoardMatrix.fromWire(wire['transform']);
    return BoardObject(
      id: asStringOr(wire['id'], ''),
      kind: asStringOr(wire['kind'], ''),
      name: asStringOr(wire['name'], ''),
      text: asStringOr(wire['text'], ''),
      role: asStringOr(wire['role'], 'unknown'),
      locked: asBool(wire['locked']),
      group: asString(wire['group']),
      resources: [
        for (final item in asMapList(wire['resources']))
          BoardResource.fromWire(item),
      ],
      task: asString(wire['task']),
      diagram: asStringOr(wire['diagram'], ''),
      shape: BoardShape.fromWire(asMap(wire['shape'])),
      transform: transform,
      style: BoardStyle.fromWire(asMap(wire['style'])),
      anchors: {
        for (final entry in asMap(wire['anchors']).entries)
          if (asList(entry.value) case final pair when pair.length >= 2)
            entry.key: (asDouble(pair[0]) ?? 0, asDouble(pair[1]) ?? 0),
      },
      z: asDouble(wire['z']) ?? 0,
      box: box.length >= 4
          ? (box[0], box[1], box[2], box[3])
          : BoardShape.fromWire(asMap(wire['shape'])).localBox,
      origin: origin.length >= 2 ? (origin[0], origin[1]) : (0.0, 0.0),
      diagrams: [
        for (final item in asList(wire['diagrams'])) asStringOr(item, ''),
      ],
      mirrored: asBool(wire['mirrored']) || transform.mirrored,
      sourceStatus: asMap(wire['sourceStatus'] ?? wire['source-status']).isEmpty
          ? null
          : BoardSourceStatus.fromWire(
              asMap(wire['sourceStatus'] ?? wire['source-status']),
            ),
    );
  }

  final String id;
  final String kind;
  final String name;
  final String text;

  /// `observed`, `declared`, `proposed` or `unknown`.
  final String role;
  final bool locked;

  /// The group object this one is a member of, if it is one.
  final String? group;
  final List<BoardResource> resources;

  /// The task id a marker reports, if it reports one.
  final String? task;
  final String diagram;
  final BoardShape shape;

  /// The placement matrix: the shape is drawn in its own local coordinates
  /// and placed by this.
  final BoardMatrix transform;
  final BoardStyle style;

  /// Named local points a relationship may attach to.
  final Map<String, (double, double)> anchors;
  final double z;

  /// The placed bounding box: `(x, y, w, h)` in canvas coordinates.
  final (double, double, double, double) box;

  /// Where the matrix puts the shape's own origin.
  final (double, double) origin;

  /// Every diagram that holds a view of this object.
  final List<String> diagrams;

  /// Whether the matrix has a negative determinant; a transform never
  /// mirrors the text itself.
  final bool mirrored;
  final BoardSourceStatus? sourceStatus;

  /// The kind as the sheet names it: `Note`, `Component`, ...
  String get kindLabel => boardObjectKinds[kind] ?? (kind.isEmpty ? 'Object' : kind);

  /// The role as a sheet names it: `Observed`, `Declared`, `Proposed`,
  /// `Unknown`.
  String get roleLabel => switch (role) {
    'observed' => 'Observed',
    'declared' => 'Declared',
    'proposed' => 'Proposed',
    'unknown' => 'Unknown',
    _ => role.isEmpty ? 'Unknown' : role,
  };

  /// The words the object is drawn with: its text, or its name.
  String get words => text.isNotEmpty ? text : name;

  /// Whether the placed box holds the point, with a margin for a finger.
  bool hits(double x, double y, {double margin = 0}) {
    final (bx, by, bw, bh) = box;
    return x >= bx - margin &&
        x <= bx + bw + margin &&
        y >= by - margin &&
        y <= by + bh + margin;
  }
}

/// A relationship between two placed anchors: a connector drawn as a curve,
/// with an arrow at its end and its label above the midpoint.
class BoardRelationship {
  const BoardRelationship({
    required this.id,
    this.kind = '',
    this.diagram = '',
    this.label = '',
    this.fromObject = '',
    this.fromAnchor = '',
    this.toObject = '',
    this.toAnchor = '',
    this.style = BoardStyle.none,
    this.resources = const [],
    this.role = 'unknown',
    this.fromPoint = (0.0, 0.0),
    this.toPoint = (0.0, 0.0),
    this.hasPoints = false,
  });

  factory BoardRelationship.fromWire(JsonMap wire) {
    final from = asMap(wire['from']);
    final to = asMap(wire['to']);
    final fromPoint = [
      for (final item in asList(wire['fromPoint'] ?? wire['from-point']))
        asDouble(item) ?? 0,
    ];
    final toPoint = [
      for (final item in asList(wire['toPoint'] ?? wire['to-point']))
        asDouble(item) ?? 0,
    ];
    final hasPoints = fromPoint.length >= 2 && toPoint.length >= 2;
    return BoardRelationship(
      id: asStringOr(wire['id'], ''),
      kind: asStringOr(wire['kind'], ''),
      diagram: asStringOr(wire['diagram'], ''),
      label: asStringOr(wire['label'], ''),
      fromObject: asStringOr(from['object'], ''),
      fromAnchor: asStringOr(from['anchor'], ''),
      toObject: asStringOr(to['object'], ''),
      toAnchor: asStringOr(to['anchor'], ''),
      style: BoardStyle.fromWire(asMap(wire['style'])),
      resources: [
        for (final item in asMapList(wire['resources']))
          BoardResource.fromWire(item),
      ],
      role: asStringOr(wire['role'], 'unknown'),
      fromPoint: hasPoints ? (fromPoint[0], fromPoint[1]) : (0.0, 0.0),
      toPoint: hasPoints ? (toPoint[0], toPoint[1]) : (0.0, 0.0),
      hasPoints: hasPoints,
    );
  }

  final String id;
  final String kind;
  final String diagram;
  final String label;

  /// The endpoints as the document names them, and where they are placed.
  final String fromObject;
  final String fromAnchor;
  final String toObject;
  final String toAnchor;
  final BoardStyle style;
  final List<BoardResource> resources;
  final String role;
  final (double, double) fromPoint;
  final (double, double) toPoint;

  /// Whether both endpoints are placed; an endpoint that names an object
  /// having no view here has no point, and the connector is not drawn.
  final bool hasPoints;

  String get roleLabel => switch (role) {
    'observed' => 'Observed',
    'declared' => 'Declared',
    'proposed' => 'Proposed',
    'unknown' => 'Unknown',
    _ => role.isEmpty ? 'Unknown' : role,
  };
}

/// One diagram of a board: a named place, its own viewport and selection,
/// the objects it holds and the diagrams it portals into.
class BoardDiagram {
  const BoardDiagram({
    required this.id,
    this.name = '',
    this.parent,
    this.x = 0,
    this.y = 0,
    this.zoom = 1,
    this.selection = const [],
    this.portals = const [],
  });

  factory BoardDiagram.fromWire(JsonMap wire) {
    final viewport = asMap(wire['viewport']);
    return BoardDiagram(
      id: asStringOr(wire['id'], ''),
      name: asStringOr(wire['name'], ''),
      parent: asString(wire['parent']),
      x: asDouble(viewport['x']) ?? 0,
      y: asDouble(viewport['y']) ?? 0,
      zoom: asDouble(viewport['zoom']) ?? 1,
      selection: [
        for (final item in asList(wire['selection'])) asStringOr(item, ''),
      ],
      portals: [
        for (final item in asMapList(wire['portals']))
          (asStringOr(item['from'], ''), asStringOr(item['diagram'], '')),
      ],
    );
  }

  final String id;
  final String name;
  final String? parent;
  final double x;
  final double y;
  final double zoom;
  final List<String> selection;

  /// `(from, diagram)` pairs: the object that leads into the other diagram.
  final List<(String, String)> portals;

  /// What the breadcrumb calls it: its name, or its id.
  String get display => name.isEmpty ? id : name;
}

/// A place on a board, as `board/focus` stores it and `board/focused`
/// announces: where a client should go.
class BoardPlace {
  const BoardPlace({
    required this.board,
    required this.diagram,
    this.object,
    this.revision = 0,
    this.time,
    this.client = false,
  });

  factory BoardPlace.fromWire(JsonMap wire) => BoardPlace(
    board: asStringOr(wire['board'], ''),
    diagram: asStringOr(wire['diagram'], ''),
    object: asString(wire['object']),
    revision: asInt(wire['revision']) ?? 0,
    time: parseTime(wire['time']),
    client: asBool(wire['client']),
  );

  /// From a `harness:board/BOARD/diagram/D/object/O` link: the same place,
  /// named by its words rather than by an answer.
  factory BoardPlace.fromLink(Uri uri) {
    final parts = [
      for (final part in uri.path.split('/'))
        if (part.isNotEmpty) Uri.decodeComponent(part),
    ];
    String? after(String kind) {
      final index = parts.indexOf(kind);
      if (index < 0 || index + 1 >= parts.length) return null;
      return parts[index + 1];
    }

    final board = parts.length > 1 && parts.first == 'board' ? parts[1] : '';
    return BoardPlace(
      board: board,
      diagram: after('diagram') ?? '',
      object: after('object'),
      revision: int.tryParse(after('revision') ?? '') ?? 0,
    );
  }

  final String board;
  final String diagram;
  final String? object;
  final int revision;

  /// Whether a client was there to hear it.  Never true when none was.
  final bool client;
  final DateTime? time;

  bool get isEmpty =>
      board.isEmpty && diagram.isEmpty && (object ?? '').isEmpty;

  bool samePlace(BoardPlace other) =>
      other.board == board &&
      other.diagram == diagram &&
      (other.object ?? '') == (object ?? '');
}

/// Something near a selection, nearest first.  Nearness is geometry only: it
/// says where things are, never what they mean to one another.
class BoardNearby {
  const BoardNearby({
    required this.id,
    this.name = '',
    this.kind = '',
    this.distance = 0,
  });

  factory BoardNearby.fromWire(JsonMap wire) => BoardNearby(
    id: asStringOr(wire['id'], ''),
    name: asStringOr(wire['name'], ''),
    kind: asStringOr(wire['kind'], ''),
    distance: asDouble(wire['distance']) ?? 0,
  );

  final String id;
  final String name;
  final String kind;
  final double distance;

  String get display => name.isEmpty ? id : name;
}

/// A client's stored view of a board: its viewport, its selection and the
/// last focus request.  Navigation writes this, not a revision.
class BoardClientView {
  const BoardClientView({
    this.x = 0,
    this.y = 0,
    this.zoom = 1,
    this.focus,
  });

  factory BoardClientView.fromWire(JsonMap wire) {
    final viewport = asMap(wire['viewport']);
    final focus = asMap(wire['focus']);
    return BoardClientView(
      x: asDouble(viewport['x']) ?? 0,
      y: asDouble(viewport['y']) ?? 0,
      zoom: asDouble(viewport['zoom']) ?? 1,
      focus: focus.isEmpty ? null : BoardPlace.fromWire(focus),
    );
  }

  final double x;
  final double y;
  final double zoom;
  final BoardPlace? focus;
}

/// The picture the preview's image object draws.
///
/// A harness's image object names a file, which a client reads from the
/// harness; a preview has no harness to ask, so the document carries its
/// own pixels as a raster data URI.  It is a small board on a light field
/// -- a frame with its tab, a note, a component, a connector, raw ink and a
/// region -- so the reference in the drawing is a picture of the thing the
/// design points at, drawn in the same primitives and colours.  An SVG data
/// URI would not do: the canvas decodes rasters only, and would name the
/// image instead of drawing it.
const boardPreviewPicture =
    'data:image/png;base64,'
    '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'
    'SUVORK5CYII=';

/// A board as `board/get` answers it: the one document a client draws from.
class BoardDocument {
  const BoardDocument({
    required this.id,
    this.schema = 1,
    this.name = '',
    this.project,
    this.theme = 'electric-commons',
    this.revision = 0,
    this.created,
    this.updated,
    this.diagram,
    this.diagrams = const [],
    this.objects = const [],
    this.relationships = const [],
    this.nearby = const [],
    this.undoDepth = 0,
    this.writers = const [],
    this.view = const {},
  });

  factory BoardDocument.fromWire(JsonMap wire) {
    final diagram = asMap(wire['diagram']).isEmpty
        ? null
        : BoardDiagram.fromWire(asMap(wire['diagram']));
    final diagrams = [
      for (final item in asMapList(wire['diagrams']))
        BoardDiagram.fromWire(item),
    ];
    return BoardDocument(
      id: asStringOr(wire['id'], ''),
      schema: asInt(wire['schema']) ?? 1,
      name: asStringOr(wire['name'], ''),
      project: asString(wire['project']),
      theme: asStringOr(wire['theme'], 'electric-commons'),
      revision: asInt(wire['revision']) ?? 0,
      created: parseTime(wire['created']),
      updated: parseTime(wire['updated']),
      diagram: diagram ??
          (diagrams.isEmpty ? null : diagrams.first),
      diagrams: diagrams,
      objects: [
        for (final item in asMapList(wire['objects'])) BoardObject.fromWire(item),
      ],
      relationships: [
        for (final item in asMapList(wire['relationships']))
          BoardRelationship.fromWire(item),
      ],
      nearby: [
        for (final item in asMapList(wire['nearby'])) BoardNearby.fromWire(item),
      ],
      undoDepth: asInt(wire['undoDepth'] ?? wire['undo-depth']) ?? 0,
      writers: [
        for (final item in asList(wire['writers'])) asStringOr(item, ''),
      ],
      view: {
        for (final entry in asMap(wire['view']).entries)
          entry.key: BoardClientView.fromWire(asMap(entry.value)),
      },
    );
  }

  final String id;
  final int schema;
  final String name;
  final String? project;
  final String theme;
  final int revision;
  final DateTime? created;
  final DateTime? updated;

  /// The diagram this answer is for; `null` only for a board with none.
  final BoardDiagram? diagram;
  final List<BoardDiagram> diagrams;
  final List<BoardObject> objects;
  final List<BoardRelationship> relationships;
  final List<BoardNearby> nearby;
  final int undoDepth;
  final List<String> writers;

  /// Each client's stored view, by client name.
  final Map<String, BoardClientView> view;

  /// What the page calls the board: its name, or its id.
  String get display => name.isEmpty ? id : name;

  BoardTheme get palette => BoardTheme.of(theme);

  /// The diagram with [id], or null.
  BoardDiagram? diagramOf(String id) {
    for (final diagram in diagrams) {
      if (diagram.id == id) return diagram;
    }
    return null;
  }

  /// The objects of the diagram this answer is for.
  ///
  /// An object's identity is not the diagram it happens to be drawn in:
  /// the same component appears in more than one view, and [objects]
  /// carries one entry for it with every diagram it is placed in.  An
  /// object that names no diagram at all belongs to every view.
  List<BoardObject> get placed {
    final here = diagram?.id ?? '';
    return [
      for (final object in objects)
        if (object.diagrams.isEmpty ||
            object.diagram.isEmpty ||
            here.isEmpty ||
            object.diagrams.contains(here) ||
            object.diagram == here)
          object,
    ];
  }

  /// The objects in the order the layers put them: the smallest z first.
  List<BoardObject> get layered {
    final placed = this.placed;
    placed.sort((a, b) => a.z == b.z ? 0 : (a.z < b.z ? -1 : 1));
    return placed;
  }

  /// The connectors drawn in this document's diagram.  A connector belongs
  /// to the diagram it was drawn in, and a document is for one diagram: the
  /// engine sends only that diagram's, and a document assembled here -- the
  /// preview -- holds every diagram's, so it is filtered here too.
  List<BoardRelationship> get connections => connectionsIn(diagram?.id ?? '');

  /// The connectors drawn in [id], in the order they were written.  A client
  /// that has walked into another diagram asks for that one.
  List<BoardRelationship> connectionsIn(String id) => [
    for (final relationship in relationships)
      if (relationship.hasPoints &&
          (id.isEmpty ||
              relationship.diagram.isEmpty ||
              relationship.diagram == id))
        relationship,
  ];

  BoardObject? objectOf(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final object in objects) {
      if (object.id == id) return object;
    }
    return null;
  }

  /// The diagram and its parent chain, root first: what the breadcrumb shows.
  List<BoardDiagram> lineOf(String? id) {
    final line = <BoardDiagram>[];
    var current = diagramOf(id ?? diagram?.id ?? '');
    final seen = <String>{};
    while (current != null && seen.add(current.id)) {
      line.insert(0, current);
      final parent = current.parent;
      current = parent == null ? null : diagramOf(parent);
    }
    return line;
  }

  /// The first diagram after [id] in its own line, or null when it is the
  /// last; Back walks this line.
  BoardDiagram? parentOf(String? id) {
    final line = lineOf(id);
    if (line.length < 2) return null;
    return line[line.length - 2];
  }

  /// The diagrams whose parent is [id].
  List<BoardDiagram> childrenOf(String? id) => [
    for (final diagram in diagrams)
      if ((diagram.parent ?? '') == (id ?? '') && diagram.id != id) diagram,
  ];

  /// How far a diagram's own geometry reaches, in canvas coordinates, with a
  /// margin.  What a "fit" frames.
  (double, double, double, double) bounds(String? diagramId) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final object in objects) {
      if (diagramId != null &&
          diagramId.isNotEmpty &&
          object.diagram != diagramId) {
        continue;
      }
      final (x, y, w, h) = object.box;
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x + w);
      maxY = math.max(maxY, y + h);
    }
    if (!minX.isFinite) return (0, 0, 900, 620);
    const margin = 48.0;
    return (
      minX - margin,
      minY - margin,
      math.max(320, maxX - minX + margin * 2),
      math.max(240, maxY - minY + margin * 2),
    );
  }

  /// A board to draw when no harness answers, for the previews and the
  /// pictures: the engine's own fixture drawing, in miniature.
  static BoardDocument preview({String diagram = 'd-overview'}) {
    BoardStyle style(Map<String, Object?> wire) => BoardStyle.fromWire(
      wire.map((key, value) => MapEntry(key, value)),
    );
    const overview = BoardDiagram(
      id: 'd-overview',
      name: 'overview',
      selection: ['n-api'],
    );
    const detail = BoardDiagram(
      id: 'd-queue',
      name: 'queue detail',
      parent: 'd-overview',
    );
    final now = DateTime.now();
    final detailHere = diagram == detail.id;
    return BoardDocument(
      id: 'b-fieldnotes',
      name: 'atlas / fieldnotes',
      // A board of a project: what an implementation task asked for from
      // its selection is made in.
      project: '/Users/noah/Code/emacs-agent-harness',
      theme: 'electric-commons',
      revision: 12,
      created: now.subtract(const Duration(hours: 2)),
      updated: now.subtract(const Duration(minutes: 4)),
      diagram: diagram == detail.id ? detail : overview,
      diagrams: const [overview, detail],
      undoDepth: 3,
      objects: [
        BoardObject(
          id: 'f-system',
          kind: 'frame',
          name: 'the system',
          role: 'declared',
          diagram: 'd-overview',
          shape: const BoardShape(kind: 'rect', w: 618, h: 380),
          transform: const BoardMatrix(1, 0, 0, 1, 34, 155),
          style: style({
            'fill': 'frame',
            'stroke': 'edge',
            'cap': 'accent',
            'fontSize': 19,
          }),
          box: (34, 155, 618, 380),
          origin: (34, 155),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-questions',
          kind: 'note',
          name: 'questions',
          role: 'unknown',
          text: 'what happens after a\ntimeout?\ncould a retry charge twice?',
          diagram: 'd-overview',
          // The size the engine's own fixture gives this note (246×122):
          // at a shorter box the wrapped fourth line is cut off.
          shape: const BoardShape(kind: 'rect', w: 246, h: 122),
          transform: const BoardMatrix(1, 0, 0, 1, 60, 190),
          style: style({'fill': 'note', 'stroke': 'none', 'fontSize': 18}),
          anchors: const {'right': (246, 61), 'left': (0, 61)},
          z: 2,
          box: (60, 190, 246, 122),
          origin: (60, 190),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-api',
          kind: 'component',
          name: 'api',
          text: 'accepts jobs',
          role: 'declared',
          // The same component, seen again in the detail: one identity, two
          // views, and each view has its own placement.  The engine answers
          // one document per diagram and this one does too, so the detail
          // draws the component where the detail put it.
          diagram: detailHere ? 'd-queue' : 'd-overview',
          shape: const BoardShape(kind: 'rect', w: 164, h: 91),
          transform: detailHere
              ? const BoardMatrix(1, 0, 0, 1, 120, 300)
              : const BoardMatrix(1, 0, 0, 1, 330, 214),
          style: style({
            'fill': 'card',
            'stroke': 'edge',
            'cap': 'accent',
            'fontSize': 22,
          }),
          anchors: const {'right': (164, 45), 'left': (0, 45)},
          z: 3,
          box: detailHere ? (120, 300, 164, 91) : (330, 214, 164, 91),
          origin: detailHere ? (120, 300) : (330, 214),
          diagrams: const ['d-overview', 'd-queue'],
          resources: [
            BoardResource(
              kind: 'task',
              ref: 't-8f2',
              label: 'task · api',
              state: 'resolved',
              column: 'review',
              name: 'Board canvas',
              target: 'harness:task/t-8f2',
            ),
            BoardResource(
              kind: 'document',
              ref: 'docs/design/freeform-agent-board.md',
              label: 'design note',
              state: 'resolved',
              note: 'readable',
              target: 'harness:board/b-fieldnotes',
            ),
          ],
        ),
        BoardObject(
          id: 'n-workers',
          kind: 'component',
          name: 'worker pool',
          text: 'executes jobs',
          role: 'declared',
          diagram: 'd-overview',
          shape: const BoardShape(kind: 'rect', w: 183, h: 91),
          transform: const BoardMatrix(1, 0, 0, 1, 560, 226),
          style: style({
            'fill': 'card',
            'stroke': 'edge',
            'cap': 'danger',
            'fontSize': 22,
          }),
          anchors: const {'left': (0, 45), 'right': (183, 45)},
          z: 3,
          box: (560, 226, 183, 91),
          origin: (560, 226),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-queue',
          kind: 'component',
          name: 'queue',
          text: 'holds jobs',
          role: 'proposed',
          diagram: 'd-overview',
          shape: const BoardShape(kind: 'rect', w: 150, h: 78),
          transform: const BoardMatrix(1, 0, 0, 1, 336, 388),
          style: style({
            'fill': 'none',
            'stroke': 'violet',
            'strokeWidth': 2,
            'textColor': 'ink',
            'fontSize': 20,
            'cap': 'violet',
          }),
          z: 3,
          box: (336, 388, 150, 78),
          origin: (336, 388),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-marker',
          kind: 'marker',
          name: 'review marker',
          role: 'declared',
          text: 'review · 2',
          task: 't-8f2',
          diagram: 'd-overview',
          shape: const BoardShape(kind: 'rect', w: 13, h: 13),
          transform: const BoardMatrix(1, 0, 0, 1, 336, 318),
          style: style({'fill': 'danger', 'textColor': 'ink', 'fontSize': 14}),
          z: 5,
          box: (336, 318, 13, 13),
          origin: (336, 318),
          diagrams: const ['d-overview'],
          sourceStatus: const BoardSourceStatus(
            status: 'resolved',
            label: 'review · Board canvas',
            column: 'review',
            id: 't-8f2',
          ),
        ),
        BoardObject(
          id: 'n-ink',
          kind: 'ink',
          name: 'ink',
          role: 'declared',
          diagram: 'd-overview',
          shape: const BoardShape(
            kind: 'path',
            raw: true,
            segments: [
              BoardPathSegment('M', [0, 8]),
              BoardPathSegment('L', [9, 3]),
              BoardPathSegment('L', [19, 9]),
              BoardPathSegment('L', [30, 4]),
              BoardPathSegment('L', [41, 9]),
              BoardPathSegment('L', [54, 5]),
              BoardPathSegment('L', [63, 9]),
              BoardPathSegment('L', [78, 4]),
            ],
          ),
          // Clear of the open question's note: ink drawn across a note reads
          // as a scribble over its words.
          transform: const BoardMatrix(1, 0, 0, 1, 736, 534),
          style: style({'stroke': 'ink', 'strokeWidth': 2.2, 'fill': 'none'}),
          z: 4,
          box: (736, 534, 78, 9),
          origin: (736, 534),
          diagrams: const ['d-overview'],
        ),
        // The store, drawn from a path: the grammar's own primitives, not a
        // widget.  Its own words are a second object below, and the retry
        // connector ends on its left anchor.
        BoardObject(
          id: 'n-store',
          kind: 'path',
          name: 'event store',
          role: 'observed',
          diagram: 'd-overview',
          shape: const BoardShape(
            kind: 'path',
            closed: true,
            segments: [
              BoardPathSegment('M', [0, 16]),
              BoardPathSegment('C', [0, 0, 183, 0, 183, 16]),
              BoardPathSegment('L', [183, 75]),
              BoardPathSegment('C', [183, 93, 0, 93, 0, 75]),
              BoardPathSegment('Z', []),
              BoardPathSegment('M', [0, 16]),
              BoardPathSegment('C', [0, 33, 183, 33, 183, 16]),
            ],
          ),
          transform: const BoardMatrix(1, 0, 0, 1, 540, 400),
          style: style({'fill': 'card', 'stroke': 'edge', 'strokeWidth': 1.5}),
          anchors: const {'left': (0, 45), 'right': (183, 45)},
          z: 3,
          box: (540, 400, 183, 93),
          origin: (540, 400),
          diagrams: const ['d-overview'],
          resources: const [
            BoardResource(
              kind: 'symbol',
              ref: 'atlas@a17c:EventStore.append',
              label: 'symbol at a17c',
              state: 'declared',
            ),
          ],
        ),
        BoardObject(
          id: 'n-reference',
          kind: 'image',
          name: 'reference · kinopio',
          role: 'observed',
          diagram: 'd-overview',
          // A picture the preview can draw: a raster data URI, which the
          // canvas decodes.  A harness names a file; the preview has none,
          // so it carries its own pixels rather than an empty outline.
          shape: const BoardShape(
            kind: 'image',
            w: 248,
            h: 155,
            src: boardPreviewPicture,
          ),
          // Clear of the worker pool's card, which ends at x 743: a picture
          // whose words a card covers is a collision nobody asked for.
          transform: const BoardMatrix(1, 0, 0, 1, 772, 190),
          style: style({'fontSize': 15, 'textColor': 'muted'}),
          z: 2,
          box: (772, 190, 248, 155),
          origin: (772, 190),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-store-name',
          kind: 'label',
          name: 'event store',
          role: 'observed',
          text: 'event store',
          diagram: 'd-overview',
          shape: const BoardShape(kind: 'text', text: 'event store', size: 20),
          transform: const BoardMatrix(1, 0, 0, 1, 566, 438),
          style: style({'fill': 'ink', 'fontSize': 20}),
          z: 4,
          box: (566, 438, 120, 26),
          origin: (566, 438),
          diagrams: const ['d-overview'],
        ),
        BoardObject(
          id: 'n-handler',
          kind: 'component',
          name: 'retry handler',
          text: 'looks up the key',
          role: 'observed',
          diagram: 'd-queue',
          shape: const BoardShape(kind: 'rect', w: 200, h: 91),
          transform: const BoardMatrix(1, 0, 0, 1, 120, 160),
          style: style({
            'fill': 'card',
            'stroke': 'edge',
            'cap': 'accent',
            'fontSize': 21,
          }),
          z: 3,
          box: (120, 160, 200, 91),
          origin: (120, 160),
          diagrams: const ['d-queue'],
        ),
        BoardObject(
          id: 'n-record',
          kind: 'component',
          name: 'idempotency record',
          text: 'returns the prior result',
          role: 'proposed',
          diagram: 'd-queue',
          shape: const BoardShape(kind: 'rect', w: 210, h: 91),
          transform: const BoardMatrix(1, 0, 0, 1, 420, 160),
          style: style({
            'fill': 'card',
            'stroke': 'edge',
            'cap': 'violet',
            'fontSize': 21,
          }),
          z: 3,
          box: (420, 160, 210, 91),
          origin: (420, 160),
          diagrams: const ['d-queue'],
        ),
      ],
      relationships: [
        BoardRelationship(
          id: 'e-jobs',
          kind: 'flow',
          diagram: 'd-overview',
          label: 'jobs',
          fromObject: 'n-api',
          fromAnchor: 'right',
          toObject: 'n-workers',
          toAnchor: 'left',
          style: style({'stroke': 'ink', 'strokeWidth': 2.4}),
          role: 'declared',
          fromPoint: (494, 259),
          toPoint: (560, 271),
          hasPoints: true,
        ),
        BoardRelationship(
          id: 'e-queue',
          kind: 'flow',
          diagram: 'd-overview',
          label: 'retry',
          fromObject: 'n-queue',
          fromAnchor: 'right',
          toObject: 'n-store',
          toAnchor: 'left',
          style: style({
            'stroke': 'violet',
            'strokeWidth': 2.4,
            'dash': '6 5',
          }),
          role: 'declared',
          fromPoint: (486, 427),
          toPoint: (540, 416),
          hasPoints: true,
        ),
        BoardRelationship(
          id: 'e-question',
          kind: 'association',
          diagram: 'd-overview',
          label: 'asked',
          fromObject: 'n-questions',
          fromAnchor: 'right',
          toObject: 'n-api',
          toAnchor: 'left',
          style: style({
            'stroke': 'danger',
            'strokeWidth': 2.2,
            'dash': '6 5',
          }),
          role: 'unknown',
          fromPoint: (306, 251),
          toPoint: (330, 259),
          hasPoints: true,
        ),
        BoardRelationship(
          id: 'e-handler-record',
          kind: 'flow',
          diagram: 'd-queue',
          label: 'lookup key',
          fromObject: 'n-handler',
          fromAnchor: 'right',
          toObject: 'n-record',
          toAnchor: 'left',
          style: style({'stroke': 'ink', 'strokeWidth': 2.2}),
          role: 'declared',
          fromPoint: (320, 205),
          toPoint: (420, 205),
          hasPoints: true,
        ),
      ],
    );
  }
}

/// One soft finding of a patch: a warning, never a refusal.  The engine
/// writes its message for a model to read, with the arguments it was
/// formatted with, so a client shows what it can and never breaks on it.
class BoardDiagnostic {
  const BoardDiagnostic({
    this.kind = '',
    this.level = 'warning',
    this.message = '',
    this.ids = const [],
  });

  factory BoardDiagnostic.fromWire(JsonMap wire) {
    return BoardDiagnostic(
      kind: asStringOr(wire['kind'], ''),
      level: asStringOr(wire['level'], 'warning'),
      message: asStringOr(wire['message'], ''),
      ids: [
        for (final item in asList(wire['ids'])) asStringOr(item, ''),
      ],
    );
  }

  final String kind;
  final String level;
  final String message;
  final List<String> ids;

  bool get warning => level != 'error';
}

/// What a patch, a preview, a commit or an undo answers: the batch, where it
/// was made, what it creates and changes, its soft findings and the document
/// it would leave (or left).
class BoardPatchAnswer {
  const BoardPatchAnswer({
    this.patch = '',
    this.hash = '',
    this.board = '',
    this.revision = 0,
    this.base = 0,
    this.ops = const [],
    this.created = const [],
    this.changed = const [],
    this.preimages = const [],
    this.diagnostics = const [],
    this.document,
    this.preview = false,
    this.committed = false,
    this.idempotent = false,
    this.key,
    this.undone,
    this.conflicts = const [],
    this.dryRun = false,
  });

  factory BoardPatchAnswer.fromWire(JsonMap wire) {
    final document = asMap(wire['document']);
    return BoardPatchAnswer(
      patch: asStringOr(wire['patch'], ''),
      hash: asStringOr(wire['hash'], ''),
      board: asStringOr(wire['board'], ''),
      revision: asInt(wire['revision']) ?? 0,
      base: asInt(wire['base']) ?? 0,
      ops: [for (final item in asList(wire['ops'])) asMap(item)],
      created: [
        for (final item in asList(wire['created'])) asStringOr(item, ''),
      ],
      changed: [
        for (final item in asList(wire['changed'])) asStringOr(item, ''),
      ],
      preimages: [
        for (final item in asMapList(wire['preimages'])) asMap(item),
      ],
      diagnostics: boardDiagnosticsFromWire(wire['diagnostics']),
      document: document.isEmpty ? null : BoardDocument.fromWire(document),
      preview: asBool(wire['preview']),
      committed: asBool(wire['committed']),
      idempotent: asBool(wire['idempotent']),
      key: asString(wire['key']),
      undone: asInt(wire['undone']),
      conflicts: [
        for (final item in asMapList(wire['conflicts'])) asMap(item),
      ],
      dryRun: asBool(wire['dryRun'] ?? wire['dry-run']),
    );
  }

  final String patch;
  final String hash;
  final String board;
  final int revision;
  final int base;
  final List<JsonMap> ops;
  final List<String> created;
  final List<String> changed;
  final List<JsonMap> preimages;
  final List<BoardDiagnostic> diagnostics;
  final BoardDocument? document;
  final bool preview;
  final bool committed;

  /// A commit whose key was used before: the answer it gave then, and no
  /// second write.
  final bool idempotent;
  final String? key;
  final int? undone;

  /// The objects an undo left alone: somebody else changed them since.
  final List<JsonMap> conflicts;
  final bool dryRun;

  /// How many objects the batch names.
  int get touched => {...created, ...changed}.length;
}

/// A board error reading helper: the diagnostics of an answer, in either
/// shape the wire may carry them.
List<BoardDiagnostic> boardDiagnosticsFromWire(Object? value) {
  final out = <BoardDiagnostic>[];
  for (final item in asList(value)) {
    final map = asMap(item);
    if (map.isNotEmpty) {
      out.add(BoardDiagnostic.fromWire(map));
    } else if (item is List) {
      // A diagnostic whose keys were paired off wrongly arrives as a list;
      // read what is there rather than fail the whole answer.
      final pairs = <String, Object?>{};
      for (var i = 0; i + 1 < item.length; i += 2) {
        final key = asString(item[i]);
        if (key != null) pairs[key] = item[i + 1];
      }
      out.add(BoardDiagnostic.fromWire(pairs));
    }
  }
  return out;
}

/// An error a board call answers with: the kind the engine refused by, and
/// its message, which is the engine's own words and is shown as it is.
class BoardError {
  const BoardError(this.kind, this.message);

  /// Reads a board error out of an ACP error's message.  The harness answers
  /// `Board error: (stale-revision . "the board is at revision 4, ...")`, so
  /// the kind is the name before the dot and the rest is the message.
  factory BoardError.fromMessage(String message) {
    final text = message.trim();
    final start = text.indexOf('(');
    if (start >= 0) {
      final body = text.substring(start + 1);
      final dot = body.indexOf(' . ');
      if (dot > 0) {
        final kind = body.substring(0, dot).trim();
        if (boardErrorKinds.contains(kind)) {
          var rest = body.substring(dot + 3).trim();
          if (rest.startsWith('"') && rest.endsWith(')')) {
            rest = rest.substring(1, rest.length - 1);
          }
          return BoardError(kind, _unescape(rest));
        }
      }
    }
    for (final kind in boardErrorKinds) {
      if (text.contains(kind)) return BoardError(kind, text);
    }
    return BoardError('', text);
  }

  static String _unescape(String text) => text
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', '\n');

  final String kind;
  final String message;

  bool get isStale => kind == 'stale-revision';

  /// The kind as the client says it: the engine's name, or `Refused`.
  String get kindLabel => kind.isEmpty ? 'Refused' : kind;

  /// What the page says of it, in a noun phrase where the kind has one:
  /// `Stale`, `Permission`, `Unknown object`, ...
  String get summary => switch (kind) {
    'stale-revision' => 'Stale',
    'invalid-parameter' => 'Invalid value',
    'unknown-id' => 'Unknown object',
    'unsupported-operation' => 'Unsupported operation',
    'precondition' => 'Precondition',
    'hard-constraint' => 'Constraint',
    'invalid-reference' => 'Invalid link',
    'permission' => 'Permission',
    _ => 'Refused',
  };
}

/// The board error kinds the engine refuses by (`harness-board-error-kinds`).
const boardErrorKinds = [
  'invalid-parameter',
  'unknown-id',
  'stale-revision',
  'unsupported-operation',
  'precondition',
  'hard-constraint',
  'invalid-reference',
  'permission',
];

/// How wide [text] is at [size], by the estimate the engine's own renderer
/// uses (0.58 of the point size a character).  A picture of words laid out
/// the same way in both places is what keeps a note's inset and its baseline
/// grid aligned with the Emacs page's.
double boardTextWidth(String text, double size) => 0.58 * size * text.length;

/// The line spacing of a text drawn at [size]: the engine's 1.3, so that the
/// same words occupy the same height in both clients.
double boardLineHeight(double size) => size * 1.3;

/// A pinned revision of a board: what a task delivered as its architecture,
/// kept as it was.  Its link is the artifact; the board goes on moving, so
/// the current one is a separate link.
class BoardPin {
  const BoardPin({
    required this.id,
    this.board = '',
    this.task,
    this.title = '',
    this.revision = 0,
    this.diagram = '',
    this.object,
    this.objects = 0,
    this.created,
    this.target,
    this.current,
  });

  factory BoardPin.fromWire(JsonMap wire) => BoardPin(
    id: asStringOr(wire['id'], ''),
    board: asStringOr(wire['board'], ''),
    task: asString(wire['task']),
    title: asStringOr(wire['title'], ''),
    revision: asInt(wire['revision']) ?? 0,
    diagram: asStringOr(wire['diagram'], ''),
    object: asString(wire['object']),
    objects: asInt(wire['objects']) ?? 0,
    created: parseTime(wire['created']),
    target: asString(wire['target']),
    current: asString(wire['current']),
  );

  final String id;
  final String board;
  final String? task;
  final String title;
  final int revision;
  final String diagram;
  final String? object;
  final int objects;
  final DateTime? created;

  /// The artifact's own link, and the board as it goes on.
  final String? target;
  final String? current;

  String get display => title.isEmpty ? id : title;

  /// What the row says of it, in a noun phrase: `revision 12 · 13 objects`.
  String get figures => [
    'revision $revision',
    objects == 1 ? '1 object' : '$objects objects',
  ].join(' · ');
}

/// One pin as the harness keeps it: the pin, the document it froze, and the
/// engine's own rendering of that document.  Nothing here is read from the
/// board as it is now.
class BoardPinnedRevision {
  const BoardPinnedRevision({
    required this.pin,
    this.document,
    this.image,
  });

  final BoardPin pin;
  final BoardDocument? document;

  /// The snapshot drawn by the harness's renderer, as SVG.
  final String? image;
}
