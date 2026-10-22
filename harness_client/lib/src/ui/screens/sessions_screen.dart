import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/session.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/quota_widgets.dart';

enum _SessionFilter { all, active, needsYou }

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    required this.app,
    required this.onOpenSession,
    this.embedded = false,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;
  final bool embedded;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  _SessionFilter _filter = _SessionFilter.all;
  String? _project;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<SessionSummary> get _visible {
    final app = widget.app;
    final query = _search.text.trim().toLowerCase();
    final out = <SessionSummary>[];
    for (final session in app.sessions) {
      final live = app.summaryFor(session.id) ?? session;
      // A session in a git worktree is in the project the worktree is of.
      if (_project != null && app.projectOfSession(live) != _project) continue;
      switch (_filter) {
        case _SessionFilter.active:
          if (!live.isActive) continue;
        case _SessionFilter.needsYou:
          if (!app.needsAttention(live.id) && !live.isBlocked) continue;
        case _SessionFilter.all:
          break;
      }
      if (query.isNotEmpty) {
        final haystack = [
          live.displayTitle,
          live.project ?? '',
          live.cwd ?? '',
          live.model ?? '',
          live.kind ?? '',
          statusLabel(live.status),
        ].join(' ').toLowerCase();
        if (!haystack.contains(query)) continue;
      }
      out.add(live);
    }
    out.sort((a, b) {
      final attentionA = widget.app.needsAttention(a.id) || a.isBlocked;
      final attentionB = widget.app.needsAttention(b.id) || b.isBlocked;
      if (attentionA != attentionB) return attentionA ? -1 : 1;
      return (b.touchedAt?.millisecondsSinceEpoch ?? 0).compareTo(
        a.touchedAt?.millisecondsSinceEpoch ?? 0,
      );
    });
    return out;
  }

  Future<void> _refresh() => widget.app.refreshSessions();

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final sessions = _visible;
    // The project is said once, in the scope bar: a row names its project
    // only where there is more than one to tell apart.
    final showProject = _project == null && app.projects.length != 1;
    final body = Column(
      children: [
        _Toolbar(
          app: app,
          search: _search,
          focus: _searchFocus,
          filter: _filter,
          project: _project,
          onFilter: (filter) => setState(() => _filter = filter),
          onProject: (project) => setState(() => _project = project),
          onChanged: () => setState(() {}),
        ),
        Expanded(
          child: _SessionList(
            app: app,
            sessions: sessions,
            showProject: showProject,
            onOpen: widget.onOpenSession,
            onRefresh: _refresh,
            onNew: () => _newSession(context),
            filtered:
                _search.text.trim().isNotEmpty ||
                _filter != _SessionFilter.all ||
                _project != null,
          ),
        ),
      ],
    );
    final newButton = HarnessIconButton(
      icon: adaptiveIcon(context, Icons.add_rounded, CupertinoIcons.add),
      label: 'New session',
      onPressed: () => _newSession(context),
    );
    final refreshButton = HarnessIconButton(
      icon: adaptiveIcon(
        context,
        Icons.refresh_rounded,
        CupertinoIcons.arrow_clockwise,
      ),
      label: 'Refresh sessions',
      onPressed: _refresh,
    );
    if (widget.embedded) {
      return Container(
        color: HarnessStyle.isCupertino(context)
            ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
            : Theme.of(context).colorScheme.surface,
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              // The header of this pane: the title, how many, the actions.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HarnessSpace.gutter,
                  HarnessSpace.md,
                  HarnessSpace.sm,
                  0,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            'Sessions',
                            style: HarnessText.pageTitle(context),
                          ),
                          const SizedBox(width: HarnessSpace.sm),
                          Text(
                            '${app.sessions.length}',
                            style: HarnessText.meta(context),
                          ),
                        ],
                      ),
                    ),
                    refreshButton,
                    newButton,
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }
    return HarnessPage(
      title: 'Sessions',
      actions: [refreshButton, newButton],
      // The first section of the list is the sessions that need an answer.
      attentionNotice: false,
      body: body,
    );
  }

  Future<void> _newSession(BuildContext context) async {
    final app = widget.app;
    final created = await showHarnessSheet<String>(
      context: context,
      builder: (sheetContext) => _NewSessionSheet(app: app),
    );
    if (created != null && mounted) {
      widget.onOpenSession(created);
    }
  }
}

/// What narrows the list, top to bottom: the project, the search, the way
/// to look at it.  Each is full width and starts on the gutter.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.app,
    required this.search,
    required this.focus,
    required this.filter,
    required this.project,
    required this.onFilter,
    required this.onProject,
    required this.onChanged,
  });

  final AppController app;
  final TextEditingController search;
  final FocusNode focus;
  final _SessionFilter filter;
  final String? project;
  final ValueChanged<_SessionFilter> onFilter;
  final ValueChanged<String?> onProject;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attention = app.sessions
        .where((s) => app.needsAttention(s.id))
        .length;
    final active = app.sessions.where((s) => s.isActive).length;
    // A project to choose is only worth a line where there is a choice.
    final scoped = app.projects.length > 1 || project != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scoped)
          HarnessScopeBar(
            label: project == null ? 'All projects' : projectName(project),
            onTap: () async {
              final choice = await showHarnessMenu<String>(
                context: context,
                title: 'Projects',
                items: [
                  const HarnessMenuItem(value: '', label: 'All projects'),
                  for (final item in app.projects)
                    HarnessMenuItem(
                      value: item,
                      label: projectName(item),
                      icon: Icons.folder_outlined,
                    ),
                ],
              );
              if (choice != null) {
                onProject(choice.isEmpty ? null : choice);
              }
            },
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            HarnessSpace.gutter,
            scoped ? 0 : HarnessSpace.sm,
            HarnessSpace.gutter,
            HarnessSpace.sm,
          ),
          child: HarnessTextField(
            key: const Key('session-search'),
            controller: search,
            focusNode: focus,
            hint: 'Search conversations',
            textInputAction: TextInputAction.search,
            onChanged: (_) => onChanged(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 9,
            ),
            prefix: Icon(
              Icons.search_rounded,
              size: 19,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            suffix: search.text.isEmpty
                ? null
                : HarnessIconButton(
                    icon: Icons.close_rounded,
                    label: 'Clear search',
                    size: 17,
                    onPressed: () {
                      search.clear();
                      onChanged();
                    },
                  ),
          ),
        ),
        HarnessTabStrip<_SessionFilter>(
          value: filter,
          onChanged: onFilter,
          tabs: [
            HarnessTab(
              value: _SessionFilter.all,
              label: 'All',
              count: app.sessions.length,
            ),
            HarnessTab(
              value: _SessionFilter.active,
              label: 'Active',
              count: active,
            ),
            HarnessTab(
              value: _SessionFilter.needsYou,
              label: 'Needs you',
              count: attention,
              color: attention > 0 ? HarnessColors.amber : null,
            ),
          ],
        ),
        if (app.capability?.isHarness != true)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.md,
              HarnessSpace.gutter,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.cable_rounded,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: HarnessSpace.sm),
                Expanded(
                  child: Text(
                    'Standard ACP agent · the task board and usage views are '
                    'hidden.',
                    style: HarnessText.caption(context),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({
    required this.app,
    required this.sessions,
    required this.showProject,
    required this.onOpen,
    required this.onRefresh,
    required this.onNew,
    required this.filtered,
  });

  final AppController app;
  final List<SessionSummary> sessions;
  final bool showProject;
  final ValueChanged<String> onOpen;
  final Future<void> Function() onRefresh;
  final VoidCallback onNew;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return HarnessEmptyState(
        icon: filtered
            ? Icons.filter_alt_off_rounded
            : adaptiveIcon(
                context,
                Icons.forum_outlined,
                CupertinoIcons.chat_bubble_2,
              ),
        title: filtered ? 'Nothing matches' : 'No conversations yet',
        message: filtered
            ? 'Try a different search, filter or project.'
            : 'Start a session on your harness and it will appear here, with its '
                  'live status, model and cost.',
        action: filtered
            ? null
            : HarnessPrimaryButton(
                label: 'New session',
                icon: Icons.add_rounded,
                onPressed: onNew,
              ),
      );
    }
    final cupertino = HarnessStyle.isCupertino(context);
    final children = <Widget>[];
    String? section;
    for (final session in sessions) {
      final wants = app.needsAttention(session.id) || session.isBlocked;
      final nextSection = wants
          ? 'Needs you'
          : session.isActive
          ? 'Active now'
          : 'Recent';
      if (nextSection != section) {
        section = nextSection;
        children.add(
          _SectionLabel(
            label: section,
            count: sessions
                .where(
                  (s) => (app.needsAttention(s.id) || s.isBlocked)
                      ? nextSection == 'Needs you'
                      : s.isActive
                      ? nextSection == 'Active now'
                      : nextSection == 'Recent',
                )
                .length,
          ),
        );
      }
      children.add(
        _SessionRow(
          app: app,
          session: session,
          showProject: showProject,
          onTap: () => onOpen(session.id),
        ),
      );
      children.add(
        Divider(
          height: 1,
          indent: _SessionRow.textInset,
          color: Theme.of(context).colorScheme.outlineVariant
              .withValues(alpha: 0.7),
        ),
      );
    }
    if (cupertino) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          CupertinoSliverRefreshControl(onRefresh: onRefresh),
          SliverList(delegate: SliverChildListDelegate(children)),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      edgeOffset: 4,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [...children, const SizedBox(height: 24)],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final style = HarnessText.label(context);
    return Padding(
      // On the gutter, the left edge of the avatars below it.
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.lg,
        HarnessSpace.gutter,
        HarnessSpace.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label.toUpperCase(), style: style),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: style.copyWith(
              fontWeight: FontWeight.w500,
              color: style.color?.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// A conversation in the list.  Three columns: the avatar (its state), the
/// title over what it is about, and at the edge the time over the cost; the
/// two lines of text and the two facts at the edge share their baselines.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.app,
    required this.session,
    required this.showProject,
    required this.onTap,
  });

  final AppController app;
  final SessionSummary session;
  final bool showProject;
  final VoidCallback onTap;

  /// Where the text starts: the gutter, the avatar and the gap after it.
  static const textInset = HarnessSpace.gutter + _avatar + HarnessSpace.md;
  static const _avatar = 40.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = app.summaryFor(session.id) ?? session;
    final attention = app.needsAttention(session.id) || live.isBlocked;
    final status = attention ? 'blocked' : live.status;
    final statusColor = HarnessColors.status(status, theme.brightness);
    final spend = app.spendOf(live);
    final cupertino = HarnessStyle.isCupertino(context);
    final selected =
        app.activeSessionId == session.id &&
        MediaQuery.sizeOf(context).width >= 920;
    final kind = live.kind != null && live.kind != 'main' ? live.kind : null;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Open ${live.displayTitle}, ${statusLabel(status)}',
      child: HarnessTap(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.md,
              HarnessSpace.gutter,
              HarnessSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _SessionAvatar(
                  kind: live.kind,
                  color: statusColor,
                  running: live.isRunning && !attention,
                  attention: attention,
                ),
                const SizedBox(width: HarnessSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              live.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HarnessText.rowTitle(context),
                            ),
                          ),
                          const SizedBox(width: HarnessSpace.sm),
                          Text(
                            relativeTime(live.touchedAt),
                            style: HarnessText.meta(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: HarnessMetaLine(
                              parts: [
                                if (kind != null)
                                  HarnessMetaPart(
                                    kindLabel(kind),
                                    weight: FontWeight.w600,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                if (showProject)
                                  projectName(app.projectOfSession(live)),
                                modelName(live.model),
                              ],
                            ),
                          ),
                          // The price, or the plan that pays: "$0.73", "Max".
                          if (spend.worthShowing) ...[
                            const SizedBox(width: HarnessSpace.sm),
                            Text(
                              spend.text,
                              key: const Key('session-row-spend'),
                              style: HarnessText.meta(context).copyWith(
                                color: spend.planned ? planAccent(theme) : null,
                                fontWeight: spend.planned
                                    ? FontWeight.w700
                                    : null,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (cupertino) ...[
                  const SizedBox(width: HarnessSpace.xs),
                  adaptiveChevron(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionAvatar extends StatelessWidget {
  const _SessionAvatar({
    required this.kind,
    required this.color,
    required this.running,
    required this.attention,
  });

  final String? kind;
  final Color color;
  final bool running;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final icon = switch (kind) {
      'fork' => Icons.call_split_rounded,
      'btw' => Icons.forum_rounded,
      'subagent' => Icons.account_tree_outlined,
      _ => attention ? Icons.front_hand_rounded : Icons.auto_awesome_rounded,
    };
    return Container(
      width: _SessionRow._avatar,
      height: _SessionRow._avatar,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.2 : 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: running
          ? _Pulse(color: color)
          : Icon(icon, size: 18, color: color),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final scale = 0.65 + _controller.value * 0.25;
        return Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(
            color: widget.color.withValues(
              alpha: 0.25 + _controller.value * 0.55,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 * _controller.value),
                blurRadius: 10,
                spreadRadius: scale,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NewSessionSheet extends StatefulWidget {
  const _NewSessionSheet({required this.app});
  final AppController app;

  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _cwd = TextEditingController(
    text: widget.app.selectedProject ?? '',
  );
  late final TextEditingController _model = TextEditingController();
  String? _project;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _project = widget.app.selectedProject;
    if (_project != null) _cwd.text = _project!;
  }

  @override
  void dispose() {
    _name.dispose();
    _cwd.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final cwd = (_project ?? _cwd.text).trim();
    if (cwd.isEmpty) {
      setState(() => _error = 'Choose a project or type an absolute path.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = await widget.app.createSession(
      cwd: cwd,
      name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      model: _model.text.trim().isEmpty ? null : _model.text.trim(),
    );
    if (!mounted) return;
    if (id == null) {
      setState(() {
        _busy = false;
        _error =
            widget.app.lastActionError ??
            'The harness could not create the session.';
      });
      return;
    }
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final projects = app.projects;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 6,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('New session', style: HarnessText.sheetTitle(context)),
            const SizedBox(height: 4),
            Text(
              'A conversation is scoped to a directory.',
              style: HarnessText.subtitle(context),
            ),
            const SizedBox(height: 20),
            if (projects.isNotEmpty) ...[
              Text('PROJECT', style: HarnessText.label(context)),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final project in projects)
                    HarnessPill(
                      label: projectName(project),
                      icon: Icons.folder_outlined,
                      selected: _project == project,
                      onTap: () => setState(() {
                        _project = project;
                        _cwd.text = project;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            HarnessTextField(
              controller: _cwd,
              hint: '/absolute/path/to/project',
              prefix: const Icon(Icons.folder_open_rounded, size: 18),
              onChanged: (_) {
                if (_project != null) setState(() => _project = null);
              },
            ),
            const SizedBox(height: 14),
            Text('NAME (OPTIONAL)', style: HarnessText.label(context)),
            const SizedBox(height: 7),
            HarnessTextField(
              controller: _name,
              hint: 'What is this conversation about?',
            ),
            if (app.capability?.isHarness == true) ...[
              const SizedBox(height: 14),
              Text('MODEL (OPTIONAL)', style: HarnessText.label(context)),
              const SizedBox(height: 7),
              HarnessTextField(
                controller: _model,
                hint: 'provider:model, or leave empty for the harness default',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              HarnessErrorBanner(message: _error!, margin: EdgeInsets.zero),
            ],
            const SizedBox(height: 20),
            HarnessPrimaryButton(
              label: _busy ? 'Creating…' : 'Start session',
              icon: _busy ? null : Icons.arrow_forward_rounded,
              expand: true,
              busy: _busy,
              onPressed: _busy ? null : _create,
            ),
          ],
        ),
      ),
    );
  }
}
