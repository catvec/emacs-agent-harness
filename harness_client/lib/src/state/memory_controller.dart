import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../models/memory.dart';
import '../models/workspace.dart';
import '../services/harness_api.dart';

/// The workspace's memory page: what it kept, and a recall search over it.
class MemoryController extends ChangeNotifier {
  MemoryController(this._api, {required this.workspaceId, this.preview = false});

  MemoryController.preview({this.workspaceId = 'w1'})
    : _api = null,
      preview = true {
    status = WorkspaceMemoryStatus(
      notes: 128,
      last: DateTime.now().subtract(const Duration(minutes: 12)),
      fullText: true,
    );
    notes = previewNotes();
  }

  final HarnessApi? _api;
  final String workspaceId;
  final bool preview;

  WorkspaceMemoryStatus? status;
  List<MemoryNote> notes = const [];
  String query = '';
  bool loading = false;
  bool searching = false;
  String? error;

  bool get hasQuery => query.trim().isNotEmpty;

  Future<void> load({bool showSpinner = true}) async {
    if (preview) {
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null) {
      error = 'No connection';
      notifyListeners();
      return;
    }
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      status = await api.workspaceMemory(workspaceId);
      notes = await api.workspaceMemoryNotes(workspaceId);
      if (!hasQuery) query = '';
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      searching = false;
      notifyListeners();
    }
  }

  /// Recall [text] over the notes.  An empty query goes back to the newest.
  Future<void> search(String text) async {
    final clean = text.trim();
    query = clean;
    if (clean.isEmpty) {
      searching = false;
      await load(showSpinner: false);
      return;
    }
    if (preview) {
      final lower = clean.toLowerCase();
      notes = [
        for (final note in previewNotes())
          if (note.text.toLowerCase().contains(lower))
            MemoryNote(
              id: note.id,
              thread: note.thread,
              role: note.role,
              text: note.text,
              at: note.at,
              snippet: _mark(note.text, clean),
            ),
      ];
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null) return;
    searching = true;
    error = null;
    notifyListeners();
    try {
      notes = await api.workspaceMemorySearch(workspaceId, clean);
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  Future<void> clearSearch() async {
    query = '';
    searching = false;
    notes = const [];
    notifyListeners();
    await load(showSpinner: false);
  }

  /// `<<matched>>` around the first occurrence, for a preview search.  The
  /// harness sends the same markers from FTS.
  String _mark(String text, String query) {
    final at = text.toLowerCase().indexOf(query.toLowerCase());
    if (at < 0) return text;
    return '${text.substring(0, at)}<<${text.substring(at, at + query.length)}>>'
        '${text.substring(at + query.length)}';
  }
}
