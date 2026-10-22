import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/session.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
                child: Row(
                  children: [
                    Text(
                      'Sessions',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${app.sessions.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HarnessTextField(
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
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              HarnessPill(
                label: 'All',
                count: app.sessions.length,
                selected: filter == _SessionFilter.all,
                onTap: () => onFilter(_SessionFilter.all),
              ),
              HarnessPill(
                label: 'Active',
                count: active,
                selected: filter == _SessionFilter.active,
                onTap: () => onFilter(_SessionFilter.active),
              ),
              HarnessPill(
                label: 'Needs you',
                count: attention,
                selected: filter == _SessionFilter.needsYou,
                color: attention > 0 ? HarnessColors.amber : null,
                onTap: () => onFilter(_SessionFilter.needsYou),
              ),
              HarnessPill(
                label: project == null ? 'All projects' : projectName(project),
                icon: Icons.folder_outlined,
                selected: project != null,
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
            ],
          ),
          if (app.capability?.isHarness != true) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.cable_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Standard ACP agent · the task board and usage views are hidden.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({
    required this.app,
    required this.sessions,
    required this.onOpen,
    required this.onRefresh,
    required this.onNew,
    required this.filtered,
  });

  final AppController app;
  final List<SessionSummary> sessions;
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
          onTap: () => onOpen(session.id),
        ),
      );
      children.add(
        Divider(
          height: 1,
          indent: 68,
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.15,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.app,
    required this.session,
    required this.onTap,
  });

  final AppController app;
  final SessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = app.summaryFor(session.id) ?? session;
    final attention = app.needsAttention(session.id) || live.isBlocked;
    final status = attention ? 'blocked' : live.status;
    final statusColor = HarnessColors.status(status, theme.brightness);
    final spend = app.spendOf(live);
    final selected =
        app.activeSessionId == session.id &&
        MediaQuery.sizeOf(context).width >= 920;
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
            padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _SessionAvatar(
                  kind: live.kind,
                  color: statusColor,
                  running: live.isRunning && !attention,
                  attention: attention,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              live.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.2,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          if (live.kind != null && live.kind != 'main') ...[
                            const SizedBox(width: 6),
                            _KindTag(kind: live.kind!),
                          ],
                          if (live.isBlocked && !attention) ...[
                            const SizedBox(width: 6),
                            HarnessStatusPill(
                              label: 'Waiting',
                              color: HarnessColors.amber,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _subtitle(live),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      relativeTime(live.touchedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: attention
                            ? HarnessColors.amber
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: attention
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (attention)
                      const HarnessStatusPill(
                        label: 'Needs you',
                        color: HarnessColors.amber,
                      )
                    else if (spend.worthShowing)
                      // The price, or the plan that pays: "$0.73", "Max".
                      Text(
                        spend.text,
                        key: const Key('session-row-spend'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: spend.planned
                              ? planAccent(theme)
                              : theme.colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.65,
                                ),
                          fontWeight: spend.planned
                              ? FontWeight.w700
                              : FontWeight.w500,
                          fontSize: 10,
                        ),
                      )
                    else
                      Text(
                        statusLabel(live.status),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 2),
                adaptiveChevron(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(SessionSummary live) {
    final project = projectName(app.projectOfSession(live));
    final model = modelName(live.model);
    return '$project · $model';
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
      width: 40,
      height: 40,
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

class _KindTag extends StatelessWidget {
  const _KindTag({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        kindLabel(kind),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
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
    final theme = Theme.of(context);
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
            Text(
              'New session',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'A conversation is scoped to a directory.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            if (projects.isNotEmpty) ...[
              Text('PROJECT', style: _labelStyle(theme)),
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
            Text('NAME (OPTIONAL)', style: _labelStyle(theme)),
            const SizedBox(height: 7),
            HarnessTextField(
              controller: _name,
              hint: 'What is this conversation about?',
            ),
            if (app.capability?.isHarness == true) ...[
              const SizedBox(height: 14),
              Text('MODEL (OPTIONAL)', style: _labelStyle(theme)),
              const SizedBox(height: 7),
              HarnessTextField(
                controller: _model,
                hint: 'provider:model, or leave empty for the harness default',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              HarnessErrorBanner(message: _error!),
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

  TextStyle? _labelStyle(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurfaceVariant,
      );
}
