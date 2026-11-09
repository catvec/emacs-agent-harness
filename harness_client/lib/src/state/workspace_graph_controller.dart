import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../models/workspace_graph.dart';
import '../services/harness_api.dart';

/// A place the graph page can show: the thread's own page, one node of it, or
/// another page the thread links.
class WorkspaceGraphView {
  const WorkspaceGraphView.thread() : kind = 'thread', id = '';

  const WorkspaceGraphView.node(this.id) : kind = 'node';

  const WorkspaceGraphView.page(this.id) : kind = 'page';

  final String kind;
  final String id;
}

/// The graph page of a workspace thread: its page, the nodes on it, a node's
/// children and the pages that link it back.
///
/// It keeps the views it walked through, so Back returns to the node or page
/// before this one, as the Emacs explorer does.
class WorkspaceGraphController extends ChangeNotifier {
  WorkspaceGraphController(
    this._api, {
    required this.workspaceId,
    this.threadId,
    this.preview = false,
  });

  /// A controller with a sample graph and no harness behind it, for the
  /// widget tests and the pictures.
  WorkspaceGraphController.preview({
    this.workspaceId = 'w1',
    this.threadId = 'th1',
  }) : _api = null,
       preview = true {
    graph = WorkspaceGraph.preview();
  }

  final HarnessApi? _api;
  final String workspaceId;
  final String? threadId;
  final bool preview;

  WorkspaceGraph? graph;
  bool loading = false;
  String? error;

  final List<WorkspaceGraphView> _views = [const WorkspaceGraphView.thread()];

  WorkspaceGraphView get view => _views.last;
  bool get canGoBack => _views.length > 1;

  /// Read the view this controller is on, from the harness.
  Future<void> load({bool showSpinner = true}) => _fetch(showSpinner);

  Future<void> refresh() => _fetch(false);

  Future<void> openNode(String id) {
    if (id.isEmpty) return Future.value();
    _views.add(WorkspaceGraphView.node(id));
    return _fetch(true);
  }

  Future<void> openPage(String name) {
    if (name.isEmpty) return Future.value();
    _views.add(WorkspaceGraphView.page(name));
    return _fetch(true);
  }

  /// Go back to the view before this one.  The first view stays.
  Future<void> back() {
    if (!canGoBack) return Future.value();
    _views.removeLast();
    return _fetch(true);
  }

  Future<void> _fetch(bool showSpinner) async {
    final api = _api;
    if (preview) {
      graph = WorkspaceGraph.preview();
      notifyListeners();
      return;
    }
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
      graph = switch (view.kind) {
        'node' => await api.workspaceGraphNode(
          workspaceId,
          view.id,
          thread: threadId,
        ),
        'page' => await api.workspaceGraphPage(workspaceId, view.id),
        _ => await api.workspaceGraph(workspaceId, thread: threadId),
      };
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
