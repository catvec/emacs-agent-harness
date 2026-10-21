/// Which project a directory belongs to.
///
/// A project is a main checkout.  The git worktrees the harness makes for
/// its tasks and sub-agents are not projects of their own: what happens in
/// one belongs to the checkout it was made from, as the harness's own views
/// have it (`insights/projects`, the `main` of a usage row, the session list
/// in Emacs).  A session, a task or a usage row names the directory it ran
/// in, which for that work is the worktree, so everything that lists or
/// matches projects folds the directory through [ProjectRoots.of] first.
library;

/// The directory inside a project that holds the worktrees the harness
/// makes for it: `PROJECT/.worktrees/BRANCH`.
const worktreeDirectory = '.worktrees';

/// [path] as a directory name: trimmed, ending in a slash, which is how the
/// harness names a directory.  Empty for no directory.
String projectDirectory(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  return trimmed.endsWith('/') ? trimmed : '$trimmed/';
}

/// The project a directory in the harness's own worktree layout
/// (`PROJECT/.worktrees/BRANCH`, or below it) belongs to, or null when the
/// path is not in that layout.  It needs only the path, which is why it
/// serves as the last resort: a worktree somewhere else is the harness's to
/// tell (see [ProjectRoots.resolved]).
String? worktreeOwner(String? path) {
  final dir = projectDirectory(path);
  final at = dir.indexOf('/$worktreeDirectory/');
  // A `.worktrees` straight under the root of the disk has no project.
  return at > 0 ? dir.substring(0, at + 1) : null;
}

/// What is known about how directories fold into projects.
class ProjectRoots {
  const ProjectRoots._(this.mains, this.resolved);

  const ProjectRoots.empty() : mains = const {}, resolved = const {};

  /// [mains] are the main checkouts the harness lists (`insights/projects`)
  /// and [resolved] directory -> main checkout answers it gave for
  /// directories (`project/mains`).
  factory ProjectRoots({
    Iterable<String> mains = const [],
    Map<String, String> resolved = const {},
  }) => ProjectRoots._(
    {
      for (final main in mains)
        if (projectDirectory(main).isNotEmpty) projectDirectory(main),
    },
    {
      for (final entry in resolved.entries)
        if (projectDirectory(entry.key).isNotEmpty &&
            projectDirectory(entry.value).isNotEmpty)
          projectDirectory(entry.key): projectDirectory(entry.value),
    },
  );

  /// The main checkouts the harness lists, as directory names.
  final Set<String> mains;

  /// What the harness resolved on disk: directory -> its main checkout.
  final Map<String, String> resolved;

  /// The project [path] belongs to: its main checkout, as a directory name,
  /// or null when [path] is none.
  ///
  /// In order: what the harness resolved for it, a main checkout it listed,
  /// the harness's worktree layout, else the directory itself.  A directory
  /// is never taken for a worktree because it lies inside another project:
  /// one project may well sit in another's tree (a home directory that is a
  /// repository and the projects below it).
  String? of(String? path) {
    final dir = projectDirectory(path);
    if (dir.isEmpty) return null;
    return resolved[dir] ??
        (mains.contains(dir) ? dir : (worktreeOwner(dir) ?? dir));
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
