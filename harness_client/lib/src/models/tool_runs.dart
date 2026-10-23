/// How a transcript folds: which of its calls are a run under one summary
/// line.  Plain Dart, so that it is tested without a widget.
///
/// The rules are the Emacs chat's (`harness-chat--regroup`), so that a
/// stretch of looking around is one line in both:
///
///  * Only the calls of the tools on the harness's allow list fold
///    ([ToolCatalogue.folds]).  A call of any other tool is a card of its own
///    and ends the run it meets: the calls before it fold into one summary
///    and the calls after it into another.
///  * A run is calls of such tools with nothing between them but thinking.
///    The thinking folds in with them, since a model that thinks before every
///    call would never have a run otherwise; thinking before the first call
///    or after the last stays out.  Anything else (the agent's words, the
///    person's, a hint, a compaction, a plan) ends a run.
///  * A lone call is a run of one under its summary.
///  * Some calls of listed tools stay out of runs, because a summary line
///    would hide what the person has to see: one whose result brings a
///    picture or a video, one the session waits on the person to allow, and
///    one the harness recorded and the agent never made.
///  * The shape is worked out from the whole list every time, so a transcript
///    that was read in one go and one that grew call by call fold the same.
library;

import '../acp/acp_message.dart';
import 'tool_catalogue.dart';
import 'transcript.dart';

/// A stretch of the transcript that folds under one summary line: calls of
/// the tools on the allow list, with the thinking between them.
class ToolRun {
  ToolRun(this.members, this.tools)
    : assert(members.isNotEmpty && members.first.isTool && members.last.isTool);

  /// The calls and the thinking between them, oldest first.  A run starts
  /// and ends on a call.
  final List<TranscriptItem> members;
  final ToolCatalogue tools;

  /// What the run is known by: its first call's key.
  String get key => members.first.key;

  late final List<ToolView> calls = [
    for (final member in members)
      if (member.isTool && member.tool != null) member.tool!,
  ];

  /// How many thoughts are folded in.  Thinking that says nothing is not a
  /// thought: nothing of it is drawn.
  late final int thoughts = members
      .where((member) => member.isThinking && member.text.trim().isNotEmpty)
      .length;

  /// Calls that ran and reported an error.
  late final int failed = calls
      .where((call) => call.isFailed && !call.isDenied)
      .length;

  /// Calls the permission system refused, so that they never ran.
  late final int denied = calls.where((call) => call.isDenied).length;

  /// Whether a call of the run has not finished.
  late final bool running = calls.any((call) => call.isRunning);

  /// "3 tool calls".
  String get heading =>
      calls.length == 1 ? '1 tool call' : '${calls.length} tool calls';

  /// The calls counted by what people call them, in the order they were
  /// first made: "Read file ×3, Search files".  A lone call is named as its
  /// own card names it, with what it is about: "Read file: lib/a.dart".
  /// [thinking] adds how many thoughts are folded in.
  String detail({bool thinking = true}) {
    final what = calls.length == 1 ? calls.single.displayTitle : _labels();
    final thoughtCount = thinking ? thoughts : 0;
    return switch (thoughtCount) {
      0 => what,
      1 => '$what · thinking',
      _ => '$what · thinking ×$thoughtCount',
    };
  }

  /// The whole summary as one line, as the Emacs chat words it: "3 tool
  /// calls: Read file ×2, Search files · thinking".
  String summary({bool thinking = true}) =>
      '$heading: ${detail(thinking: thinking)}';

  String _labels() {
    final counts = <String, int>{};
    for (final call in calls) {
      counts.update(
        tools.labelOf(call.tool),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return counts.entries
        .map(
          (entry) =>
              entry.value > 1 ? '${entry.key} ×${entry.value}' : entry.key,
        )
        .join(', ');
  }
}

/// One thing the transcript shows in one piece.
sealed class TranscriptSegment {
  const TranscriptSegment();
}

/// An item that stands alone.
class ItemSegment extends TranscriptSegment {
  const ItemSegment(this.item);

  final TranscriptItem item;
}

/// Calls that fold under one summary line.
class RunSegment extends TranscriptSegment {
  const RunSegment(this.run);

  final ToolRun run;
}

/// Whether [item] is a call that folds into a run: it is a call of a tool on
/// the allow list of [tools], and none of the things that keep a call in
/// view applies to it.  [waiting] holds the ids of the calls the session
/// waits for the person to answer.
bool foldsIntoRun(
  TranscriptItem item,
  ToolCatalogue tools, {
  Set<String> waiting = const {},
}) {
  final call = item.tool;
  if (!item.isTool || call == null) return false;
  return tools.folds(call.tool) &&
      // The harness recorded it for the session, as its merge queue does
      // with a resolver: the agent never asked for it, and it runs whatever
      // the session does.
      call.sender == null &&
      !waiting.contains(call.callId) &&
      !showsMedia(call);
}

/// Whether the result of [call] brings an image or a video, which a summary
/// line would hide.
bool showsMedia(ToolView call) => call.attachments.any((attachment) {
  final mime =
      asString(attachment['mime']) ??
      _mimeOfName(
        asString(attachment['path']) ?? asString(attachment['name']) ?? '',
      );
  return mime.startsWith('image/') || mime.startsWith('video/');
});

const _imageExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif', 'heic', 'heif', //
  'tif', 'tiff', 'ico',
};
const _videoExtensions = {
  'mp4', 'm4v', 'mov', 'webm', 'mkv', 'avi', 'mpg', 'mpeg', 'ogv', '3gp', //
};

/// The kind of file a name is, from its extension, when the harness did not
/// say: `image/` or `video/` for the ones a person looks at, else empty.
String _mimeOfName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  final extension = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(extension)) return 'image/$extension';
  if (_videoExtensions.contains(extension)) return 'video/$extension';
  return '';
}

/// [items] as the pieces they are shown in: the items that stand alone, and
/// the runs of calls that fold.  Without a catalogue nothing folds.
List<TranscriptSegment> segmentTranscript(
  List<TranscriptItem> items, {
  required ToolCatalogue tools,
  Set<String> waiting = const {},
}) {
  if (tools.isEmpty) return [for (final item in items) ItemSegment(item)];
  final segments = <TranscriptSegment>[];
  var run = <TranscriptItem>[];
  void flush() {
    // Thinking that comes after the run's last call stays out of it, as the
    // thinking before its first call does.
    var end = run.length;
    while (end > 0 && run[end - 1].isThinking) {
      end--;
    }
    if (end > 0) {
      segments.add(RunSegment(ToolRun(run.sublist(0, end), tools)));
    }
    for (final left in run.skip(end)) {
      segments.add(ItemSegment(left));
    }
    run = <TranscriptItem>[];
  }

  for (final item in items) {
    if (foldsIntoRun(item, tools, waiting: waiting)) {
      run.add(item);
    } else if (run.isNotEmpty && item.isThinking) {
      run.add(item);
    } else {
      flush();
      segments.add(ItemSegment(item));
    }
  }
  flush();
  return segments;
}
