/// Which project a directory belongs to.
///
/// A project is a main checkout.  The git worktrees the harness makes for
/// its tasks and sub-agents are not projects of their own: what happens in
/// one belongs to the checkout it was made from, as the harness's own views
/// have it (`insights/projects`, the `main` of a usage row, the session list
/// in Emacs).  Nor is a scratch directory an agent works in, in the
/// temporary directory the harness gives each session: its work is its
/// session's.  A session, a task or a usage row names the directory it ran
/// in, which for that work is a worktree or a scratch directory, so
/// everything that lists or matches projects folds the directory through
/// [ProjectRoots.of] first.
library;

/// The directory inside a project that holds the worktrees the harness
/// makes for it: `PROJECT/.worktrees/BRANCH`.
const worktreeDirectory = '.worktrees';

/// Where the harness made worktrees before it made them in
/// [worktreeDirectory]: `NAME-worktrees/BRANCH`, beside the project NAME.
/// Group 1 is the name of the project.
final _besideLayout = RegExp(r'/([^/]+)-worktrees/[^/]+/');

/// The temporary directory of a session, `harness-UID/ID` in the
/// directory temporary files go to, and what is in it.  The ID is the
/// session's, a UUID, or `id-` and a hash of an id that is no plain name:
/// a directory that is only called `harness-2` is none.
final _scratchLayout = RegExp(
  r'/harness-[0-9]+/'
  r'(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  r'|id-[0-9a-f]{32})/',
);

/// [path] as a directory name: trimmed, ending in a slash, which is how the
/// harness names a directory.  Empty for no directory.
String projectDirectory(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  return trimmed.endsWith('/') ? trimmed : '$trimmed/';
}

/// The project a directory in the harness's own worktree layouts
/// (`PROJECT/.worktrees/BRANCH`, or below it; `PROJECT-worktrees/BRANCH`
/// beside the project, as it made them first) belongs to, or null when the
/// path is not in one.  The outermost project when worktrees nest.  It needs
/// only the path, which is why it serves as the last resort: a worktree
/// somewhere else is the harness's to tell (see [ProjectRoots.resolved]).
String? worktreeOwner(String? path) {
  final dir = projectDirectory(path);
  // A `.worktrees` straight under the root of the disk has no project.
  final inside = dir.indexOf('/$worktreeDirectory/');
  final beside = _besideLayout.firstMatch(dir);
  if (inside > 0 && (beside == null || inside < beside.start)) {
    return dir.substring(0, inside + 1);
  }
  if (beside != null) {
    return '${dir.substring(0, beside.start + 1)}${beside.group(1)}/';
  }
  return null;
}

/// Whether [path] is a scratch directory: in the temporary directory of a
/// session, which is `harness-UID/ID` where temporary files go.  What an
/// agent makes there, a repository to try something in or the working
/// directory of a sub-agent, is no project of the user's.  The name is all
/// there is to go by; the harness says whose it is (see
/// [ProjectRoots.resolved]).
bool isScratchDirectory(String? path) =>
    _scratchLayout.hasMatch(projectDirectory(path));

/// What is known about how directories fold into projects.
class ProjectRoots {
  const ProjectRoots._(this.resolved);

  const ProjectRoots.empty() : resolved = const {};

  /// [resolved] is what the harness said of directories (`project/mains`):
  /// directory -> the main checkout its work counts for, or '' for none.
  factory ProjectRoots({Map<String, String> resolved = const {}}) =>
      ProjectRoots._({
        for (final entry in resolved.entries)
          if (projectDirectory(entry.key).isNotEmpty)
            projectDirectory(entry.key): projectDirectory(entry.value),
      });

  /// What the harness resolved on disk: directory -> its main checkout, or ''
  /// for a directory it says no project's work is in.
  final Map<String, String> resolved;

  /// The project [path] belongs to: its main checkout, as a directory name,
  /// or null when [path] is none, or the work in it counts for none.
  ///
  /// In order: what the harness said, when it named another checkout or none
  /// (a worktree, wherever it was made; a scratch directory, whose work is
  /// its session's); else what the path says, where the harness had no
  /// answer or took the directory for a checkout of its own, as one that is
  /// gone from disk, or a harness older than the answer, has it; else the
  /// directory itself.  A directory is never taken for a worktree because it
  /// lies inside another project: one project may well sit in another's
  /// tree (a home directory that is a repository and the projects below it).
  String? of(String? path) {
    final dir = projectDirectory(path);
    if (dir.isEmpty) return null;
    final said = resolved[dir];
    if (said != null && said != dir) return said.isEmpty ? null : said;
    if (isScratchDirectory(dir)) return null;
    return worktreeOwner(dir) ?? dir;
  }

  /// The projects of [paths]: each folded, once, sorted.
  List<String> projectsOf(Iterable<String?> paths) {
    final found = <String>{};
    for (final path in paths) {
      final project = of(path);
      if (project != null) found.add(project);
    }
    return found.toList()..sort();
  }
}
