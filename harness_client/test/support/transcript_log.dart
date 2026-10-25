// A transcript written the way the harness writes its nodes, one item at a
// time, for the tests of how a transcript folds into runs of tool calls and
// how those are drawn: the same `tool-call` and `tool-result` nodes (with
// `call-id`, `is-error` and the result's `meta`) that a session replays, so
// that what is tried is what the app reads.

import 'package:harness_client/src/models/transcript.dart';

class TranscriptLog {
  final transcript = TranscriptState();
  int _n = 0;

  /// The node written last: the one the next follows (`parent`), as the
  /// harness's nodes each say which they follow.
  String? _last;

  /// The nodes written so far, oldest first: what a harness holds of the
  /// session, to serve it or to send it as it grows.
  final List<Map<String, Object?>> nodes = [];

  /// The items of the transcript so far, in the order they came in; the list
  /// grows as the log does, as the app's does.
  List<TranscriptItem> get items => transcript.items;

  /// What the screen shows of the transcript so far: [items] in the order
  /// the harness recorded them.
  List<TranscriptItem> get displayItems => transcript.displayItems;

  /// Write a node: it is kept, and read into the transcript.
  void _write(String kind, Map<String, Object?> rest) {
    final id = 'n${++_n}';
    final node = {
      'id': id,
      'kind': kind,
      'ts': 1.0 + _n,
      'parent': _last,
      ...rest,
    };
    _last = id;
    nodes.add(node);
    transcript.applyNode(node);
  }

  void user(String text) => _write('user', {'content': text});

  void say(String text) => _write('assistant', {'content': text});

  void think(String text) => _write('thinking', {'content': text});

  void hint(String text) => _write('hint', {'content': text});

  /// A call of [tool] and, unless [result] is false, its result: [error]
  /// says it failed, [denied] that the permission system refused it,
  /// [attachments] what it brought, and [from] who recorded it when the
  /// agent did not make it.
  void call(
    String id,
    String tool, {
    String? title,
    Map<String, Object?> input = const {'path': 'a.dart'},
    bool result = true,
    String output = 'ok',
    bool error = false,
    bool denied = false,
    List<Map<String, Object?>>? attachments,
    Map<String, Object?>? from,
  }) {
    _write('tool-call', {
      'call-id': id,
      'tool': tool,
      'title': ?title,
      'input': input,
      'meta': {'from': ?from},
    });
    if (result) {
      this.result(
        id,
        output: output,
        error: error,
        denied: denied,
        attachments: attachments,
        from: from,
      );
    }
  }

  /// The result of the call [id], which came after it.
  void result(
    String id, {
    String output = 'ok',
    bool error = false,
    bool denied = false,
    List<Map<String, Object?>>? attachments,
    Map<String, Object?>? from,
  }) {
    _write('tool-result', {
      'call-id': id,
      'output': output,
      'is-error': error ? true : null,
      'attachments': attachments,
      'meta': {'duration': 0.1, 'denied': denied ? true : null, 'from': ?from},
    });
  }
}
