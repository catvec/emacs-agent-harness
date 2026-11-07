import '../acp/acp_message.dart';
import 'session.dart';

/// One note in the workspace's memory: a turn the assistant kept, with the
/// thread it belongs to.  Search results add a [snippet] that marks the
/// matched words between `<<` and `>>`.
class MemoryNote {
  const MemoryNote({
    required this.id,
    this.thread = '',
    this.role = 'user',
    this.text = '',
    this.snippet = '',
    this.at,
  });

  factory MemoryNote.fromWire(JsonMap wire) => MemoryNote(
    id: asStringOr(wire['id'], ''),
    thread: asStringOr(wire['thread'], ''),
    role: asStringOr(wire['role'], 'user'),
    text: asStringOr(wire['text'], ''),
    snippet: asStringOr(wire['snippet'], ''),
    at: parseTime(wire['ts'] ?? wire['at']),
  );

  final String id;
  final String thread;
  final String role;
  final String text;
  final String snippet;
  final DateTime? at;

  bool get isAgent => role == 'assistant' || role == 'agent';
  String get roleLabel => isAgent ? 'Agent' : 'You';

  /// The text to show: a search snippet when there is one, else the note.
  String get display => snippet.isEmpty ? text : snippet;
}

/// A few notes for the preview and the pictures.  They are sample text, not
/// anything the harness stored.
List<MemoryNote> previewNotes() {
  final now = DateTime.now();
  return [
    MemoryNote(id: 'n1', thread: 'Kitchen renovation', role: 'user',
        text: 'Let us go with quartz for the countertop.', at: now.subtract(const Duration(minutes: 12))),
    MemoryNote(id: 'n2', thread: 'Kitchen renovation', role: 'assistant',
        text: 'Updated Decision/Countertop and opened the quote task. The fabricator can template on Tuesday.',
        at: now.subtract(const Duration(minutes: 11))),
    MemoryNote(id: 'n3', thread: 'Harness memory', role: 'assistant',
        text: 'The recall index keeps the thread and the page it came from, so the brief can quote the source.',
        at: now.subtract(const Duration(hours: 5))),
    MemoryNote(id: 'n4', thread: 'Kitchen budget', role: 'user',
        text: 'The countertop quote came back 200 over budget; ask about the edge profile.',
        at: now.subtract(const Duration(days: 1))),
  ];
}
