import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/project_roots.dart';
import 'package:harness_client/src/models/usage.dart';
import 'package:harness_client/src/ui/format.dart';

const _main = '/home/noah/code/harness/';
const _other = '/home/noah/code/other/';

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

    test('is none for a directory outside that layout', () {
      expect(worktreeOwner(_main), isNull);
      expect(worktreeOwner('${_main}worktrees/task-a/'), isNull);
      expect(worktreeOwner('/home/noah/.worktrees-old/task-a/'), isNull);
      expect(worktreeOwner(null), isNull);
      expect(worktreeOwner(''), isNull);
    });

    test('is none for a .worktrees at the root of the disk', () {
      expect(worktreeOwner('/.worktrees/task-a/'), isNull);
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
      final roots = ProjectRoots(mains: [_main, _other]);
      expect(roots.of('$_main.worktrees/task-a/'), _main);
      expect(roots.of('$_other.worktrees/task-b/src/'), _other);
    });

    test('is the checkout even when the harness listed no project', () {
      expect(const ProjectRoots.empty().of('$_main.worktrees/task-a/'), _main);
    });

    test('is what the harness resolved, wherever the worktree is', () {
      final roots = ProjectRoots(
        mains: [_main],
        resolved: {'/home/noah/code/harness-worktrees/task-old/': _main},
      );
      expect(roots.of('/home/noah/code/harness-worktrees/task-old/'), _main);
      // The names need no slash on either side.
      expect(roots.of('/home/noah/code/harness-worktrees/task-old'), _main);
    });

    test('is what the harness resolved before what the path says', () {
      final roots = ProjectRoots(
        resolved: {'$_main.worktrees/task-a/': _other},
      );
      expect(roots.of('$_main.worktrees/task-a/'), _other);
    });

    test('is a main checkout the harness listed, as it is', () {
      final roots = ProjectRoots(mains: ['/home/noah/code/.worktrees/odd/']);
      expect(
        roots.of('/home/noah/code/.worktrees/odd/'),
        '/home/noah/code/.worktrees/odd/',
      );
    });

    test('is never another project just because it lies inside it', () {
      // A home directory that is a repository, and the projects below it.
      final roots = ProjectRoots(mains: ['/home/noah/', _main, _other]);
      expect(roots.of(_main), _main);
      expect(roots.of('/home/noah/code/scratch/'), '/home/noah/code/scratch/');
      expect(roots.of('/home/noah/'), '/home/noah/');
    });

    test('lists the projects of directories, each once, sorted', () {
      final roots = ProjectRoots(mains: [_main, _other]);
      expect(
        roots.projectsOf([
          '$_main.worktrees/task-a/',
          _other,
          null,
          '',
          _main,
          '$_main.worktrees/task-b/',
        ]),
        [_main, _other],
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
        row(_main, listCost: 2),
      ], ProjectRoots(mains: [_main]));
      expect(folded, hasLength(1));
      expect(folded.single.key, _main);
      expect(folded.single.listCost, 3);
    });

    test('keeps the usage that has no project apart', () {
      final folded = foldProjectUsage([
        row('', main: '', listCost: 1),
        row(_main, main: _main, listCost: 2),
      ], const ProjectRoots.empty());
      expect(folded.map((r) => r.key), [_main, '']);
      expect(folded.last.main, isNull);
    });
  });
}
