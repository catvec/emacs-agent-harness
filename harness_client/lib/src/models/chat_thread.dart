import '../acp/acp_message.dart';

/// A reply in a thread of the conversation, as the harness keeps it.
///
/// A message of the user's or of the agent's may hold a reply as a
/// `<thread>` block ([harness-thread-text] in the harness): the quote of
/// what it answers and the words under it.  A message of the user's carries
/// the data beside the words (`_harness.thread`), structured references to
/// the messages it quotes; the agent writes the block itself, and the quote
/// is all there is.  Both draw as the same card.
///
/// The data is the harness's, read here and never written anywhere else: a
/// reply sent from the app is a text block whose `_harness.thread` holds the
/// same references, which the harness records as the comment of a review
/// (see `harness-thread-reply.el`).
class ChatThreadRef {
  const ChatThreadRef({
    this.kind = 'chat',
    this.who,
    this.label,
    this.node,
    this.session,
    this.part,
    this.from,
    this.to,
    this.text = '',
    this.task,
    this.thread,
    this.comment,
    this.author,
    this.file,
    this.side,
    this.line,
    this.end,
    this.revision,
  });

  /// Read a reference as the harness writes it in `:refs` of a thread.
  factory ChatThreadRef.fromWire(JsonMap wire) => ChatThreadRef(
    kind: asStringOr(wire['kind'], 'chat'),
    who: asString(wire['who']),
    label: asString(wire['label']),
    node: asString(wire['node']),
    session: asString(wire['session']),
    part: asString(wire['part']),
    from: asInt(wire['from']),
    to: asInt(wire['to']),
    text: asStringOr(wire['text'], ''),
    task: asString(wire['task']),
    thread: asString(wire['thread']),
    comment: asString(wire['comment']),
    author: asString(wire['author']),
    file: asString(wire['file']),
    side: asString(wire['side']),
    line: asInt(wire['line']),
    end: asInt(wire['end']),
    revision: asString(wire['revision']),
  );

  final String kind;
  final String? who;
  final String? label;
  final String? node;
  final String? session;
  final String? part;
  final int? from;
  final int? to;
  final String text;
  final String? task;
  final String? thread;
  final String? comment;
  final String? author;
  final String? file;
  final String? side;
  final int? line;
  final int? end;
  final String? revision;

  bool get isChat => kind == 'chat';
  bool get isComment => kind == 'comment';
  bool get isDiff => kind == 'diff';
  bool get isReport => kind == 'report';

  /// Whose words the quote is, as the card names them: `You`, `Agent`, a
  /// plan, a tool call.  The harness calls the user "you" in a reference.
  String get sourceLabel {
    if (kind == 'comment') {
      final name = author?.trim();
      return name == null || name.isEmpty ? 'Comment' : name;
    }
    if (kind == 'diff') return 'Change';
    if (kind == 'buffer') return 'Buffer';
    if (kind == 'report') return 'Hand-in report';
    return switch (who) {
      'you' || 'user' => 'You',
      'agent' || 'assistant' => label == 'thinking' ? 'Thinking' : 'Agent',
      'plan' => 'Plan',
      'thread' => 'Thread answer',
      'report' => 'Hand-in report',
      'tool' => _toolLabel,
      _ => 'Message',
    };
  }

  String get _toolLabel {
    final name = label?.trim();
    if (name == null || name.isEmpty) return 'Tool call';
    return name;
  }

  /// Where the quote is from, beyond whose words: a file and its lines, or
  /// the lines of a message.
  String? get placeLabel {
    final lines = lineLabel;
    final path = file;
    if (path != null && path.isNotEmpty) {
      return lines == null ? path : '$path:$lines';
    }
    if (lines != null) return 'Line $lines';
    return null;
  }

  /// The lines of a change the quote names: `42`, `40–42`, or null.
  String? get lineLabel {
    final first = line;
    if (first == null) return null;
    final last = end;
    if (last != null && last > first) return '$first–$last';
    return '$first';
  }

  /// The review thread this quote is of, when the reference names one.
  String? get reviewThread => thread;

  /// The task of the review it is of, when the reference names one.
  String? get reviewTask => task;

  /// A quote of the whole of [text], of the message [node] in [session]:
  /// what a reply to a message sends as its quote.
  factory ChatThreadRef.message({
    required String node,
    required String who,
    required String text,
    String? session,
    String? label,
  }) => ChatThreadRef(
    kind: 'chat',
    node: node,
    who: who,
    session: session,
    label: label,
    part: 'content',
    text: text,
  );

  /// The reference as the harness reads it: the keys with a value, and a
  /// text when there are words.  A message reference carries the session so
  /// the model has a link back to the message it quotes.
  JsonMap toWire() => <String, Object?>{
    'kind': kind,
    if (who != null) 'who': who,
    if (label != null) 'label': label,
    if (node != null) 'node': node,
    if (session != null) 'session': session,
    if (part != null) 'part': part,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (task != null) 'task': task,
    if (thread != null) 'thread': thread,
    if (comment != null) 'comment': comment,
    if (author != null) 'author': author,
    if (file != null) 'file': file,
    if (side != null) 'side': side,
    if (line != null) 'line': line,
    if (end != null) 'end': end,
    if (revision != null) 'revision': revision,
    if (text.trim().isNotEmpty) 'text': text,
  };
}

/// One reply in a thread: its id, its status, the quote it answers and the
/// words under the quote.
class ChatThread {
  const ChatThread({
    this.id,
    this.status,
    this.response = '',
    this.refs = const <ChatThreadRef>[],
    this.quote,
  });

  /// The thread as a message of the user's keeps it: the data of
  /// `_harness.thread` and the words typed under the quote.
  factory ChatThread.fromWire(JsonMap wire, {String response = ''}) {
    final refs = [
      for (final ref in asMapList(wire['refs'])) ChatThreadRef.fromWire(ref),
    ];
    final quoted = response.isEmpty
        ? asStringOr(wire['response'], '')
        : response;
    return ChatThread(
      id: asString(wire['id']),
      status: asString(wire['status']),
      response: quoted,
      refs: refs,
    );
  }

  /// A reply as a message's block keeps it: the data to draw it and the
  /// text it was written as.  The data says what the reply quotes; when it
  /// names no response, the text has it, as the harness writes both.
  factory ChatThread.fromBlock(JsonMap block) {
    final data = asMap(block['thread']);
    final text = asStringOr(block['text'], '');
    final response = asStringOr(data['response'], '').trim();
    final parsed = parseThreadMarkup(text);
    final written = parsed.threads.isEmpty ? null : parsed.threads.first;
    final id = asString(data['id']);
    final status = asString(data['status']);
    final refs = [
      for (final ref in asMapList(data['refs'])) ChatThreadRef.fromWire(ref),
    ];
    return ChatThread(
      id: id ?? written?.id,
      status: status ?? written?.status,
      response: response.isNotEmpty
          ? response
          : (written?.response ??
                (text.contains('<thread') ? '' : text.trim())),
      refs: refs,
      // The refs already say what is quoted; the markup's quote is for a
      // reply that has none, as an agent writes it.
      quote: refs.isEmpty ? written?.quote : null,
    );
  }

  /// A reply in a thread as an agent writes it: `<thread>` with an optional
  /// `<quote>` and the words under it.  The quote is one piece of text, as
  /// the block holds it; the card says it is a quote.
  factory ChatThread.fromMarkup({
    String? id,
    String? status,
    String? quote,
    required String response,
  }) => ChatThread(id: id, status: status, response: response, quote: quote);

  final String? id;
  final String? status;
  final String response;

  /// What the reply answers: one reference each for a message of the user's,
  /// the quote as written for one of the agent's.
  final List<ChatThreadRef> refs;

  /// The quote of a block the agent wrote, which names no structured
  /// references.  Null for a message of the user's.
  final String? quote;

  bool get hasId => id != null && id!.trim().isNotEmpty;
  bool get isClosed => status == 'closed';
  bool get isOpen => status == 'open';
  bool get hasStatus => isClosed || isOpen;

  /// Whether there is anything to draw above the words: a quote, or the
  /// line of a new thread.
  bool get hasQuote =>
      refs.any((ref) => ref.text.trim().isNotEmpty) ||
      (quote?.trim().isNotEmpty ?? false);

  /// What the card calls itself: a thread the review made, or one the reply
  /// starts.
  String get label => hasId ? 'Thread' : 'New thread';

  /// The words a reply to this thread quotes: its own references, or the
  /// quote it was written with.
  List<ChatThreadRef> get replyRefs {
    if (refs.isNotEmpty) return refs;
    final words = quote?.trim() ?? '';
    if (words.isEmpty) return const <ChatThreadRef>[];
    return [ChatThreadRef(kind: 'chat', who: 'agent', text: words)];
  }

  /// The data a reply in this thread sends: what it quotes, and the thread
  /// it answers when there is one.  No response: the text of the block is
  /// the response.
  JsonMap replyData() => <String, Object?>{
    'refs': [for (final ref in replyRefs) ref.toWire()],
    if (hasId) 'id': id,
  };
}

/// A message's words and the replies in threads it holds.
class ChatThreadText {
  const ChatThreadText({required this.body, required this.threads});

  /// What the message says besides its replies in threads.
  final String body;

  /// The replies, in the order they are written.
  final List<ChatThread> threads;

  static const empty = ChatThreadText(body: '', threads: <ChatThread>[]);

  /// Read a message node: the structured data of its blocks when it has it,
  /// else the `<thread>` blocks its words carry.  The body is the words
  /// that are no reply.
  factory ChatThreadText.fromNode(JsonMap node) {
    final content = asStringOr(node['content'], '');
    final structured = <ChatThread>[
      for (final block in asMapList(node['blocks']))
        if (asMap(block['thread']).isNotEmpty) ChatThread.fromBlock(block),
    ];
    final parsed = parseThreadMarkup(content);
    if (structured.isNotEmpty) {
      // A message of the user's writes the replies twice: the data of its
      // blocks and the markup of their text.  The data is the one to draw.
      return ChatThreadText(
        body: parsed.threads.isEmpty
            ? _bodyWithoutThreadBlocks(node)
            : parsed.body,
        threads: structured,
      );
    }
    return parsed;
  }

  /// The words of a node whose replies are in its blocks: its blocks that
  /// are no reply, a paragraph apart, as the harness reads them
  /// (`harness-blocks-text`).
  static String _bodyWithoutThreadBlocks(JsonMap node) {
    final blocks = asMapList(node['blocks']);
    if (blocks.isEmpty) return asStringOr(node['content'], '');
    final parts = <String>[];
    for (final block in blocks) {
      if (asMap(block['thread']).isNotEmpty) continue;
      if (asString(block['type']) == 'text') {
        final text = asStringOr(block['text'], '').trim();
        if (text.isNotEmpty) parts.add(text);
        continue;
      }
      // Images and files are part of the message's words, as `[image 1]`
      // and an @ reference; a text already has their token.
      final name = asString(block['name']);
      if (asString(block['type']) == 'file' && name != null) {
        parts.add('@$name');
      }
    }
    if (parts.isNotEmpty) return parts.join('\n\n');
    return stripThreadMarkup(node['content']).body;
  }
}

/// The words of [text] without the `<thread>` blocks it holds.
ChatThreadText stripThreadMarkup(Object? text) =>
    parseThreadMarkup(asStringOr(text, ''));

/// Read the strict `<thread>` blocks of [text], oldest first, and return the
/// words around them.
///
/// The form is the harness's (`harness-thread-parse-blocks`): the tags are
/// lowercase and exact, the opening tag has `id` and `status` only, each in
/// double quotes, `status` is `open` or `closed`; the optional `<quote>`
/// comes first; a block in code is an example and no reply; an opening tag
/// never closed is no block.  A block starts a new paragraph in the body,
/// where it stood, and its own words are the card's.
ChatThreadText parseThreadMarkup(String text) {
  if (text.isEmpty) return const ChatThreadText(body: '', threads: []);
  final threads = <ChatThread>[];
  final body = StringBuffer();
  var cursor = 0;
  var searched = 0;
  while (true) {
    final open = text.indexOf('<thread', searched);
    if (open < 0) break;
    final tagEnd = text.indexOf('>', open);
    if (tagEnd < 0) break;
    final after = text.substring(open + '<thread'.length, tagEnd);
    final attributes = _strictAttributes(after);
    if (attributes != null && !_inCode(text, open) && !_inCode(text, tagEnd)) {
      final close = text.indexOf('</thread>', tagEnd + 1);
      if (close >= 0) {
        final block = _parseBlock(
          text.substring(tagEnd + 1, close),
          id: attributes.id,
          status: attributes.status,
        );
        if (block != null) {
          body.write(text.substring(cursor, open));
          if (body.isNotEmpty && !body.toString().endsWith('\n')) {
            body.write('\n\n');
          }
          threads.add(block);
          cursor = close + '</thread>'.length;
          searched = cursor;
          continue;
        }
      }
    }
    searched = tagEnd + 1;
  }
  body.write(text.substring(cursor));
  return ChatThreadText(body: _tidyBody(body.toString()), threads: threads);
}

String _tidyBody(String text) {
  // A removed block leaves the blank lines around it; a message reads as
  // the words that were there, not as the gaps it left.
  final lines = text.split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  // A block between two paragraphs leaves the blank lines of both: the
  // message reads as one paragraph break where it stood.
  return lines.join('\n').trimRight().replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

({String? id, String? status})? _strictAttributes(String after) {
  if (after.isEmpty) return (id: null, status: null);
  if (!after.startsWith(' ')) return null;
  final seen = <String>{};
  String? id;
  String? status;
  for (final part in after.substring(1).split(' ')) {
    final match = RegExp(r'^(id|status)="([^"\n]*)"$').firstMatch(part);
    if (match == null) return null;
    final name = match.group(1)!;
    final value = match.group(2)!;
    if (!seen.add(name)) return null;
    if (name == 'id') {
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(value)) {
        return null;
      }
      id = value;
    } else {
      if (value != 'open' && value != 'closed') return null;
      status = value;
    }
  }
  return (id: id, status: status);
}

/// Read what stands between the tags of a reply: its quote, when it has one,
/// and the words under it.  Nil when it is no strict block.
ChatThread? _parseBlock(String inner, {String? id, String? status}) {
  final content = inner.trim();
  if (content.isEmpty) {
    // Closing or opening a thread needs no words.
    return status == null
        ? null
        : ChatThread.fromMarkup(id: id, status: status, response: '');
  }
  if (content.startsWith('<quote>')) {
    final close = content.indexOf('</quote>', '<quote>'.length);
    if (close < 0) return null;
    final quote = content.substring('<quote>'.length, close).trim();
    final rest = content.substring(close + '</quote>'.length).trim();
    if (quote.isEmpty) return null;
    if (_hasTag(quote, 'quote') || _hasTag(quote, 'thread')) return null;
    if (_hasTag(rest, 'quote')) return null;
    if (rest.isNotEmpty && !_strictBody(rest)) return null;
    return ChatThread.fromMarkup(
      id: id,
      status: status,
      quote: quote,
      response: rest,
    );
  }
  if (_hasTag(content, 'quote')) return null;
  if (!_strictBody(content)) return null;
  return ChatThread.fromMarkup(id: id, status: status, response: content);
}

/// Whether [body] holds another reply tag; the harness refuses a wrapper such
/// as `<reply>`.
bool _strictBody(String body) {
  if (_hasTag(body, 'thread') || _hasTag(body, 'quote')) return false;
  return !RegExp(
    r'<\s*/?\s*(?:reply|response|answer)\b',
    caseSensitive: false,
  ).hasMatch(body);
}

bool _hasTag(String text, String name) =>
    RegExp('<\\s*/?\\s*$name\\b', caseSensitive: false).hasMatch(text);

/// Whether [position] in [text] is inside a fenced or inline code span, as
/// the harness reads it: a `<thread>` written as an example is no reply.
bool _inCode(String text, int position) {
  final before = text.substring(0, position);
  var fences = 0;
  for (final line in before.split('\n')) {
    if (RegExp(r'^[ \t]*(?:```|~~~)').hasMatch(line)) fences++;
  }
  if (fences.isOdd) return true;
  final lineStart = before.lastIndexOf('\n') + 1;
  final ticks = '`'.allMatches(text.substring(lineStart, position)).length;
  return ticks.isOdd;
}

/// A reply being written: what it quotes and, for a reply in an existing
/// thread, the thread it answers.
///
/// It is the app's, not the harness's: the words are the composer's draft,
/// and the reply goes out with them as one text block whose `_harness.thread`
/// is [threadData].  A reply that fails to send keeps this, so that trying
/// again answers the same message and not another.
class ChatReplyDraft {
  const ChatReplyDraft({this.refs = const <ChatThreadRef>[], this.threadId});

  final List<ChatThreadRef> refs;

  /// The thread the reply answers; null for a new one.
  final String? threadId;

  bool get hasThread => threadId != null && threadId!.trim().isNotEmpty;

  /// What the composer's bar calls what is answered.
  String get label => hasThread ? 'Thread' : 'Message';

  /// The words of the quote, as the bar shows their start.
  String get excerpt => refs
      .map((ref) => ref.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  /// Whose words are answered, for the bar: the first reference's source.
  String? get sourceLabel => refs.isEmpty ? null : refs.first.sourceLabel;

  JsonMap threadData() => <String, Object?>{
    'refs': [for (final ref in refs) ref.toWire()],
    if (hasThread) 'id': threadId,
  };
}
