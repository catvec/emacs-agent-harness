import '../acp/acp_message.dart';
import 'workspace_speech.dart';

/// What `_harness/workspace/speech/claim` answers: whether this client may
/// say [entry] now, and the floor as it stands.
///
/// A claim is a lease the harness serializes: two clients that claim the
/// same entry in the same instant get one `claimed` and one `holder`, so a
/// room with a phone and a desktop in it says the words once.
class WorkspaceSpeechClaim {
  const WorkspaceSpeechClaim({
    this.claimed = false,
    this.holder,
    this.held = false,
    this.floor,
  });

  factory WorkspaceSpeechClaim.fromWire(JsonMap wire) {
    final floor = asMap(wire['floor']);
    return WorkspaceSpeechClaim(
      claimed: asBool(wire['claimed']),
      holder: asString(wire['holder']),
      held: asBool(wire['held']),
      floor: floor.isEmpty ? null : WorkspaceSpeech.fromWire(floor),
    );
  }

  /// Whether this client holds the entry now: it took it, already had it,
  /// or the entry needs no claim.
  final bool claimed;

  /// The other client holding it, when one does.
  final String? holder;

  /// Whether the floor is held, so nothing starts.
  final bool held;

  /// The floor as the harness has it after the claim.
  final WorkspaceSpeech? floor;
}
