import '../acp/acp_message.dart';

/// One mode an ACP agent offers for a session: ACP's `SessionMode`.
///
/// [id] is what `session/set_mode` takes; [name] is what a person reads.
class SessionMode {
  const SessionMode({required this.id, required this.name, this.description});

  factory SessionMode.fromWire(JsonMap wire) {
    final id = asString(wire['id']) ?? '';
    final name = asString(wire['name']);
    return SessionMode(
      id: id,
      name: name == null || name.trim().isEmpty ? id : name,
      description: asString(wire['description']),
    );
  }

  final String id;
  final String name;
  final String? description;
}

/// ACP's `SessionModeState`: the mode a session is in and the modes it can
/// operate in.  An agent that offers no modes sends no such object, and the
/// client offers none: a mode picker is only shown for what the session says
/// it has (see `SessionController.canChangeMode`).
class SessionModes {
  const SessionModes({required this.currentModeId, required this.available});

  /// The state in [raw], an initialize-shaped `modes` object, or null when it
  /// names no mode that can be chosen.
  static SessionModes? fromWire(Object? raw) {
    final wire = asMap(raw);
    final available = <SessionMode>[];
    for (final mode in asMapList(wire['availableModes'])) {
      final parsed = SessionMode.fromWire(mode);
      if (parsed.id.isNotEmpty) available.add(parsed);
    }
    if (available.isEmpty) return null;
    final current = asString(wire['currentModeId']);
    return SessionModes(
      currentModeId: current == null || current.isEmpty
          ? available.first.id
          : current,
      available: List.unmodifiable(available),
    );
  }

  final String currentModeId;
  final List<SessionMode> available;

  /// The mode [currentModeId] names, when the agent still offers it.
  SessionMode? get current {
    for (final mode in available) {
      if (mode.id == currentModeId) return mode;
    }
    return null;
  }

  SessionModes withCurrent(String id) =>
      SessionModes(currentModeId: id, available: available);
}
