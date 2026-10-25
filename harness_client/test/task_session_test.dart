// A task is handled in the conversation of its session, so the app has to
// know which task a session is the session of, whatever the board shows: a
// board narrowed to another project does not list the task, and a task the
// board has not heard of yet still has its conversation open.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/state/task_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _other = '/Users/noah/Code/other-project/';

Future<(AppController, FakeHarness)> _connected({
  void Function(FakeHarness harness)? arrange,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness()..seedOtherProjectTasks();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  // The board loads on its own once the app is connected.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (app.tasks!.tasks.isEmpty) {
    if (DateTime.now().isAfter(deadline)) fail('The board did not load.');
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
  return (app, harness);
}

/// How many times the harness was asked which task a session is of.
int _asked(FakeHarness harness) => harness.requests
    .where((request) => request.$1 == '_harness/task/for-session')
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the task of a session', () {
    test('is the board\'s task that works in it', () async {
      final (app, _) = await _connected();
      final board = app.tasks!;
      // "Build the Flutter ACP client" works in s3, "Answer the permission"
      // in s2; the other sessions are no task's.
      expect(board.forSession('s3')?.id, 'task-1');
      expect(board.forSession('s2')?.id, 'task-4');
      expect(board.forSession('s1'), isNull);
      expect(board.forSession(''), isNull);
      expect(board.forSession(null), isNull);
    });

    test(
      'is still known when the board is narrowed to another project',
      () async {
        final (app, _) = await _connected();
        final board = app.tasks!;
        await board.load(project: _other);
        expect({for (final task in board.tasks) task.id}, {'task-7', 'task-8'});
        // The board has no place for it, its conversation does.
        expect(board.forSession('s3')?.id, 'task-1');
        expect(board.forSession('s2')?.id, 'task-4');
      },
    );

    test(
      'follows the harness\'s events for a task the board does not list',
      () async {
        final (app, harness) = await _connected();
        final board = app.tasks!;
        await board.load(project: _other);
        var heard = 0;
        board.addListener(() => heard++);
        expect(board.forSession('s3')?.isActive, isTrue);

        board.applyEvent('task/changed', [
          {...harness.tasks['task-1']!, 'state': 'review', 'column': 'review'},
        ]);

        expect(board.forSession('s3')?.isReview, isTrue);
        expect(
          {for (final task in board.tasks) task.id},
          {'task-7', 'task-8'},
          reason: 'the board stays the other project\'s',
        );
        expect(heard, greaterThan(0), reason: 'its conversation is told');
      },
    );

    test('is forgotten with the task', () async {
      final (app, _) = await _connected();
      final board = app.tasks!;
      expect(board.forSession('s3'), isNotNull);
      board.applyEvent('task/deleted', ['task-1']);
      expect(board.forSession('s3'), isNull);
    });

    test(
      'is asked of the harness when the board has not heard of it',
      () async {
        final (app, harness) = await _connected();
        // A board that has not loaded, as one is before its first answer.
        final board = TaskController(app.api!);
        expect(board.forSession('s3'), isNull);
        var heard = 0;
        board.addListener(() => heard++);

        await board.lookUp('s3');

        expect(board.forSession('s3')?.id, 'task-1');
        expect(heard, 1);
        expect(_asked(harness), 1);
      },
    );

    test('is asked once, and a session that is no task\'s stays so', () async {
      final (app, harness) = await _connected();
      final board = TaskController(app.api!);
      await board.lookUp('s1');
      await board.lookUp('s1');
      expect(board.forSession('s1'), isNull);
      expect(_asked(harness), 1);
    });

    test('is not asked of the board that has it', () async {
      final (app, harness) = await _connected();
      await app.tasks!.lookUp('s3');
      expect(_asked(harness), 0);
    });

    test('is not asked of a harness that cannot say', () async {
      final (app, harness) = await _connected(
        arrange: (harness) => harness.methods.remove('task/for-session'),
      );
      final board = TaskController(app.api!);
      await board.lookUp('s3');
      expect(board.forSession('s3'), isNull);
      expect(_asked(harness), 0);
    });
  });
}
