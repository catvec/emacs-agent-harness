import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/project_roots.dart';
import 'package:harness_client/src/models/usage.dart';
import 'package:harness_client/src/ui/format.dart';

const _main = '/home/noah/code/harness/';
const _other = '/home/noah/code/other/';
const _session = '6f2c1a90-1111-4222-8333-444444444444';
const _scratch = '/tmp/harness-1000/$_session/q13b-1/';

void main() {
  group('a directory as a project directory', () {
    test('ends in a slash, as the harness names directories', () {
      expect(projectDirectory('/home/noah/code/harness'), _main);
      expect(projectDirectory(_main), _main);
      expect(projectDirectory('  /a/b  '), '/a/b/');
    });

    test('is empty for no directory', () {
      expect(projectDirectory(null), '');
      expect(projectDirectory(''), '');
      expect(projectDirectory('   '), '');
    });
  });

  group('the worktree of a project, by its path', () {
    test('is in the project\'s .worktrees', () {
      expect(worktreeOwner('$_main.worktrees/task-fix-titles/'), _main);
      expect(worktreeOwner('$_main.worktrees/task-fix-titles'), _main);
    });

    test('also below the worktree\'s top', () {
      expect(worktreeOwner('$_main.worktrees/task-fix-titles/lib/src/'), _main);
    });

    test('belongs to the outermost project when worktrees nest', () {
      expect(worktreeOwner('$_main.worktrees/task-a/.worktrees/sub-b/'), _main);
    });

    test('is beside the project, as the harness first made them', () {
      expect(
        worktreeOwner('/home/noah/code/harness-worktrees/task-old/'),
        _main,
      );
      expect(
        worktreeOwner('/home/noah/code/harness-worktrees/task-old'),
        _main,
      );
      expect(
        worktreeOwner('/home/noah/code/harness-worktrees/task-old/lib/'),
        _main,
      );
    });

    test('belongs to the outermost project when worktrees beside nest', () {
      // A task started in a worktree made its own worktrees beside that one.
      expect(
        worktreeOwner(
          '/home/noah/code/harness-worktrees/task-a-worktrees/task-b/',
        ),
        _main,
      );
      // And whichever layout is outermost wins when the two are mixed.
      expect(
        worktreeOwner(
          '/home/noah/code/harness-worktrees/task-a/.worktrees/harness-b/',
        ),
        _main,
      );
      expect(worktreeOwner('$_main.worktrees/task-a-worktrees/task-b/'), _main);
    });

    test('is none for a directory outside those layouts', () {
      expect(worktreeOwner(_main), isNull);
      expect(worktreeOwner('${_main}worktrees/task-a/'), isNull);
      expect(worktreeOwner('/home/noah/.worktrees-old/task-a/'), isNull);
      // The directory the worktrees are in is no worktree.
      expect(worktreeOwner('/home/noah/code/harness-worktrees/'), isNull);
      expect(worktreeOwner('/home/noah/code/-worktrees/task-a/'), isNull);
      expect(worktreeOwner(null), isNull);
      expect(worktreeOwner(''), isNull);
    });

    test('is none for a .worktrees at the root of the disk', () {
      expect(worktreeOwner('/.worktrees/task-a/'), isNull);
    });
  });

  group('a scratch directory', () {
    test('is in the temporary directory of a session', () {
      expect(isScratchDirectory(_scratch), isTrue);
      expect(isScratchDirectory('/tmp/harness-1000/$_session/q13b'), isTrue);
      expect(
        isScratchDirectory('/tmp/harness-1000/$_session/wt/core/'),
        isTrue,
      );
      // The directory of the session itself is where its scratch is.
      expect(isScratchDirectory('/tmp/harness-1000/$_session/'), isTrue);
      // Wherever temporary files go, for the user of any number.
      expect(
        isScratchDirectory('/var/folders/xy/T/harness-501/$_session/x/'),
        isTrue,
      );
      // An id that is no plain name is hashed, and the hash is the name.
      expect(
        isScratchDirectory(
          '/tmp/harness-1000/id-5d41402abc4b2a76b9719d911017c592/x/',
        ),
        isTrue,
      );
    });

    test('is not any other directory', () {
      expect(isScratchDirectory(_main), isFalse);
      expect(isScratchDirectory('/home/noah/code/harness/lib/'), isFalse);
      expect(isScratchDirectory('/tmp/harness-1000/'), isFalse);
      expect(isScratchDirectory('/tmp/harness-mine/$_session/x/'), isFalse);
      expect(isScratchDirectory('/tmp/xharness-1000/$_session/x/'), isFalse);
      // A directory that is merely called like the temporary directory of
      // the sessions, or like one of theirs, is not one.
      expect(isScratchDirectory('/home/noah/harness-2/notes/'), isFalse);
      expect(isScratchDirectory('/tmp/harness-1000/abc-123/x/'), isFalse);
      expect(isScratchDirectory(null), isFalse);
      expect(isScratchDirectory(''), isFalse);
    });
  });

  group('the project of a directory', () {
    test('is the directory itself when nothing says it is a worktree', () {
      const roots = ProjectRoots.empty();
      expect(roots.of(_main), _main);
      expect(roots.of('/home/noah/code/harness'), _main);
    });

    test('is none for no directory', () {
      const roots = ProjectRoots.empty();
      expect(roots.of(null), isNull);
      expect(roots.of(''), isNull);
    });

    test('is the checkout a worktree in the .worktrees layout is of', () {
      const roots = ProjectRoots.empty();
      expect(roots.of('$_main.worktrees/task-a/'), _main);
      expect(roots.of('$_other.worktrees/task-b/src/'), _other);
    });

    test('is the checkout a worktree beside it is of', () {
      const roots = ProjectRoots.empty();
      expect(roots.of('/home/noah/code/harness-worktrees/task-old/'), _main);
    });

    test('is none for a scratch directory', () {
      expect(const ProjectRoots.empty().of(_scratch), isNull);
    });

    test('is what the harness resolved, wherever the worktree is', () {
      final roots = ProjectRoots(
        resolved: {'/home/noah/code/elsewhere/task-old/': _main},
      );
      expect(roots.of('/home/noah/code/elsewhere/task-old/'), _main);
      // The names need no slash on either side.
      expect(roots.of('/home/noah/code/elsewhere/task-old'), _main);
    });

    test('is what the harness resolved before what the path says', () {
      final roots = ProjectRoots(
        resolved: {'$_main.worktrees/task-a/': _other},
      );
      expect(roots.of('$_main.worktrees/task-a/'), _other);
    });

    test('is the project of the session whose scratch directory it is', () {
      final roots = ProjectRoots(resolved: {_scratch: _main});
      expect(roots.of(_scratch), _main);
    });

    test('is none when the harness says no project\'s work is in it', () {
      final roots = ProjectRoots(
        resolved: {_scratch: '', '/home/noah/code/gone/': ''},
      );
      expect(roots.of(_scratch), isNull);
      expect(roots.of('/home/noah/code/gone'), isNull);
    });

    test('is what the path says when the harness took it for its own', () {
      // A harness that does not know the layouts answers every directory it
      // can find no worktree in with itself: a worktree gone from disk, and
      // a scratch directory.
      final beside = '/home/noah/code/harness-worktrees/task-old/';
      final roots = ProjectRoots(
        resolved: {beside: beside, _scratch: _scratch, _main: _main},
      );
      expect(roots.of(beside), _main);
      expect(roots.of(_scratch), isNull);
      expect(roots.of(_main), _main);
    });

    test('is never another project just because it lies inside it', () {
      // A home directory that is a repository, and the projects below it.
      final roots = ProjectRoots(
        resolved: {
          '/home/noah/': '/home/noah/',
          _main: _main,
          '/home/noah/code/scratch/': '/home/noah/code/scratch/',
        },
      );
      expect(roots.of(_main), _main);
      expect(roots.of('/home/noah/code/scratch/'), '/home/noah/code/scratch/');
      expect(roots.of('/home/noah/'), '/home/noah/');
      // Not knowing of the home directory either, nothing is folded into it.
      expect(
        const ProjectRoots.empty().of('/home/noah/code/x/'),
        '/home/noah/code/x/',
      );
    });

    test('lists the projects of directories, each once, sorted', () {
      const roots = ProjectRoots.empty();
      expect(
        roots.projectsOf([
          '$_main.worktrees/task-a/',
          _other,
          null,
          '',
          _main,
          '$_main.worktrees/task-b/',
          '/home/noah/code/harness-worktrees/task-old/',
        ]),
        [_main, _other],
      );
    });

    test('lists none for the directories no project\'s work is in', () {
      final roots = ProjectRoots(resolved: {'/tmp/odd/': ''});
      expect(
        roots.projectsOf([
          _scratch,
          '/tmp/odd/',
          '/tmp/harness-7/$_session/c/',
          _main,
        ]),
        [_main],
      );
    });
  });

  group('a project\'s name', () {
    test('is the last part of its directory', () {
      expect(projectName(_main), 'harness');
      expect(projectName('/home/noah/code/harness'), 'harness');
      expect(projectName('$_main.git/'), 'harness');
      expect(projectName(null), 'No project');
      expect(projectName(''), 'No project');
    });

    test('is its project\'s, for a worktree', () {
      expect(projectName('$_main.worktrees/task-fix-titles/'), 'harness');
      expect(projectName('$_main.worktrees/task-fix-titles/lib/'), 'harness');
      expect(
        projectName('/home/noah/code/harness-worktrees/task-old/'),
        'harness',
      );
    });
  });

  group('usage by project, folded', () {
    UsageAggregate row(
      String key, {
      String? main,
      double cost = 0,
      double listCost = 0,
      int input = 0,
      int calls = 0,
    }) => UsageAggregate(
      key: key,
      main: main,
      cost: cost,
      listCost: listCost,
      input: input,
      calls: calls,
    );

    test('adds the worktrees of a project to it, richest project first', () {
      final folded = foldProjectUsage([
        row(_other, main: _other, cost: 0.2, listCost: 0.3, input: 5, calls: 1),
        row(_main, main: _main, cost: 0.5, listCost: 0.6, input: 40, calls: 12),
        row(
          '$_main.worktrees/task-a/',
          main: _main,
          cost: 0.25,
          listCost: 0.5,
          input: 20,
          calls: 4,
        ),
        row(
          '$_main.worktrees/task-b/',
          main: _main,
          cost: 0.25,
          listCost: 0.5,
          input: 20,
          calls: 4,
        ),
      ], const ProjectRoots.empty());
      expect(folded.map((r) => r.key), [_main, _other]);
      expect(folded.map((r) => r.main), [_main, _other]);
      expect(folded.first.listCost, closeTo(1.6, 1e-9));
      expect(folded.first.cost, closeTo(1.0, 1e-9));
      expect(folded.first.input, 80);
      expect(folded.first.calls, 20);
      expect(folded.last.listCost, closeTo(0.3, 1e-9));
    });

    test('trusts the main checkout the harness gave a row', () {
      final folded = foldProjectUsage([
        row('/elsewhere/task-old/', main: _main, listCost: 1),
        row(_main, main: _main, listCost: 2),
      ], const ProjectRoots.empty());
      expect(folded, hasLength(1));
      expect(folded.single.key, _main);
      expect(folded.single.listCost, 3);
    });

    test('works the project out when the harness gave no main', () {
      final folded = foldProjectUsage([
        row('$_main.worktrees/task-a/', listCost: 1),
        row('/home/noah/code/harness-worktrees/task-old/', listCost: 4),
        row(_main, listCost: 2),
      ], const ProjectRoots.empty());
      expect(folded, hasLength(1));
      expect(folded.single.key, _main);
      expect(folded.single.listCost, 7);
    });

    test('counts a scratch directory for the project of its session', () {
      final folded = foldProjectUsage([
        row(_scratch, main: _main, listCost: 1),
        row(_main, main: _main, listCost: 2),
      ], const ProjectRoots.empty());
      expect(folded, hasLength(1));
      expect(folded.single.key, _main);
      expect(folded.single.listCost, 3);
    });

    test('keeps the usage that has no project apart', () {
      final folded = foldProjectUsage([
        row('', main: '', listCost: 1),
        row(_scratch, main: '', listCost: 3),
        row('/tmp/harness-1000/$_session/wt/core/', listCost: 4),
        row(_main, main: _main, listCost: 2),
      ], const ProjectRoots.empty());
      // One row for all that has none, a scratch directory's included.
      expect(folded.map((r) => r.key), ['', _main]);
      expect(folded.first.listCost, 8);
      expect(folded.first.main, isNull);
    });
  });
}
