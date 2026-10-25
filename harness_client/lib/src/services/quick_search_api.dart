import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/quick_search.dart';
import 'harness_api.dart';

/// What the model that answers a search is, and whether a process of it is
/// ready: what `search/warm` says.
class SearchModel {
  const SearchModel({required this.id, this.warm = false});
  final String id;
  final bool warm;
}

/// The harness's quick search, over ACP: the same three methods the harness's
/// Emacs asks, so a line typed on the phone is answered as it is there --
/// by the same model, from the same sessions, tasks and rules -- and only
/// what the app itself can do (its commands, which it sends along) is the
/// app's to know.
///
///  * `search/ask` runs a search and answers with its plan; nothing changes.
///  * `search/warm` starts the model's process, so that it is ready by the
///    time the line is typed.
///  * `task/search-apply` does what the plan proposes to tasks, once a person
///    said yes.
class QuickSearchApi {
  QuickSearchApi(this.api);

  final HarnessApi api;

  /// How long the app waits for a plan.  The harness gives a model call 45
  /// seconds and a search two of them at most, then says why it failed: its
  /// word, not a timeout of the app's, should be the one a person reads.
  static const askTimeout = Duration(seconds: 150);

  /// Whether the harness can answer a search at all: an older one, or one
  /// without its search module, cannot.
  bool get canSearch => api.can('search/ask');

  /// Whether the harness can do what a search proposes.
  bool get canApply => api.can('task/search-apply');

  /// Have the harness start the model of the next search of the project
  /// [cwd]; say which model that is.  Null when it has none, or the harness
  /// does not offer the method: a search then finds out for itself.
  Future<SearchModel?> warm(String cwd) async {
    if (!api.can('search/warm')) return null;
    final reply = await api.extensionRaw('search/warm', {'cwd': cwd});
    if (reply is! Map) return null;
    final wire = asMap(reply);
    final id = asString(wire['model']);
    if (id == null || id.isEmpty) return null;
    return SearchModel(id: id, warm: asBool(wire['warm']));
  }

  /// Ask the harness about [query], typed in the project [cwd].  [context]
  /// says where (see `QuickSearchPlace.toContext`), [bias] what to favour,
  /// and [commands] is what the app can do: each entry as
  /// `QuickCommand.toWire` has it, the only commands the answer may name.
  Future<QuickSearchPlan> ask({
    required String cwd,
    required String query,
    required SearchBias bias,
    required JsonMap context,
    required List<JsonMap> commands,
  }) async {
    final reply = await api.extension('search/ask', {
      'cwd': cwd,
      'query': query,
      'opts': {'bias': bias.wire, 'context': context, 'commands': commands},
    }, askTimeout);
    return QuickSearchPlan.fromWire(reply);
  }

  /// Do [actions], which a plan proposed, one after the other: how each
  /// went.  A harness that cannot is an [AcpException].
  Future<List<ActionResult>> apply(List<ProposedAction> actions) async {
    final reply = await api.extensionRaw('task/search-apply', {
      'actions': [for (final action in actions) action.toWire()],
    }, const Duration(seconds: 60));
    return [for (final item in asMapList(reply)) ActionResult.fromWire(item)];
  }

  /// A failure in words for a person: the harness's own message for an error
  /// of its, else what happened.
  static String describe(Object error) {
    if (error is AcpException) {
      final message = error.message.trim();
      if (error.isTransport) {
        return message.isEmpty ? 'The connection was lost.' : message;
      }
      return message.isEmpty ? 'The harness gave an error.' : message;
    }
    final text = '$error'.trim();
    return text.isEmpty ? 'Something went wrong.' : text;
  }
}
