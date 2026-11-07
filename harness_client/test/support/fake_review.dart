// A task's review as the harness keeps one, for the fake harness the client
// tests and screenshots talk to.
//
// The data is the shape `patch-review/get`, `-changes`, `-diff` and
// `-viewed` answer, with threads at two revisions, one closed by an agent and
// unseen, one closed by the user, a draft saved on the harness, a rename, a
// deletion, an addition, a binary file and enough changed files to scroll.
// The operations the app sends (`add-comment`, `set-status`, `mark-reviewed`,
// `edit-comment`, `delete-comment`) change it the way the real review does,
// so a test sees the comment it made come back, and the harness's own data
// stays the only place a comment lives.
import 'dart:math';

/// What a review's version calls itself.
const reviewTip = '9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b';
const reviewBase = '1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c';
const reviewEarlier = '0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c';

/// One task's review, as the fake harness holds it.
class FakeReview {
  FakeReview({this.taskId = 'task-2'}) {
    _seed();
  }

  final String taskId;

  /// The revision the changes are read at, and the version they are.  A test
  /// changes [revision] to show a newer hand-in under the old diff.
  String revision = reviewTip;
  String version = reviewTip;

  /// The files, patches and threads; [viewed] the marks.
  late List<Map<String, Object?>> files;
  late Map<String, String> patches;
  late List<Map<String, Object?>> threads;
  late List<Map<String, Object?>> seen;
  late List<Map<String, Object?>> approved;

  /// The message the harness leaves when the last open thread of a task at
  /// work is closed; null for none.
  Map<String, Object?>? lastClose;

  /// The operations the app applied, in order.
  final List<Map<String, Object?>> operations = [];

  /// How many times the replies were sent.
  int sends = 0;

  int _ids = 0;

  String _id(String prefix) {
    _ids++;
    return '$prefix-phone-$_ids';
  }

  double _ago(Duration duration) =>
      DateTime.now().subtract(duration).millisecondsSinceEpoch / 1000;

  Map<String, Object?> _author(String kind, String name) => {
    'kind': kind,
    'name': name,
    if (kind == 'agent') 'session': 's-agent',
  };

  Map<String, Object?> _place(
    String file,
    int line, {
    int? endLine,
    String side = 'new',
    String? oldFile,
  }) => {
    'file': file,
    if (oldFile != null) 'old-file': oldFile,
    'side': side,
    'line': line,
    if (endLine != null) 'end-line': endLine,
  };

  Map<String, Object?> _comment(
    String thread,
    String body, {
    required String author,
    required String name,
    String? id,
    String? replyTo,
    Map<String, Object?>? location,
    String? revision,
    double? sent,
  }) => {
    'id': id ?? _id('c'),
    'thread': thread,
    if (replyTo != null) 'reply-to': replyTo,
    'author': _author(author, name),
    'body': body,
    'time': sent,
    if (sent != null) 'sent': sent,
    if (location != null) 'location': location,
    if (revision != null) 'revision': revision,
  };

  Map<String, Object?> _thread(
    String id, {
    required String status,
    required List<Map<String, Object?>> comments,
    required List<Map<String, Object?>> history,
  }) => {'id': id, 'status': status, 'comments': comments, 'history': history};

  Map<String, Object?> _closed(
    String id, {
    required String by,
    required String name,
    required double time,
    double? reviewed,
  }) => {
    'id': id,
    'status': 'closed',
    'time': time,
    'author': _author(by, name),
    if (reviewed != null) 'reviewed': reviewed,
  };

  void _seed() {
    final longAnswer = [
      'The list is rebuilt whenever the controller says a task changed. That is once per event, and an event can carry every task of a project, so a board of forty tasks reads forty cards for one change.',
      '',
      'The fix is to keep the task objects and compare them before the whole list is made: a card whose task is the same object, and whose column and facts are the same, is not rebuilt.',
      '',
      'The hard part is the session: a session says the same task in another object, and the card listens to both. Comparing by identity would miss that, so the card takes the task id and the state it shows, and the list compares those.',
      '',
      'The tests in `task_board_test.dart` count builds, so a change that quietly rebuilds everything is caught before it reaches a phone.',
      '',
      'It is a small change, but it is the one the board has been asking for since the fourth task.',
    ].join('\n');
    final draftBody =
        'The hint text is 3.1:1 on the light surface; the guide asks for 4.5:1.';
    threads = [
      _thread(
        't-chat',
        status: 'open',
        comments: [
          _comment(
            't-chat',
            'The composer covers the last message once the keyboard opens. This is the third report of it.',
            author: 'user',
            name: 'Noah',
            id: 'c-chat-1',
            location: _place('lib/src/ui/chat_screen.dart', 42, endLine: 44),
            revision: reviewTip,
            sent: _ago(const Duration(hours: 2)),
          ),
          _comment(
            't-chat',
            'The inset is applied twice: once by the scaffold, once by the composer. It is one now.',
            author: 'agent',
            name: 'Agent',
            id: 'c-chat-2',
            replyTo: 'c-chat-1',
            sent: _ago(const Duration(hours: 1)),
          ),
        ],
        history: [
          {
            'id': 'h-chat-1',
            'status': 'open',
            'time': _ago(const Duration(hours: 2)),
            'author': _author('user', 'Noah'),
          },
        ],
      ),
      _thread(
        't-task',
        status: 'closed',
        comments: [
          _comment(
            't-task',
            'This re-reads every task on every event; it should be once a refresh.',
            author: 'user',
            name: 'Noah',
            id: 'c-task-1',
            location: _place(
              'lib/src/state/task_controller.dart',
              118,
              side: 'old',
            ),
            revision: reviewEarlier,
            sent: _ago(const Duration(hours: 5)),
          ),
          _comment(
            't-task',
            'Agreed. It is read once, at the start of a refresh, and the list is kept.',
            author: 'agent',
            name: 'Agent',
            id: 'c-task-2',
            replyTo: 'c-task-1',
            sent: _ago(const Duration(hours: 4)),
          ),
        ],
        history: [
          {
            'id': 'h-task-1',
            'status': 'open',
            'time': _ago(const Duration(hours: 5)),
            'author': _author('user', 'Noah'),
          },
          _closed(
            'h-task-2',
            by: 'agent',
            name: 'Agent',
            time: _ago(const Duration(hours: 4)),
          ),
        ],
      ),
      _thread(
        't-whole',
        status: 'open',
        comments: [
          _comment(
            't-whole',
            'The board still flashes when a task changes column. Worth a pass before this goes in?',
            author: 'user',
            name: 'Noah',
            id: 'c-whole-1',
            revision: reviewTip,
            sent: _ago(const Duration(minutes: 30)),
          ),
          _comment(
            't-whole',
            longAnswer,
            author: 'agent',
            name: 'Agent',
            id: 'c-whole-2',
            replyTo: 'c-whole-1',
            sent: _ago(const Duration(minutes: 20)),
          ),
        ],
        history: [
          {
            'id': 'h-whole-1',
            'status': 'open',
            'time': _ago(const Duration(minutes: 30)),
            'author': _author('user', 'Noah'),
          },
        ],
      ),
      _thread(
        't-theme',
        status: 'open',
        comments: [
          _comment(
            't-theme',
            draftBody,
            author: 'user',
            name: 'Noah',
            id: 'c-theme-draft',
            location: _place('lib/src/ui/theme.dart', 12),
            revision: reviewTip,
          ),
        ],
        history: const [],
      ),
      _thread(
        't-panel',
        status: 'closed',
        comments: [
          _comment(
            't-panel',
            'This panel is no longer reachable from the board.',
            author: 'user',
            name: 'Noah',
            id: 'c-panel-1',
            location: _place('lib/src/ui/old_panel.dart', 40, side: 'old'),
            revision: reviewTip,
            sent: _ago(const Duration(days: 1)),
          ),
        ],
        history: [
          {
            'id': 'h-panel-1',
            'status': 'open',
            'time': _ago(const Duration(days: 1)),
            'author': _author('user', 'Noah'),
          },
          _closed(
            'h-panel-2',
            by: 'user',
            name: 'Noah',
            time: _ago(const Duration(hours: 20)),
          ),
        ],
      ),
      _thread(
        't-long',
        status: 'open',
        comments: [
          _comment(
            't-long',
            'Does this still rebuild every frame?',
            author: 'user',
            name: 'Noah',
            id: 'c-long-1',
            location: _place('lib/src/ui/chat_screen.dart', 40),
            revision: reviewTip,
            sent: _ago(const Duration(hours: 3)),
          ),
          _comment(
            't-long',
            longAnswer,
            author: 'agent',
            name: 'Agent',
            id: 'c-long-2',
            replyTo: 'c-long-1',
            sent: _ago(const Duration(hours: 2)),
          ),
        ],
        history: [
          {
            'id': 'h-long-1',
            'status': 'open',
            'time': _ago(const Duration(hours: 3)),
            'author': _author('user', 'Noah'),
          },
        ],
      ),
    ];
    files = [
      _file('lib/src/ui/chat_screen.dart', 'M', 18, 7, 'blob-chat'),
      _file('lib/src/state/task_controller.dart', 'M', 9, 4, 'blob-task'),
      _file('lib/src/ui/theme.dart', 'M', 8, 0, 'blob-theme'),
      _file('lib/src/ui/new_panel.dart', 'A', 64, 0, 'blob-new-panel'),
      _file(
        'lib/src/ui/split_view.dart',
        'R',
        6,
        2,
        'blob-split',
        oldPath: 'lib/src/ui/old_view.dart',
      ),
      _file('lib/src/ui/old_panel.dart', 'D', 0, 52, null),
      _file('docs/logo.png', 'M', null, null, 'blob-logo', binary: true),
      _file(
        'lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart',
        'M',
        22,
        3,
        'blob-long-name',
      ),
      for (var i = 0; i < 26; i++)
        _file(
          'lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart',
          'M',
          4 + i,
          2,
          'blob-feature-$i',
        ),
    ];
    seen = [
      {'path': 'lib/src/ui/chat_screen.dart', 'blob': 'blob-chat'},
      {'path': 'lib/src/state/task_controller.dart', 'blob': 'blob-task'},
    ];
    approved = [
      {'path': 'lib/src/state/task_controller.dart', 'blob': 'blob-task'},
    ];
    patches = {
      'lib/src/ui/chat_screen.dart': '''
diff --git a/lib/src/ui/chat_screen.dart b/lib/src/ui/chat_screen.dart
index 1111111..2222222 100644
--- a/lib/src/ui/chat_screen.dart
+++ b/lib/src/ui/chat_screen.dart
@@ -36,9 +36,12 @@ class _ChatScreenState extends State<ChatScreen> {
   Widget build(BuildContext context) {
     return Scaffold(
-      body: Column(
-        children: [
-          Expanded(child: _Transcript(controller: _controller)),
-        ],
+      body: SafeArea(
+        bottom: false,
+        child: Column(
+          children: [
+            Expanded(child: _Transcript(controller: _controller)),
+            _Composer(controller: _controller),
+          ],
+        ),
       ),
     );
   }
@@ -78,4 +81,12 @@ class _ChatScreenState extends State<ChatScreen> {
   void _onKey() {
-    if (_keyboard.isOpen) setState(() {});
+    final open = _keyboard.isOpen;
+    if (open == _wasOpen) return;
+    setState(() {
+      _wasOpen = open;
+      _scrollToEnd();
+    });
   }
+
+  bool _wasOpen = false;
 }
''',
      'lib/src/state/task_controller.dart': '''
diff --git a/lib/src/state/task_controller.dart b/lib/src/state/task_controller.dart
index 3333333..4444444 100644
--- a/lib/src/state/task_controller.dart
+++ b/lib/src/state/task_controller.dart
@@ -116,6 +116,10 @@ class TaskController extends ChangeNotifier {
   void _onEvent(TaskEvent event) {
-    for (final task in event.tasks) {
-      _tasks[task.id] = task;
-    }
-    notifyListeners();
+    final changed = event.tasks
+        .where((task) => _tasks[task.id] != task)
+        .toList(growable: false);
+    if (changed.isEmpty) return;
+    for (final task in changed) {
+      _tasks[task.id] = task;
+    }
+    _scheduleNotify();
   }
''',
      'lib/src/ui/theme.dart': '''
diff --git a/lib/src/ui/theme.dart b/lib/src/ui/theme.dart
index 5555555..6666666 100644
--- a/lib/src/ui/theme.dart
+++ b/lib/src/ui/theme.dart
@@ -6,9 +6,15 @@ class HarnessTheme {
   static ThemeData light() {
     final scheme = ColorScheme.fromSeed(
-      seedColor: const Color(0xFF2F6F4F),
+      seedColor: const Color(0xFF1F5C40),
+      brightness: Brightness.light,
     );
     return ThemeData(
       colorScheme: scheme,
+      textTheme: _textTheme(Brightness.light),
+      hintColor: scheme.onSurfaceVariant,
+      cardTheme: _cards(scheme),
       useMaterial3: true,
     );
   }
''',
      'lib/src/ui/new_panel.dart': '''
diff --git a/lib/src/ui/new_panel.dart b/lib/src/ui/new_panel.dart
new file mode 100644
index 0000000..7777777
--- /dev/null
+++ b/lib/src/ui/new_panel.dart
@@ -0,0 +1,8 @@
+import 'package:flutter/material.dart';
+
+/// A panel of the board that holds the tasks of one project.
+class ProjectPanel extends StatelessWidget {
+  const ProjectPanel({super.key, required this.title});
+
+  final String title;
+}
''',
      'lib/src/ui/split_view.dart': '''
diff --git a/lib/src/ui/old_view.dart b/lib/src/ui/split_view.dart
similarity index 91%
rename from lib/src/ui/old_view.dart
rename to lib/src/ui/split_view.dart
index 8888888..9999999 100644
--- a/lib/src/ui/old_view.dart
+++ b/lib/src/ui/split_view.dart
@@ -12,7 +12,7 @@ class SplitView extends StatelessWidget {
   Widget build(BuildContext context) {
     return Row(
       children: [
-        Expanded(child: _left(context)),
+        Expanded(child: _left(context), flex: 2),
         Expanded(child: _right(context)),
       ],
     );
''',
      'lib/src/ui/old_panel.dart': '''
diff --git a/lib/src/ui/old_panel.dart b/lib/src/ui/old_panel.dart
deleted file mode 100644
index aaaaaaa..0000000
--- a/lib/src/ui/old_panel.dart
+++ /dev/null
@@ -36,10 +36,1 @@ class OldPanel extends StatelessWidget {
-  Widget build(BuildContext context) {
-    return Card(
-      child: Column(
-        children: const [
-          _Title(),
-          _Body(),
-        ],
-      ),
-    );
-  }
 }
''',
      'docs/logo.png': '',
      'lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart':
          '''
diff --git a/lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart b/lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart
index bbbbbbb..ccccccc 100644
--- a/lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart
+++ b/lib/src/ui/very_long_directory_name/that_keeps_going/a_widget_with_a_long_name.dart
@@ -18,3 +18,6 @@ class AWidgetWithALongName extends StatelessWidget {
   const AWidgetWithALongName({super.key});
+
+  /// The words the widget shows, kept short on a narrow screen.
+  static const label = 'A name that does not fit';
 
   @override
''',
      for (var i = 0; i < 26; i++)
        'lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart':
            '''
diff --git a/lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart b/lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart
index ddddddd..eeeeeee 100644
--- a/lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart
+++ b/lib/src/features/feature_${i.toString().padLeft(2, '0')}/widget.dart
@@ -1,1 +1,3 @@
+// A small widget of feature ${i.toString().padLeft(2, '0')}.
+
 class Feature$i extends StatelessWidget {
''',
    };
    lastClose = null;
  }

  Map<String, Object?> _file(
    String path,
    String status,
    int? added,
    int? deleted,
    String? blob, {
    String? oldPath,
    bool binary = false,
  }) => {
    'path': path,
    if (oldPath != null) 'old-path': oldPath,
    'status': status,
    'added': added,
    'deleted': deleted,
    'binary': binary,
    if (blob != null) 'new-blob': blob,
    if (status != 'A' && blob != null) 'old-blob': 'old-$blob',
  };

  // ---- The methods ------------------------------------------------------

  Map<String, Object?> get set => {
    'id': taskId,
    'title': 'Review the emulator screenshots',
    'description': 'Check every flow and screenshot on both device sizes.',
    'versions': [
      {
        'id': reviewEarlier,
        'number': 1,
        'label': 'v1',
        'time': _ago(const Duration(hours: 6)),
        'author': _author('agent', 'Agent'),
        'base': reviewBase,
        'tip': reviewEarlier,
      },
      {
        'id': reviewTip,
        'number': 2,
        'label': 'v2',
        'time': _ago(const Duration(hours: 1)),
        'author': _author('agent', 'Agent'),
        'base': reviewBase,
        'tip': reviewTip,
      },
    ],
    'threads': threads,
  };

  /// Whether [requested] names the earlier version the review keeps.
  bool _earlier(String? requested) =>
      requested == reviewEarlier || requested == 'v-1';

  /// The files of the earlier version: it still has `removed_panel.dart`,
  /// which the newest version dropped, and not `new_panel.dart`, which the
  /// newest added.  The file a comment of the earlier version is on is
  /// there, with the lines that comment was written at.
  List<Map<String, Object?>> get earlierFiles => [
    _file('lib/src/state/task_controller.dart', 'M', 120, 6, 'blob-task-v1'),
    _file('lib/src/ui/chat_screen.dart', 'M', 18, 7, 'blob-chat-v1'),
    _file('lib/src/ui/removed_panel.dart', 'A', 3, 0, 'blob-removed'),
    _file('lib/src/ui/old_panel.dart', 'M', 4, 2, 'blob-old-v1'),
  ];

  Map<String, Object?> changesFor(String? requested) {
    final earlier = _earlier(requested);
    if (requested != null &&
        !earlier &&
        requested != version &&
        requested != revision) {
      throw StateError('The review has no version $requested');
    }
    return {
      'task-id': taskId,
      'revision': earlier ? reviewEarlier : revision,
      'base': reviewBase,
      'version': earlier ? reviewEarlier : version,
      'label': earlier ? 'v1' : 'v2',
      'branch': 'task/screenshots',
      'files': earlier ? earlierFiles : files,
    };
  }

  Map<String, Object?> get changes => changesFor(null);

  Map<String, Object?> get viewed => {'seen': seen, 'approved': approved};

  Map<String, Object?>? diff(String path, {String? version}) {
    final earlier = _earlier(version);
    final known = earlier ? earlierFiles : files;
    Map<String, Object?>? file;
    for (final one in known) {
      if (one['path'] == path || one['old-path'] == path) file = one;
    }
    if (file == null) return null;
    final patch = earlier
        ? _earlierPatch(file['path'] as String)
        : patches[file['path']] ?? '';
    return {
      'path': file['path'],
      if (file['old-path'] != null) 'old-path': file['old-path'],
      'status': file['status'],
      'added': file['added'],
      'deleted': file['deleted'],
      'binary': file['binary'],
      'patch': patch,
      'revision': earlier ? reviewEarlier : revision,
      'base': reviewBase,
      'version': earlier ? reviewEarlier : version,
      'label': earlier ? 'v1' : 'v2',
      'branch': 'task/screenshots',
    };
  }

  String _earlierPatch(String path) => switch (path) {
    'lib/src/state/task_controller.dart' => '''
diff --git a/lib/src/state/task_controller.dart b/lib/src/state/task_controller.dart
--- a/lib/src/state/task_controller.dart
+++ b/lib/src/state/task_controller.dart
@@ -116,6 +116,6 @@ class TaskController extends ChangeNotifier {
   void _onEvent(TaskEvent event) {
-    for (final task in event.tasks) {
-      _tasks[task.id] = task;
+    for (final task in event.tasks) { // one pass
+      _tasks[task.id] = task;
     }
     notifyListeners();
   }
''',
    'lib/src/ui/removed_panel.dart' => '''
diff --git a/lib/src/ui/removed_panel.dart b/lib/src/ui/removed_panel.dart
new file mode 100644
--- /dev/null
+++ b/lib/src/ui/removed_panel.dart
@@ -0,0 +1,3 @@
+class RemovedPanel {
+  const RemovedPanel();
+}
''',
    _ => '',
  };

  /// What one operation of `patch-review/apply` does here.
  Map<String, Object?> apply(Map<String, Object?> params) {
    operations.add(params);
    final op = params['op'];
    switch (op) {
      case 'add-comment':
        _addComment(params);
        break;
      case 'edit-comment':
        final id = params['comment'];
        for (final thread in threads) {
          for (final comment in _comments(thread)) {
            if (comment['id'] == id) comment['body'] = params['body'];
          }
        }
        break;
      case 'delete-comment':
        final id = params['comment'];
        for (final thread in threads) {
          _comments(thread).removeWhere((comment) => comment['id'] == id);
        }
        threads.removeWhere((thread) => _comments(thread).isEmpty);
        break;
      case 'set-status':
        final id = params['thread'];
        for (final thread in threads) {
          if (thread['id'] != id) continue;
          final status = '${params['status'] ?? 'closed'}';
          thread['status'] = status;
          final history = _history(thread);
          history.add({
            'id': _id('h'),
            'status': status,
            'time': _ago(Duration.zero),
            'author': _author('user', 'Noah'),
          });
          if (status == 'closed') {
            lastClose = {
              'task': taskId,
              'text': 'Closed: this point is done.',
              'from': _author('user', 'Noah'),
              'time': _ago(Duration.zero),
            };
          }
        }
        break;
      case 'mark-reviewed' || 'unmark-reviewed':
        final closing = params['status-id'];
        for (final thread in threads) {
          for (final entry in _history(thread)) {
            if (closing != null && entry['id'] != closing) continue;
            if (entry['status'] != 'closed') continue;
            entry['reviewed'] = op == 'mark-reviewed'
                ? _ago(Duration.zero)
                : null;
          }
        }
        break;
      case 'assume-viewed':
        seen = [
          for (final file in files)
            if (file['new-blob'] != null)
              {'path': file['path'], 'blob': file['new-blob']},
        ];
        break;
      default:
        return {'changed': false};
    }
    return {'changed': true};
  }

  void _addComment(Map<String, Object?> params) {
    final wire = Map<String, Object?>.from(
      params['comment'] as Map? ?? const <String, Object?>{},
    );
    wire['author'] = _author('user', 'Noah');
    wire['time'] = _ago(Duration.zero);
    wire['revision'] ??= revision;
    // An operation names what it adds by id: performing one twice adds
    // nothing the second time, even when the first made its thread.
    for (final known in threads) {
      if (_comments(known).any((comment) => comment['id'] == wire['id'])) {
        return;
      }
    }
    final threadId = params['thread'] ?? wire['thread'];
    Map<String, Object?>? thread;
    if (threadId != null) {
      for (final known in threads) {
        if (known['id'] == threadId) thread = known;
      }
    }
    if (thread == null) {
      thread = _thread(
        _id('t'),
        status: 'open',
        comments: <Map<String, Object?>>[],
        history: <Map<String, Object?>>[],
      );
      threads.add(thread);
    }
    wire['thread'] = thread['id'];
    _comments(thread).add(wire);
  }

  /// The replies of `patch-review/send-replies`: every draft is delivered.
  Map<String, Object?> sendReplies() {
    sends++;
    var sent = 0;
    for (final thread in threads) {
      for (final comment in _comments(thread)) {
        if (comment['sent'] == null) {
          comment['sent'] = _ago(Duration.zero);
          sent++;
        }
      }
    }
    final close = lastClose != null;
    lastClose = null;
    return {'sent': sent, 'last-close': close};
  }

  /// The files of a diff so large no phone should render it at once: one
  /// hunk with [lines] added lines, for a performance test.
  static String largePatch({int lines = 4000}) {
    final buffer = StringBuffer()
      ..writeln(
        'diff --git a/lib/src/generated/catalog.dart b/lib/src/generated/catalog.dart',
      )
      ..writeln('--- a/lib/src/generated/catalog.dart')
      ..writeln('+++ b/lib/src/generated/catalog.dart')
      ..writeln('@@ -1,1 +1,${lines + 1} @@')
      ..writeln(' // Generated. Do not edit.');
    for (var i = 0; i < lines; i++) {
      buffer.writeln("+const title$i = 'A title, number $i';");
    }
    return buffer.toString();
  }

  /// A patch whose lines are as wide as a terminal: the phone must scroll or
  /// wrap it, never clip it without a way to read it.
  static String widePatch() {
    final line =
        'const configurationKeyForTheVeryLongName = '
        "'a value that runs past the edge of any phone screen and keeps going "
        "for another eighty characters to be sure';";
    return [
      'diff --git a/lib/src/wide.dart b/lib/src/wide.dart',
      '--- a/lib/src/wide.dart',
      '+++ b/lib/src/wide.dart',
      '@@ -1,2 +1,4 @@',
      ' class Wide {',
      '+$line',
      '+$line',
      ' }',
    ].join('\n');
  }

  List<Map<String, Object?>> _comments(Map<String, Object?> thread) =>
      (thread['comments'] as List).cast<Map<String, Object?>>();

  List<Map<String, Object?>> _history(Map<String, Object?> thread) =>
      (thread['history'] as List).cast<Map<String, Object?>>();

  /// A random but stable id, for a test that needs many.
  static String idFor(int n) => 'c-${Random(n).nextInt(1 << 32)}';
}
