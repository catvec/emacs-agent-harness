// The data of a task's review as the harness sends it: the diff parser and
// its line numbers, the files of a change and their tree, a thread's place,
// state and quote, and what a comment sends back.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/review.dart';

const _patch = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,4 +1,5 @@
 import 'b';
-old line
+new line
+added line
 same
 tail
@@ -20,3 +21,3 @@ class A
 ctx
-before
+after
 end
''';

void main() {
  group('a unified diff', () {
    test('is cut into its hunks with both line numbers', () {
      final parsed = parseUnifiedPatch(_patch);
      expect(parsed.hunks, hasLength(2));
      final first = parsed.hunks.first;
      expect(first.oldStart, 1);
      expect(first.oldCount, 4);
      expect(first.newStart, 1);
      expect(first.newCount, 5);
      expect(first.header, '@@ -1,4 +1,5 @@');
      expect(first.lines, hasLength(6));
      // Context, deletion, two additions, context, context.
      expect(
        first.lines.map((line) => line.prefix).toList(),
        [' ', '-', '+', '+', ' ', ' '],
      );
      expect(first.lines[0].oldLine, 1);
      expect(first.lines[0].newLine, 1);
      expect(first.lines[1].oldLine, 2);
      expect(first.lines[1].newLine, isNull);
      expect(first.lines[2].oldLine, isNull);
      expect(first.lines[2].newLine, 2);
      expect(first.lines[3].newLine, 3);
      expect(first.lines[4].oldLine, 3);
      expect(first.lines[4].newLine, 4);
      expect(first.lines[5].newLine, 5);

      final second = parsed.hunks[1];
      expect(second.section, 'class A');
      expect(second.oldStart, 20);
      expect(second.newStart, 21);
      expect(second.additions, 1);
      expect(second.deletions, 1);
      expect(second.contains('old', 21), isTrue);
      expect(second.contains('old', 23), isFalse);
      expect(second.contains('new', 22), isTrue);
    });

    test('keeps a file without a final newline marked', () {
      final parsed = parseUnifiedPatch('''
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1,1 +1,1 @@
-one
\\ No newline at end of file
+two
''');
      expect(parsed.hunks, hasLength(1));
      expect(parsed.hunks.first.lines, hasLength(3));
      expect(parsed.hunks.first.lines[1].kind, DiffLineKind.marker);
      expect(parsed.hunks.first.lines[1].oldLine, isNull);
      expect(parsed.hunks.first.lines[1].newLine, isNull);
    });

    test('reads a created and a deleted file, and a binary one', () {
      final created = parseUnifiedPatch('''
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+a
+b
''');
      expect(created.oldPath, isNull);
      expect(created.newPath, 'new.txt');
      expect(created.hunks.single.newStart, 1);
      final deleted = parseUnifiedPatch('''
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-gone
''');
      expect(deleted.oldPath, 'gone.txt');
      expect(deleted.newPath, isNull);
      final binary = parseUnifiedPatch('''
diff --git a/logo.png b/logo.png
index 111..222 100644
Binary files a/logo.png and b/logo.png differ
''');
      expect(binary.binary, isTrue);
      expect(binary.hunks, isEmpty);
    });

    test('is empty for an empty patch', () {
      final parsed = parseUnifiedPatch('');
      expect(parsed.hunks, isEmpty);
      expect(parsed.binary, isFalse);
    });

    test('a split view pairs deletions with additions', () {
      final rows = splitHunks(parseUnifiedPatch(_patch).hunks);
      expect(rows, hasLength(2));
      final first = rows.first.rows;
      // Context, the replaced line, the extra addition alone, two contexts.
      expect(first, hasLength(5));
      expect(first[0].isContext, isTrue);
      expect(first[1].isDeletion, isFalse);
      expect(first[1].oldLine?.text, 'old line');
      expect(first[1].newLine?.text, 'new line');
      expect(first[2].isAddition, isTrue);
      expect(first[2].newLine?.text, 'added line');
      expect(first[3].oldLine?.text, 'same');
    });

    test('an excerpt is the hunk through the commented line', () {
      final diff = ReviewFileDiff.fromWire({
        'path': 'lib/a.dart',
        'patch': _patch,
        'revision': 'abc1234',
      });
      final excerpt = excerptFor(diff, side: 'new', start: 2, end: 3);
      expect(excerpt, isNotNull);
      final lines = excerpt!.split('\n');
      expect(lines.first, '@@ -1,4 +1,5 @@');
      expect(lines.last, '+added line');
      expect(lines, contains('-old line'));
      // A line that is not in the diff has no excerpt.
      expect(excerptFor(diff, side: 'new', start: 99, end: 99), isNull);
    });

    test('a diff from the wire has its revision and hunks', () {
      final diff = ReviewFileDiff.fromWire({
        'path': 'lib/a.dart',
        'old-path': null,
        'status': 'M',
        'added': 3,
        'deleted': 2,
        'binary': false,
        'patch': _patch,
        'revision': 'deadbeefcafe',
        'base': 'cafebabe',
        'version': 'deadbeefcafe',
        'label': 'v2',
      });
      expect(diff.path, 'lib/a.dart');
      expect(diff.revision, 'deadbeefcafe');
      expect(diff.versionId, 'deadbeefcafe');
      expect(diff.label, 'v2');
      expect(diff.hunks, hasLength(2));
      expect(diff.isEmpty, isFalse);
      expect(diff.lines.where((line) => line.isAdded), hasLength(3));
      expect(diff.lines.where((line) => line.isDeleted), hasLength(2));
    });
  });

  group('the files of a change', () {
    final files = [
      const ChangedFile(path: 'README.md', status: 'M', added: 2, deleted: 1),
      const ChangedFile(path: 'lib/z/b.dart', status: 'A', added: 10),
      const ChangedFile(
        path: 'lib/a.dart',
        oldPath: 'lib/old.dart',
        status: 'R',
        added: 1,
        deleted: 1,
      ),
      const ChangedFile(path: 'assets/logo.png', status: 'M', binary: true),
    ];

    test('say their status, counts and rename', () {
      final changed = ReviewChanges.fromWire({
        'task-id': 't-1',
        'revision': 'abcdef1234',
        'base': '1234567890',
        'version': 'abcdef1234',
        'label': 'v1',
        'files': [
          for (final file in files)
            {
              'path': file.path,
              if (file.oldPath != null) 'old-path': file.oldPath,
              'status': file.status,
              if (file.added != null) 'added': file.added,
              if (file.deleted != null) 'deleted': file.deleted,
              if (file.binary) 'binary': true,
            },
        ],
      });
      expect(changed.revisionLabel, 'abcdef1');
      expect(changed.files, hasLength(4));
      expect(changed.additions, 13);
      expect(changed.deletions, 2);
      expect(changed.file('lib/old.dart')?.path, 'lib/a.dart');
      expect(changed.file('lib/a.dart')?.isRename, isTrue);
      expect(changed.files.last.binary, isTrue);
      expect(changed.files.last.statusLabel, 'Modified');
      expect(changed.files.last.countsLabel, 'binary');
    });

    test('are a tree with directories first and their counts summed', () {
      final tree = buildReviewTree(files);
      expect(tree.map((node) => node.name), ['assets', 'lib', 'README.md']);
      final lib = tree.firstWhere((node) => node.name == 'lib');
      expect(lib.isDirectory, isTrue);
      expect(lib.fileCount, 2);
      expect(lib.added, 11);
      final z = lib.children.firstWhere((node) => node.name == 'z');
      expect(z.isDirectory, isTrue);
      expect(lib.children.first.name, 'z');
      final rows = flattenReviewTree(tree);
      expect(
        rows.map((row) => row.name),
        ['assets', 'logo.png', 'lib', 'z', 'b.dart', 'a.dart', 'README.md'],
      );
      final collapsed = flattenReviewTree(tree, collapsed: {'lib', 'assets'});
      expect(
        collapsed.map((row) => row.name),
        ['assets', 'lib', 'README.md'],
      );
      expect(collapsed.first.directory, isTrue);
      expect(collapsed.first.expanded, isFalse);
    });
  });

  group('a thread', () {
    ReviewComment comment({
      String id = 'c-1',
      String body = 'Why this?',
      bool sent = true,
      String? revision = 'aaa1111',
      ReviewLocation? location,
      ReviewAuthor author = const ReviewAuthor(kind: 'user', name: 'Noah'),
    }) => ReviewComment(
      id: id,
      thread: 't-1',
      author: author,
      body: body,
      sent: sent ? DateTime(2026, 1, 1) : null,
      revision: revision,
      location: location,
    );

    ReviewThread thread({
      String status = 'open',
      String? revision = 'aaa1111',
      ReviewLocation? location = const ReviewLocation(
        file: 'lib/a.dart',
        line: 12,
      ),
      List<ReviewComment> comments = const [],
      List<ReviewHistoryEntry> history = const [],
    }) => ReviewThread(
      id: 't-1',
      status: status,
      comments: comments.isEmpty ? [comment(location: location)] : comments,
      history: history,
      meta: const {},
    );

    test('is to review when someone else closed it and nobody looked', () {
      final open = thread(comments: [comment()]);
      expect(open.isOpen, isTrue);
      expect(open.toReview, isFalse);
      final closedByUser = thread(
        status: 'closed',
        comments: [comment()],
        history: [
          ReviewHistoryEntry(
            id: 's-1',
            status: 'closed',
            author: const ReviewAuthor(kind: 'user', name: 'Noah'),
          ),
        ],
      );
      expect(closedByUser.toReview, isFalse);
      final closedByAgent = thread(
        status: 'closed',
        comments: [comment()],
        history: [
          ReviewHistoryEntry(
            id: 's-2',
            status: 'closed',
            author: const ReviewAuthor(kind: 'agent', name: 'Agent'),
          ),
        ],
      );
      expect(closedByAgent.toReview, isTrue);
      final reviewed = thread(
        status: 'closed',
        comments: [comment()],
        history: [
          ReviewHistoryEntry(
            id: 's-3',
            status: 'closed',
            author: const ReviewAuthor(kind: 'agent', name: 'Agent'),
            reviewed: DateTime(2026, 1, 2),
          ),
        ],
      );
      expect(reviewed.toReview, isFalse);
    });

    test('finds its place, revision, files and filters', () {
      final withPlace = thread(
        comments: [
          comment(
            location: const ReviewLocation(file: 'lib/a.dart', line: 12),
          ),
        ],
      );
      expect(withPlace.location?.line, 12);
      expect(withPlace.revision, 'aaa1111');
      expect(withPlace.file, 'lib/a.dart');
      expect(withPlace.excerpt, 'Why this?');
      final set = ReviewSet(
        id: 't-1',
        threads: [
          withPlace,
          thread(
            comments: [
              comment(
                id: 'c-2',
                location: const ReviewLocation(file: 'lib/a.dart', line: 20),
              ),
            ],
          ),
          thread(
            status: 'closed',
            comments: [comment(id: 'c-3')],
            history: [
              ReviewHistoryEntry(
                id: 's-1',
                status: 'closed',
                author: const ReviewAuthor(kind: 'agent'),
              ),
            ],
          ),
        ],
      );
      expect(set.threadsForFile('lib/a.dart'), hasLength(2));
      expect(set.threadsForFile('lib/other.dart'), isEmpty);
      expect(set.wholeChange, hasLength(1));
      expect(set.openThreads, 2);
      expect(set.toReview, 1);
      expect(
        set.threads
            .where((t) => ReviewThreadFilter.open.matches(t, hasDraft: true))
            .length,
        2,
      );
      expect(
        set.threads
            .where(
              (t) => ReviewThreadFilter.toReview.matches(t, hasDraft: true),
            )
            .length,
        1,
      );
    });

    test('names its drafts and quotes them', () {
      final draft = comment(id: 'c-9', body: 'A draft', sent: false);
      final t = thread(comments: [comment(), draft]);
      expect(t.isDraftsOnly, isFalse);
      expect(t.drafted, 1);
      expect(t.sent, 1);
      final quote = draft.quoteMarkdown;
      expect(quote, startsWith('> Noah:'));
      expect(quote, contains('> A draft'));
      expect(
        const ReviewAuthor(kind: 'agent', name: 'DeepSeek').label,
        'DeepSeek',
      );
      expect(
        const ReviewAuthor(kind: 'agent', session: 's-1').label,
        'Agent',
      );
    });

    test('sends only what a comment needs; the harness fills the rest', () {
      final draft = comment(
        id: 'c-5',
        body: 'A note',
        sent: false,
        location: const ReviewLocation(
          file: 'lib/a.dart',
          side: 'old',
          line: 4,
          endLine: 5,
          excerpt: '@@ -1,4 +1,4 @@\n ctx\n-before\n+after',
        ),
      );
      final wire = draft.toWire();
      expect(wire['id'], 'c-5');
      expect(wire['body'], 'A note');
      expect(wire['revision'], 'aaa1111');
      expect(wire['author'], isA<Map<String, Object?>>());
      expect(wire['sent'], isNull);
      final location = wire['location'] as Map<String, Object?>;
      expect(location['file'], 'lib/a.dart');
      expect(location['side'], 'old');
      expect(location['line'], 4);
      expect(location['end-line'], 5);
      expect(location['excerpt'], contains('@@'));
      expect(
        const ReviewLocation(file: 'x', line: 3, endLine: 3).label,
        'x:3',
      );
      expect(
        const ReviewLocation(file: 'x', line: 3, endLine: 5).label,
        'x:3–5',
      );
      expect(const ReviewLocation(file: 'x').label, 'x');
    });
  });
}
