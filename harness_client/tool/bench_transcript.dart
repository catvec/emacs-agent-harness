// How long the app takes to read a transcript of a given size, without a
// device: the JSON decode, one `applyNode` per node, and the displayed
// order, which a screen asks for on every build.
//
// The content is synthetic.  It is a chain of message, thought and tool
// nodes like a long conversation, and no real transcript is read.
//
//   cd harness_client
//   dart run tool/bench_transcript.dart [NODE_COUNT] [BYTES_PER_NODE]
//
// With no arguments it measures a small open (60 nodes), a long one (400)
// and a very long one (1200), each node about 5 KB.
import 'dart:convert';
import 'dart:io';

import 'package:harness_client/src/models/transcript.dart';

typedef JsonMap = Map<String, Object?>;

List<JsonMap> conversation(int count, int bytes) {
  final nodes = <JsonMap>[];
  for (var i = 0; i < count; i++) {
    final kind = switch (i % 5) {
      0 => 'user',
      1 => 'assistant',
      2 => 'thinking',
      3 => 'tool-call',
      _ => 'tool-result',
    };
    final id = 'n-${i.toString().padLeft(5, '0')}';
    final node = <String, Object?>{
      'id': id,
      'session': 'bench',
      'parent': i == 0 ? null : 'n-${(i - 1).toString().padLeft(5, '0')}',
      'ts': 1794000000 + i * 0.5,
      'kind': kind,
    };
    switch (kind) {
      case 'tool-call':
        node
          ..['call-id'] = 'call-$i'
          ..['tool'] = 'read_file'
          ..['title'] = 'Read a file'
          ..['input'] = {'path': '/tmp/file-$i'};
      case 'tool-result':
        node
          ..['call-id'] = 'call-${i - 1}'
          ..['tool'] = 'read_file'
          ..['title'] = 'Read a file'
          ..['output'] = 'x' * bytes;
      default:
        node['content'] =
            '${'a' * bytes}\n\nSome **markdown**, `code` and a [link](https://example.invalid/).';
    }
    nodes.add(node);
  }
  return nodes;
}

double ms(Stopwatch watch) => watch.elapsedMicroseconds / 1000.0;

void measure(int count, int bytes) {
  final nodes = conversation(count, bytes);
  final encoded = jsonEncode({'nodes': nodes});
  final watch = Stopwatch()..start();
  final decoded = jsonDecode(encoded) as Map<String, Object?>;
  final decode = ms(watch);
  final wire = (decoded['nodes'] as List).cast<JsonMap>();

  watch
    ..reset()
    ..start();
  final transcript = TranscriptState();
  for (final node in wire) {
    transcript.applyNode(node);
  }
  final apply = ms(watch);

  watch
    ..reset()
    ..start();
  final first = transcript.displayItems;
  final firstOrder = ms(watch);

  watch
    ..reset()
    ..start();
  for (var i = 0; i < 100; i++) {
    transcript.displayItems;
  }
  final repeatedOrder = ms(watch) / 100;

  watch
    ..reset()
    ..start();
  transcript.addLocalUser('a message sent while it reads');
  final addLocal = ms(watch);
  final afterChange = transcript.displayItems;

  final order = identical(first, afterChange) ? 'stale' : 'new';
  stdout.writeln(
    'BENCH nodes=$count bytes=${encoded.length} '
    'decode=${decode.toStringAsFixed(2)}ms '
    'apply=${apply.toStringAsFixed(2)}ms '
    'order-first=${firstOrder.toStringAsFixed(2)}ms '
    'order-repeat=${repeatedOrder.toStringAsFixed(3)}ms '
    'order-after-change=$order '
    'items=${afterChange.length} '
    'local-add=${addLocal.toStringAsFixed(3)}ms',
  );
}

void main(List<String> args) {
  final count = args.isNotEmpty ? int.parse(args[0]) : 0;
  final bytes = args.length > 1 ? int.parse(args[1]) : 5000;
  if (count > 0) {
    measure(count, bytes);
    return;
  }
  for (final size in [60, 400, 1200]) {
    measure(size, bytes);
  }
}
