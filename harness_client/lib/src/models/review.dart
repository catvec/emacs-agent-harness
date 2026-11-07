import '../acp/acp_message.dart';
import 'session.dart' show parseTime;

/// A task's change review: its versions, threads, comments and the files it
/// changes, as the harness keeps them (`patch-review/get`,
/// `patch-review/changes`).
///
/// The data is the harness's own.  The phone adds nothing to it: a comment
/// made here is an `add-comment` operation (`patch-review/apply`) with the
/// revision of the diff the line was read at, a reply names the comment it
/// answers, closing a thread is a `set-status` operation, and a review mark
/// is `mark-reviewed`.  Emacs, the app and another device all see the same
/// threads, because all of them write through those operations.

/// Who wrote a comment: a person, an agent, or another source.
class ReviewAuthor {
  const ReviewAuthor({
    this.kind = 'user',
    this.name,
    this.email,
    this.session,
    this.toolCall,
  });

  factory ReviewAuthor.fromWire(Object? wire) {
    final map = asMap(wire);
    return ReviewAuthor(
      kind: asStringOr(map['kind'], 'user'),
      name: asString(map['name']),
      email: asString(map['email']),
      session: asString(map['session']),
      toolCall: asString(map['tool-call'] ?? map['toolCall']),
    );
  }

  /// `user`, `agent` or `other`.
  final String kind;
  final String? name;
  final String? email;

  /// The conversation an agent wrote in, and the tool call that made the
  /// comment, which is how to get back to that point of it.
  final String? session;
  final String? toolCall;

  bool get isUser => kind == 'user';
  bool get isAgent => kind == 'agent';

  /// How the author is named: their name, their address, or what they are.
  String get label {
    final given = name;
    if (given != null && given.trim().isNotEmpty) return given.trim();
    final address = email;
    if (address != null && address.trim().isNotEmpty) return address.trim();
    return switch (kind) {
      'agent' => 'Agent',
      'user' => 'You',
      _ => 'Unknown',
    };
  }

  JsonMap toWire() => {
    'kind': kind,
    if (name != null) 'name': name,
    if (email != null) 'email': email,
    if (session != null) 'session': session,
    if (toolCall != null) 'tool-call': toolCall,
  };
}

/// Where in the change a comment was made: a file, a side of it, a line or a
/// range, and the part of the diff around it when it was written.
class ReviewLocation {
  const ReviewLocation({
    required this.file,
    this.oldFile,
    this.side = 'new',
    this.line,
    this.endLine,
    this.excerpt,
    this.patch,
  });

  factory ReviewLocation.fromWire(Object? wire) {
    final map = asMap(wire);
    if (map.isEmpty) return const ReviewLocation(file: '');
    return ReviewLocation(
      file: asStringOr(map['file'], ''),
      oldFile: asString(map['old-file'] ?? map['oldFile']),
      side: asStringOr(map['side'], 'new'),
      line: asInt(map['line']),
      endLine: asInt(map['end-line'] ?? map['endLine']),
      excerpt: asString(map['excerpt']),
      patch: asInt(map['patch']),
    );
  }

  /// The path after the change (before it, for a deleted file).
  final String file;

  /// The path before the change, for a rename or a copy.
  final String? oldFile;

  /// `new` for a line of the file after the change, `old` for one before it.
  final String side;
  final int? line;
  final int? endLine;

  /// The hunk of the line or range, as unified-diff lines: a hunk header,
  /// then lines each starting with " ", "+" or "-", the commented line last.
  final String? excerpt;

  /// The patch of a series the file is in, when the version is a series.
  final int? patch;

  bool get isOld => side == 'old';

  /// "lib/a.dart:12", "lib/a.dart:12–15", or the file alone.
  String get label {
    final path = file.isEmpty ? 'The change' : file;
    final start = line;
    final end = endLine;
    if (start == null) return path;
    if (end != null && end != start) return '$path:$start–$end';
    return '$path:$start';
  }

  /// The same location against the line range [line]..[end], of [side].
  ReviewLocation withRange({
    required int line,
    int? endLine,
    required String side,
  }) => ReviewLocation(
    file: file,
    oldFile: oldFile,
    side: side,
    line: line,
    endLine: endLine == line ? null : endLine,
    excerpt: excerpt,
  );

  ReviewLocation withExcerpt(String? excerpt) => ReviewLocation(
    file: file,
    oldFile: oldFile,
    side: side,
    line: line,
    endLine: endLine,
    excerpt: excerpt,
    patch: patch,
  );

  JsonMap toWire() => {
    'file': file,
    if (oldFile != null && oldFile!.isNotEmpty) 'old-file': oldFile,
    if (isOld) 'side': 'old',
    if (line != null) 'line': line,
    if (endLine != null) 'end-line': endLine,
    if (excerpt != null && excerpt!.isNotEmpty) 'excerpt': excerpt,
    if (patch != null) 'patch': patch,
  };
}

/// One message of a thread.
class ReviewComment {
  const ReviewComment({
    required this.id,
    required this.thread,
    this.replyTo,
    required this.author,
    required this.body,
    this.time,
    this.location,
    this.revision,
    this.sent,
    this.edited,
    this.meta = const {},
  });

  factory ReviewComment.fromWire(JsonMap wire) => ReviewComment(
    id: asStringOr(wire['id'], ''),
    thread: asStringOr(wire['thread'], ''),
    replyTo: asString(wire['reply-to'] ?? wire['replyTo']),
    author: ReviewAuthor.fromWire(wire['author']),
    body: asStringOr(wire['body'], ''),
    time: parseTime(wire['time']),
    location: ReviewLocation.fromWire(wire['location']).file.isEmpty
        ? null
        : ReviewLocation.fromWire(wire['location']),
    revision: asString(wire['revision']),
    sent: parseTime(wire['sent']),
    edited: parseTime(wire['edited']),
    meta: asMap(wire['meta']),
  );

  final String id;
  final String thread;
  final String? replyTo;
  final ReviewAuthor author;
  final String body;
  final DateTime? time;
  final ReviewLocation? location;

  /// The version's revision the comment was written against: what its line
  /// means, whatever the branch does later.
  final String? revision;

  /// When the comment was delivered; null while it is a draft.
  final DateTime? sent;
  final DateTime? edited;
  final JsonMap meta;

  bool get isDraft => sent == null;

  /// The words without the quote a reply carries above them, for a list.
  String get answerText {
    final lines = body.split('\n');
    final answer = lines.firstWhere(
      (line) => line.trim().isNotEmpty && !line.trimLeft().startsWith('>'),
      orElse: () => '',
    );
    if (answer.trim().isNotEmpty) return answer.trim();
    return lines
        .map((line) => line.replaceFirst(RegExp(r'^[>\s]+'), ''))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  }

  /// The quote of this comment a reply starts with: the comment's markdown
  /// lines, each quoted, under a line naming its author.
  String get quoteMarkdown {
    final quote = body
        .trim()
        .split('\n')
        .map((line) => line.trim().isEmpty ? '>' : '> $line')
        .join('\n');
    return '> ${author.label}:\n$quote';
  }

  JsonMap toWire() => {
    'id': id,
    'thread': thread,
    if (replyTo != null) 'reply-to': replyTo,
    'author': author.toWire(),
    'body': body,
    if (location != null) 'location': location!.toWire(),
    if (revision != null) 'revision': revision,
    if (sent != null) 'sent': sent!.millisecondsSinceEpoch / 1000.0,
  };
}

/// One change of a thread's status: who closed or opened it, and when.
class ReviewHistoryEntry {
  const ReviewHistoryEntry({
    this.id,
    required this.status,
    this.time,
    this.author,
    this.revision,
    this.reviewed,
  });

  factory ReviewHistoryEntry.fromWire(JsonMap wire) => ReviewHistoryEntry(
    id: asString(wire['id']),
    status: asStringOr(wire['status'], 'open'),
    time: parseTime(wire['time']),
    author: asMap(wire['author']).isEmpty
        ? null
        : ReviewAuthor.fromWire(wire['author']),
    revision: asString(wire['revision']),
    reviewed: parseTime(wire['reviewed']),
  );

  final String? id;
  final String status;
  final DateTime? time;
  final ReviewAuthor? author;
  final String? revision;
  final DateTime? reviewed;

  bool get isClose => status == 'closed';
}

/// A conversation about the change, or about one place in it.
class ReviewThread {
  const ReviewThread({
    required this.id,
    required this.status,
    this.comments = const [],
    this.history = const [],
    this.meta = const {},
  });

  factory ReviewThread.fromWire(JsonMap wire) => ReviewThread(
    id: asStringOr(wire['id'], ''),
    status: asStringOr(wire['status'], 'open'),
    comments: [
      for (final comment in asMapList(wire['comments']))
        ReviewComment.fromWire(comment),
    ],
    history: [
      for (final entry in asMapList(wire['history']))
        ReviewHistoryEntry.fromWire(entry),
    ],
    meta: asMap(wire['meta']),
  );

  final String id;
  final String status;
  final List<ReviewComment> comments;
  final List<ReviewHistoryEntry> history;
  final JsonMap meta;

  bool get isOpen => status == 'open';
  bool get isClosed => !isOpen;

  ReviewComment? get root => comments.isEmpty ? null : comments.first;
  ReviewComment? get last => comments.isEmpty ? null : comments.last;

  /// The change of status that closed the thread, when it is closed.
  ReviewHistoryEntry? get closing {
    for (final entry in history.reversed) {
      if (entry.isClose) return entry;
    }
    return null;
  }

  /// The user closed the thread, so nothing waits to be looked at.
  bool get closedByUser => closing?.author?.isUser ?? false;

  /// Closed by someone else, and the user has not marked that close
  /// reviewed: the harness's "to review" (`change-review-thread-unreviewed-p`).
  bool get toReview {
    if (isOpen) return false;
    final entry = closing;
    if (entry == null) return false;
    final author = entry.author;
    if (author == null || author.isUser) return false;
    return entry.reviewed == null;
  }

  /// A thread nothing was sent in: only the user's drafts (`draft`).
  bool get isDraftsOnly =>
      comments.isNotEmpty && comments.every((comment) => comment.isDraft);

  /// Where the thread is: the first place any of its comments names,
  /// preferring the root's.
  ReviewLocation? get location {
    final first = root?.location;
    if (first != null) return first;
    for (final comment in comments) {
      final found = comment.location;
      if (found != null) return found;
    }
    return null;
  }

  /// The revision the thread was started against: the root's, else the
  /// first comment's that names one.
  String? get revision {
    final fromRoot = root?.revision;
    if (fromRoot != null) return fromRoot;
    for (final comment in comments) {
      final found = comment.revision;
      if (found != null) return found;
    }
    return null;
  }

  /// The file the thread is on, or null for the change as a whole.
  String? get file => location?.file;

  /// The users and agents in the conversation, in order of appearance.
  List<ReviewAuthor> get participants {
    final seen = <String>[];
    final authors = <ReviewAuthor>[];
    for (final comment in comments) {
      final key =
          '${comment.author.kind}/${comment.author.name ?? comment.author.label}';
      if (seen.contains(key)) continue;
      seen.add(key);
      authors.add(comment.author);
    }
    return authors;
  }

  /// The first words of what the thread raises, one line.
  String get excerpt {
    final root = this.root;
    if (root == null) return '';
    final text = root.answerText.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 90 ? text : '${text.substring(0, 89)}…';
  }

  int get drafted => comments.where((comment) => comment.isDraft).length;
  int get sent => comments.where((comment) => !comment.isDraft).length;

  /// The comment [id] names, or null.
  ReviewComment? comment(String? id) {
    if (id == null) return null;
    for (final comment in comments) {
      if (comment.id == id) return comment;
    }
    return null;
  }

  ReviewThread withComments(List<ReviewComment> comments) => ReviewThread(
    id: id,
    status: status,
    comments: comments,
    history: history,
    meta: meta,
  );
}

/// One version of a change: a hand-in of a branch.
class ReviewVersion {
  const ReviewVersion({
    required this.id,
    this.number,
    this.label,
    this.time,
    this.author,
    this.title,
    this.description,
    this.base,
    this.tip,
    this.meta = const {},
  });

  factory ReviewVersion.fromWire(JsonMap wire) => ReviewVersion(
    id: asStringOr(wire['id'], ''),
    number: asInt(wire['number']),
    label: asString(wire['label']),
    time: parseTime(wire['time']),
    author: asMap(wire['author']).isEmpty
        ? null
        : ReviewAuthor.fromWire(wire['author']),
    title: asString(wire['title']),
    description: asString(wire['description']),
    base: asString(wire['base']),
    tip: asString(wire['tip']),
    meta: asMap(wire['meta']),
  );

  final String id;
  final int? number;
  final String? label;
  final DateTime? time;
  final ReviewAuthor? author;
  final String? title;
  final String? description;

  /// The commit the version was made from, and the one it ends at.
  final String? base;
  final String? tip;
  final JsonMap meta;

  String get name {
    final given = label;
    if (given != null && given.isNotEmpty) return given;
    return 'v${number ?? 1}';
  }

  String get shortRevision => shortRevisionOf(id);
}

/// The first seven characters of a commit.
String shortRevisionOf(String? revision) {
  final value = revision ?? '';
  if (value.length <= 7) return value;
  return value.substring(0, 7);
}

/// The change under review, as `patch-review/get` returns it.
class ReviewSet {
  const ReviewSet({
    required this.id,
    this.title,
    this.description,
    this.versions = const [],
    this.threads = const [],
  });

  factory ReviewSet.fromWire(JsonMap wire) => ReviewSet(
    id: asStringOr(wire['id'], ''),
    title: asString(wire['title']),
    description: asString(wire['description']),
    versions: [
      for (final version in asMapList(wire['versions']))
        ReviewVersion.fromWire(version),
    ],
    threads: [
      for (final thread in asMapList(wire['threads']))
        ReviewThread.fromWire(thread),
    ],
  );

  final String id;
  final String? title;
  final String? description;
  final List<ReviewVersion> versions;
  final List<ReviewThread> threads;

  ReviewVersion? get latestVersion => versions.isEmpty ? null : versions.last;

  ReviewSet withThreads(List<ReviewThread> threads) => ReviewSet(
    id: id,
    title: title,
    description: description,
    versions: versions,
    threads: threads,
  );

  ReviewThread? thread(String id) {
    for (final thread in threads) {
      if (thread.id == id) return thread;
    }
    return null;
  }

  /// The comments written but not sent, in the order they were written.
  List<ReviewComment> get drafts => [
    for (final thread in threads)
      for (final comment in thread.comments)
        if (comment.isDraft) comment,
  ];

  /// The drafts with words: a blank draft is no reply.
  List<ReviewComment> get sendableDrafts => [
    for (final comment in drafts)
      if (comment.body.trim().isNotEmpty) comment,
  ];

  /// The threads a file's review shows: those placed on it, after the
  /// change or before it, and a rename's old path too.
  List<ReviewThread> threadsForFile(String path, {String? oldPath}) => [
    for (final thread in threads)
      if (_threadOnFile(thread, path, oldPath)) thread,
  ];

  bool _threadOnFile(ReviewThread thread, String path, String? oldPath) {
    final location = thread.location;
    if (location == null) return false;
    return location.file == path ||
        (oldPath != null && location.file == oldPath) ||
        (location.oldFile != null && location.oldFile == path);
  }

  /// The threads on the change as a whole.
  List<ReviewThread> get wholeChange => [
    for (final thread in threads)
      if (thread.location == null) thread,
  ];

  int get openThreads => threads.where((thread) => thread.isOpen).length;
  int get toReview => threads.where((thread) => thread.toReview).length;
  int get draftedComments => drafts.length;
}

/// One file a version changes.
class ChangedFile {
  const ChangedFile({
    required this.path,
    this.oldPath,
    this.status = 'M',
    this.added,
    this.deleted,
    this.binary = false,
    this.oldBlob,
    this.newBlob,
  });

  factory ChangedFile.fromWire(JsonMap wire) => ChangedFile(
    path: asStringOr(wire['path'], ''),
    oldPath: asString(wire['old-path'] ?? wire['oldPath']),
    status: asStringOr(wire['status'], 'M'),
    added: asInt(wire['added']),
    deleted: asInt(wire['deleted']),
    binary: asBool(wire['binary']),
    oldBlob: asString(wire['old-blob'] ?? wire['oldBlob']),
    newBlob: asString(wire['new-blob'] ?? wire['newBlob']),
  );

  final String path;
  final String? oldPath;

  /// Git's letter: A added, D deleted, M modified, R renamed, C copied,
  /// T type changed.
  final String status;
  final int? added;
  final int? deleted;
  final bool binary;
  final String? oldBlob;
  final String? newBlob;

  bool get isRename => status == 'R' && oldPath != null && oldPath!.isNotEmpty;
  bool get isDeleted => status == 'D';
  bool get isAdded => status == 'A';

  String get name {
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  String get directory {
    final parts = path.split('/');
    if (parts.length <= 1) return '';
    return parts.sublist(0, parts.length - 1).join('/');
  }

  /// The status as a word: `Added`, `Deleted`, `Renamed` and the rest.
  String get statusLabel => switch (status) {
    'A' => 'Added',
    'D' => 'Deleted',
    'M' => 'Modified',
    'R' => 'Renamed',
    'C' => 'Copied',
    'T' => 'Type changed',
    _ => 'Changed',
  };

  String get statusLetter => status.isEmpty ? 'M' : status;

  /// What the reviewed version's view needs to mark this file viewed: its
  /// path and the blob it has there (none for a file the change deletes).
  Map<String, Object?> get viewedEntry => {
    'path': path,
    if (newBlob != null && newBlob!.isNotEmpty) 'blob': newBlob,
  };

  String get countsLabel {
    if (binary) return 'binary';
    final add = added ?? 0;
    final del = deleted ?? 0;
    return '+$add −$del';
  }
}

/// The files a version changes, with the revision they are read at.
class ReviewChanges {
  const ReviewChanges({
    required this.taskId,
    required this.revision,
    this.base,
    this.versionId,
    this.label,
    this.branch,
    this.files = const [],
  });

  factory ReviewChanges.fromWire(JsonMap wire) => ReviewChanges(
    taskId: asStringOr(wire['task-id'] ?? wire['taskId'], ''),
    revision: asStringOr(wire['revision'], ''),
    base: asString(wire['base']),
    versionId: asString(wire['version']),
    label: asString(wire['label']),
    branch: asString(wire['branch']),
    files: [
      for (final file in asMapList(wire['files'])) ChangedFile.fromWire(file),
    ],
  );

  final String taskId;

  /// The commit the files are read at: what a comment made here records.
  final String revision;
  final String? base;
  final String? versionId;
  final String? label;
  final String? branch;
  final List<ChangedFile> files;

  ChangedFile? file(String path) {
    for (final file in files) {
      if (file.path == path || file.oldPath == path) return file;
    }
    return null;
  }

  int get additions =>
      files.fold<int>(0, (total, file) => total + (file.added ?? 0));
  int get deletions =>
      files.fold<int>(0, (total, file) => total + (file.deleted ?? 0));

  String get revisionLabel => shortRevisionOf(revision);

  String get summaryLabel {
    final count = files.length;
    final what = count == 1 ? '1 file' : '$count files';
    return '$what · +$additions −$deletions';
  }
}

/// One file's diff, as `patch-review/diff` returns it.
class ReviewFileDiff {
  const ReviewFileDiff({
    required this.path,
    this.oldPath,
    this.status = 'M',
    this.added,
    this.deleted,
    this.binary = false,
    this.patch,
    this.revision,
    this.base,
    this.versionId,
    this.label,
    this.hunks = const [],
    this.oldTop,
    this.newTop,
  });

  factory ReviewFileDiff.fromWire(JsonMap wire, {ParsedPatch? parsed}) {
    final patch = asString(wire['patch']);
    final parse = parsed ?? parseUnifiedPatch(patch ?? '');
    return ReviewFileDiff(
      path: asStringOr(wire['path'], ''),
      oldPath: asString(wire['old-path'] ?? wire['oldPath']),
      status: asStringOr(wire['status'], 'M'),
      added: asInt(wire['added']),
      deleted: asInt(wire['deleted']),
      binary: asBool(wire['binary']),
      patch: patch,
      revision: asString(wire['revision']),
      base: asString(wire['base']),
      versionId: asString(wire['version']),
      label: asString(wire['label']),
      hunks: parse.hunks,
      oldTop: parse.oldPath,
      newTop: parse.newPath,
    );
  }

  final String path;
  final String? oldPath;
  final String status;
  final int? added;
  final int? deleted;
  final bool binary;
  final String? patch;
  final String? revision;
  final String? base;
  final String? versionId;
  final String? label;
  final List<DiffHunk> hunks;
  final String? oldTop;
  final String? newTop;

  bool get isEmpty => hunks.isEmpty;

  /// Every line of every hunk, in the order the file reads.
  Iterable<DiffLine> get lines => hunks.expand((hunk) => hunk.lines);

  /// The number of a line's counterpart on the other side, when it has one.
  int? lineNumber(DiffLine line) =>
      line.kind == DiffLineKind.deleted ? line.oldLine : line.newLine;
}

enum DiffLineKind { context, added, deleted, marker }

/// One line of a hunk, with its line numbers on both sides of the change.
class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final DiffLineKind kind;

  /// The line's text, without its leading `+`, `-` or space.
  final String text;

  /// The line's number in the file before the change, and after it.  A line
  /// added has no old number, one deleted no new number, and the marker of a
  /// file without a final newline has neither.
  final int? oldLine;
  final int? newLine;

  bool get isContext => kind == DiffLineKind.context;
  bool get isAdded => kind == DiffLineKind.added;
  bool get isDeleted => kind == DiffLineKind.deleted;

  /// The character the diff writes before the line: " ", "+", "-" or "\\".
  String get prefix => switch (kind) {
    DiffLineKind.context => ' ',
    DiffLineKind.added => '+',
    DiffLineKind.deleted => '-',
    DiffLineKind.marker => r'\',
  };

  /// What a comment records as the line's part of the diff.
  String get excerptLine => kind == DiffLineKind.marker
      ? r'\ No newline at end of file'
      : '$prefix$text';

  /// The number the line has on [side], or null where it has none.
  int? numberOn(String side) => side == 'old' ? oldLine : newLine;

  /// A screen reader's name for the line, saying what it is before its text:
  /// an addition, a deletion or a line of context.
  String semanticsLabel(int index) {
    final number = newLine ?? oldLine;
    final where = number == null ? '' : ' $number';
    final what = switch (kind) {
      DiffLineKind.added => 'Added line$where',
      DiffLineKind.deleted => 'Deleted line$where',
      DiffLineKind.marker => 'End of file marker',
      DiffLineKind.context => 'Line$where',
    };
    return '$what: $text';
  }
}

/// One hunk of a unified diff.
class DiffHunk {
  const DiffHunk({
    required this.index,
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    this.section = '',
    this.lines = const [],
  });

  final int index;
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final String section;
  final List<DiffLine> lines;

  /// The header as a diff writes it, such as `@@ -1,4 +1,6 @@`.
  String get header =>
      '@@ -$oldStart,$oldCount +$newStart,$newCount @@'
      '${section.isEmpty ? '' : ' $section'}';

  int get additions => lines.where((line) => line.isAdded).length;
  int get deletions => lines.where((line) => line.isDeleted).length;

  /// The line [number] on [side] belongs to this hunk, or null when it is
  /// not here.
  bool contains(String side, int number) {
    if (side == 'old') {
      return oldStart <= number && number < oldStart + oldCount;
    }
    return newStart <= number && number < newStart + newCount;
  }
}

/// A unified diff cut into its hunks.
class ParsedPatch {
  const ParsedPatch({
    this.oldPath,
    this.newPath,
    this.hunks = const [],
    this.binary = false,
  });

  final String? oldPath;
  final String? newPath;
  final List<DiffHunk> hunks;
  final bool binary;

  bool get isBinary => binary;
  bool get isEmpty => hunks.isEmpty;
}

final _hunkHeader = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$',
);

/// Cut the unified diff [patch] into its hunks and number every line.
///
/// The parser reads what `git diff` writes for one file: its `diff --git`
/// and `---`/`+++` lines, its hunk headers, and its lines of context,
/// additions, deletions and the marker of a file without a final newline.
/// A patch that says the file is binary has no hunks.  It never throws on
/// text a server sends: lines it does not understand are left out of the
/// hunks.
ParsedPatch parseUnifiedPatch(String patch) {
  if (patch.trim().isEmpty) return const ParsedPatch();
  final lines = patch.split('\n');
  String? oldTop;
  String? newTop;
  var binary = false;
  final hunks = <DiffHunk>[];
  List<DiffLine>? current;
  int oldNumber = 0;
  int newNumber = 0;
  DiffHunk? building;
  var index = 0;

  void finish() {
    final hunk = building;
    final body = current;
    if (hunk != null && body != null) {
      hunks.add(
        DiffHunk(
          index: hunk.index,
          oldStart: hunk.oldStart,
          oldCount: hunk.oldCount,
          newStart: hunk.newStart,
          newCount: hunk.newCount,
          section: hunk.section,
          lines: List.unmodifiable(body),
        ),
      );
    }
    building = null;
    current = null;
  }

  for (final raw in lines) {
    if (raw.isEmpty && current == null) continue;
    if (raw.startsWith('diff --git ')) {
      finish();
      final match = RegExp(r'^diff --git a/(.*) b/(.*)$').firstMatch(raw);
      if (match != null) {
        oldTop = match.group(1);
        newTop = match.group(2);
      }
      continue;
    }
    if (raw.startsWith('Binary files ') || raw.startsWith('GIT binary patch')) {
      binary = true;
      finish();
      continue;
    }
    if (current == null) {
      if (raw.startsWith('--- ')) {
        oldTop = _pathOf(raw.substring(4));
        continue;
      }
      if (raw.startsWith('+++ ')) {
        newTop = _pathOf(raw.substring(4));
        continue;
      }
    }
    final header = _hunkHeader.firstMatch(raw);
    if (header != null) {
      finish();
      oldNumber = int.tryParse(header.group(1) ?? '') ?? 0;
      newNumber = int.tryParse(header.group(3) ?? '') ?? 0;
      building = DiffHunk(
        index: index++,
        oldStart: oldNumber,
        oldCount: int.tryParse(header.group(2) ?? '') ?? 1,
        newStart: newNumber,
        newCount: int.tryParse(header.group(4) ?? '') ?? 1,
        section: (header.group(5) ?? '').trim(),
      );
      current = <DiffLine>[];
      continue;
    }
    if (current == null) continue;
    if (raw.startsWith(r'\')) {
      current!.add(
        DiffLine(
          kind: DiffLineKind.marker,
          text: raw.length > 1 ? raw.substring(1) : '',
        ),
      );
      continue;
    }
    if (raw.startsWith('+')) {
      current!.add(
        DiffLine(
          kind: DiffLineKind.added,
          text: raw.substring(1),
          newLine: newNumber++,
        ),
      );
    } else if (raw.startsWith('-')) {
      current!.add(
        DiffLine(
          kind: DiffLineKind.deleted,
          text: raw.substring(1),
          oldLine: oldNumber++,
        ),
      );
    } else if (raw.startsWith(' ')) {
      current!.add(
        DiffLine(
          kind: DiffLineKind.context,
          text: raw.substring(1),
          oldLine: oldNumber++,
          newLine: newNumber++,
        ),
      );
    } else if (raw.isEmpty) {
      // A patch whose last newline was cut: the last context line may be
      // empty, which `split` cannot tell from the end of the string.
      continue;
    }
  }
  finish();
  // `---`/`+++` of a file that deletes or creates it name no path.
  return ParsedPatch(
    oldPath: oldTop,
    newPath: newTop,
    hunks: List.unmodifiable(hunks),
    binary: binary,
  );
}

String? _pathOf(String value) {
  var path = value.trim();
  final tab = path.indexOf('\t');
  if (tab >= 0) path = path.substring(0, tab);
  if (path == '/dev/null') return null;
  if (path.startsWith('a/') || path.startsWith('b/')) {
    path = path.substring(2);
  }
  if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
    path = path.substring(1, path.length - 1);
  }
  return path.isEmpty ? null : path;
}

/// The hunk of [side]'s line [number], or null.
DiffHunk? hunkForLine(ReviewFileDiff diff, String side, int number) {
  for (final hunk in diff.hunks) {
    if (hunk.contains(side, number)) return hunk;
  }
  return null;
}

/// The excerpt a comment on the range [start]..[end] of [side] records:
/// the hunk header, then its lines through the end of the range, the last
/// line being the line (or the last line of the range) the comment is on.
///
/// It is the part of the diff the comment was about, kept with the comment,
/// so that a change to the file later does not make it read as a comment on
/// code that is no longer there.  Null when the diff has no such line.
String? excerptFor(
  ReviewFileDiff diff, {
  required String side,
  required int start,
  int? end,
}) {
  final last = end ?? start;
  final hunk = hunkForLine(diff, side, last);
  if (hunk == null) return null;
  final out = <String>[hunk.header];
  for (final line in hunk.lines) {
    out.add(line.excerptLine);
    final number = line.numberOn(side);
    if (number != null && number >= last) break;
  }
  return out.join('\n');
}

/// The added and deleted lines of [diff] as two columns, for a split view.
class SplitHunk {
  SplitHunk(this.hunk, this.rows);
  final DiffHunk hunk;
  final List<SplitRow> rows;
}

/// One row of a split hunk: a line of the old file beside a line of the new.
class SplitRow {
  const SplitRow(this.oldLine, this.newLine);

  /// The line before the change, and after it; one of them may be null.
  final DiffLine? oldLine;
  final DiffLine? newLine;

  bool get isAddition => oldLine == null && newLine != null;
  bool get isDeletion => oldLine != null && newLine == null;
  bool get isContext => oldLine != null && newLine != null;
}

/// Pair the deleted and added lines of every hunk into rows.
///
/// A run of deletions is put beside the run of additions that replaces it,
/// line for line, and the longer of the two runs keeps its extra rows on
/// its own side.  Context lines sit in both columns.
List<SplitHunk> splitHunks(List<DiffHunk> hunks) {
  final out = <SplitHunk>[];
  for (final hunk in hunks) {
    final rows = <SplitRow>[];
    var index = 0;
    final lines = hunk.lines;
    while (index < lines.length) {
      final line = lines[index];
      if (line.isContext) {
        rows.add(SplitRow(line, line));
        index++;
        continue;
      }
      if (line.kind == DiffLineKind.marker) {
        index++;
        continue;
      }
      final deleted = <DiffLine>[];
      final added = <DiffLine>[];
      while (index < lines.length &&
          (lines[index].isDeleted || lines[index].isAdded)) {
        final next = lines[index];
        if (next.isDeleted) {
          deleted.add(next);
        } else {
          added.add(next);
        }
        index++;
      }
      final count = deleted.length > added.length
          ? deleted.length
          : added.length;
      for (var i = 0; i < count; i++) {
        rows.add(
          SplitRow(
            i < deleted.length ? deleted[i] : null,
            i < added.length ? added[i] : null,
          ),
        );
      }
    }
    out.add(SplitHunk(hunk, List.unmodifiable(rows)));
  }
  return out;
}

/// One row of a file tree.
class ReviewTreeRow {
  const ReviewTreeRow({
    required this.name,
    required this.path,
    required this.depth,
    this.directory = false,
    this.expanded = false,
    this.file,
    this.added = 0,
    this.deleted = 0,
    this.files = 0,
  });

  final String name;
  final String path;
  final int depth;
  final bool directory;
  final bool expanded;
  final ChangedFile? file;
  final int added;
  final int deleted;
  final int files;

  String get key => '${directory ? 'd' : 'f'}:$path';
}

/// A directory of the change, with the files under it.
class ReviewTreeNode {
  ReviewTreeNode({required this.name, required this.path, this.file});

  final String name;
  final String path;
  ChangedFile? file;
  final List<ReviewTreeNode> children = [];

  bool get isDirectory => file == null;

  int get added => children.fold<int>(
    0,
    (total, node) => total + (node.file?.added ?? node.added),
  );
  int get deleted => children.fold<int>(
    0,
    (total, node) => total + (node.file?.deleted ?? node.deleted),
  );
  int get fileCount => children.fold<int>(
    0,
    (total, node) => total + (node.file == null ? node.fileCount : 1),
  );
}

/// Build the directory tree of [files], sorted by name with directories
/// first.
List<ReviewTreeNode> buildReviewTree(List<ChangedFile> files) {
  final root = ReviewTreeNode(name: '', path: '');
  for (final file in files) {
    final parts = file.path
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) continue;
    var parent = root;
    var path = '';
    for (var i = 0; i < parts.length; i++) {
      final name = parts[i];
      path = path.isEmpty ? name : '$path/$name';
      final isFile = i == parts.length - 1;
      ReviewTreeNode? child;
      for (final node in parent.children) {
        if (node.name == name && node.isDirectory == !isFile) {
          child = node;
          break;
        }
      }
      if (child == null) {
        child = ReviewTreeNode(
          name: name,
          path: path,
          file: isFile ? file : null,
        );
        parent.children.add(child);
      }
      parent = child;
    }
  }
  return _sorted(root.children);
}

List<ReviewTreeNode> _sorted(Iterable<ReviewTreeNode> nodes) {
  final list = nodes.toList()
    ..sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  for (final node in list) {
    if (node.isDirectory) {
      final sorted = _sorted(node.children);
      node.children
        ..clear()
        ..addAll(sorted);
    }
  }
  return list;
}

/// Flatten the tree into rows, leaving the contents of a directory in
/// [collapsed] out.  A directory path in [collapsed] is closed.
List<ReviewTreeRow> flattenReviewTree(
  List<ReviewTreeNode> nodes, {
  Set<String> collapsed = const {},
  int depth = 0,
}) {
  final rows = <ReviewTreeRow>[];
  for (final node in nodes) {
    final file = node.file;
    if (file != null) {
      rows.add(
        ReviewTreeRow(
          name: node.name,
          path: node.path,
          depth: depth,
          file: file,
          added: file.added ?? 0,
          deleted: file.deleted ?? 0,
          files: 1,
        ),
      );
    } else {
      final expanded = !collapsed.contains(node.path);
      rows.add(
        ReviewTreeRow(
          name: node.name,
          path: node.path,
          depth: depth,
          directory: true,
          expanded: expanded,
          added: node.added,
          deleted: node.deleted,
          files: node.fileCount,
        ),
      );
      if (expanded) {
        rows.addAll(
          flattenReviewTree(
            node.children,
            collapsed: collapsed,
            depth: depth + 1,
          ),
        );
      }
    }
  }
  return rows;
}

/// The threads of a review, filtered the way the harness's threads views
/// filter them.
enum ReviewThreadFilter { all, open, toReview, closed, drafts }

extension ReviewThreadFilterLabel on ReviewThreadFilter {
  /// The filter's name, as the chip says it.
  String get label => switch (this) {
    ReviewThreadFilter.all => 'All',
    ReviewThreadFilter.open => 'Open',
    ReviewThreadFilter.toReview => 'To review',
    ReviewThreadFilter.closed => 'Closed',
    ReviewThreadFilter.drafts => 'Drafts',
  };

  bool matches(ReviewThread thread, {bool hasDraft = false}) => switch (this) {
    ReviewThreadFilter.all => true,
    ReviewThreadFilter.open => thread.isOpen,
    ReviewThreadFilter.toReview => thread.toReview,
    ReviewThreadFilter.closed => thread.isClosed,
    ReviewThreadFilter.drafts => hasDraft,
  };
}

/// A file the reviewer marked viewed or approved: its path, and the blob it
/// has on the branch.  A file the branch changes again has another blob, so
/// the mark no longer covers it.
class ViewedFile {
  const ViewedFile({required this.path, this.blob});

  factory ViewedFile.fromWire(JsonMap wire) => ViewedFile(
    path: asStringOr(wire['path'], ''),
    blob: asString(wire['blob']),
  );

  final String path;
  final String? blob;

  bool covers(ChangedFile file) =>
      path == file.path && (blob ?? '') == (file.newBlob ?? '');
}

/// The files of a review that were viewed and approved (`patch-review/viewed`).
class ReviewViewed {
  const ReviewViewed({
    this.seen = const [],
    this.approved = const [],
    this.assumedAt,
    this.assumedRevision,
    this.assumedTip,
  });

  factory ReviewViewed.fromWire(JsonMap wire) {
    final assumed = asMap(wire['assumed']);
    return ReviewViewed(
      seen: [
        for (final file in asMapList(wire['seen'])) ViewedFile.fromWire(file),
      ],
      approved: [
        for (final file in asMapList(wire['approved']))
          ViewedFile.fromWire(file),
      ],
      assumedAt: parseTime(assumed['time']),
      assumedRevision: asString(assumed['revision']),
      assumedTip: asString(assumed['tip']),
    );
  }

  final List<ViewedFile> seen;
  final List<ViewedFile> approved;

  /// When files were taken as viewed without being looked at, and the
  /// commits that says: the harness's `V`, `patch-review/assume-viewed`.
  final DateTime? assumedAt;
  final String? assumedRevision;
  final String? assumedTip;

  bool get wasAssumed => assumedAt != null;

  bool isSeen(ChangedFile file) => seen.any((entry) => entry.covers(file));
  bool isApproved(ChangedFile file) =>
      approved.any((entry) => entry.covers(file));

  int get seenCount => seen.length;
  int get approvedCount => approved.length;

  ReviewViewed withFile(ChangedFile file, {bool? seen, bool? approved}) {
    final nextSeen = [
      for (final entry in this.seen)
        if (entry.path != file.path) entry,
    ];
    final nextApproved = [
      for (final entry in this.approved)
        if (entry.path != file.path) entry,
    ];
    final nowApproved = approved ?? isApproved(file);
    final nowSeen = seen ?? (isSeen(file) || nowApproved);
    if (nowSeen) {
      nextSeen.add(ViewedFile(path: file.path, blob: file.newBlob));
    }
    if (nowApproved) {
      nextApproved.add(ViewedFile(path: file.path, blob: file.newBlob));
    }
    return ReviewViewed(
      seen: nextSeen,
      approved: nextApproved,
      assumedAt: assumedAt,
      assumedRevision: assumedRevision,
      assumedTip: assumedTip,
    );
  }
}

/// What `patch-review/send-replies` did: how many replies went, and whether
/// the harness's last-close message went with them.
class ReviewSendResult {
  const ReviewSendResult({this.sent = 0, this.lastClose = false});

  factory ReviewSendResult.fromWire(JsonMap wire) => ReviewSendResult(
    sent: asInt(wire['sent']) ?? 0,
    lastClose: asBool(wire['last-close'] ?? wire['lastClose']),
  );

  final int sent;
  final bool lastClose;
}

/// The message that a task's last closed thread leaves for the user to send
/// (`patch-review/last-close`).
class ReviewLastClose {
  const ReviewLastClose({
    this.task,
    this.session,
    this.text = '',
    this.from,
    this.time,
  });

  factory ReviewLastClose.fromWire(JsonMap wire) => ReviewLastClose(
    task: asString(wire['task']),
    session: asString(wire['session']),
    text: asStringOr(wire['text'], ''),
    from: asMap(wire['from']).isEmpty
        ? null
        : ReviewAuthor.fromWire(wire['from']),
    time: parseTime(wire['time']),
  );

  final String? task;
  final String? session;
  final String text;
  final ReviewAuthor? from;
  final DateTime? time;

  bool get isEmpty => text.trim().isEmpty && task == null && session == null;
}
