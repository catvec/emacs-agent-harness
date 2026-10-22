import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';
import 'session_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';
import 'usage_screen.dart';
import 'server_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final AppController app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _tab = 'sessions';

  List<_Tab> _tabs(AppController app) => [
    const _Tab(
      'sessions',
      'Sessions',
      Icons.forum_outlined,
      CupertinoIcons.chat_bubble_2,
    ),
    if (app.hasTasks)
      const _Tab(
        'tasks',
        'Tasks',
        Icons.checklist_rtl_rounded,
        CupertinoIcons.checkmark_circle,
      ),
    if (app.hasUsage)
      const _Tab(
        'usage',
        'Usage',
        Icons.insights_rounded,
        CupertinoIcons.chart_bar_alt_fill,
      ),
    const _Tab(
      'server',
      'Server',
      Icons.dns_outlined,
      CupertinoIcons.bolt_horizontal_circle,
    ),
    const _Tab(
      'settings',
      'Settings',
      Icons.tune_rounded,
      CupertinoIcons.settings,
    ),
  ];

  void _select(String id) {
    setState(() => _tab = id);
  }

  Future<void> _openAttentionSession() async {
    for (final session in widget.app.sessions) {
      if (widget.app.needsAttention(session.id)) {
        _openSession(session.id);
        return;
      }
    }
  }

  void _openSession(String id) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    if (wide) {
      setState(() => _tab = 'sessions');
      widget.app.openSession(id);
    } else {
      Navigator.of(
        context,
      ).push(harnessRoute(context, (context) => SessionScreen(sessionId: id)));
    }
  }

  Widget _screen(String id) {
    final app = widget.app;
    return switch (id) {
      'tasks' => TasksScreen(app: app, onOpenSession: _openSession),
      'usage' => UsageScreen(app: app, onOpenSession: _openSession),
      'server' => ServerScreen(app: app),
      'settings' => SettingsScreen(app: app),
      _ => SessionsWorkspace(app: app, onOpenSession: _openSession),
    };
  }

  /// The notices of the shell, in the order a person should meet them: what
  /// went wrong, then what waits for an answer.
  Widget _notices(BuildContext context, {required bool attention}) {
    final app = widget.app;
    final count = app.attentionCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (app.lastActionError != null)
          HarnessErrorBanner(
            message: app.lastActionError!,
            onDismiss: app.clearActionError,
          ),
        if (attention && count > 0)
          HarnessNotice(
            icon: Icons.front_hand_rounded,
            message: count == 1
                ? 'One session needs your answer'
                : '$count sessions need your answer',
            onTap: _openAttentionSession,
            margin: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.sm,
              HarnessSpace.gutter,
              HarnessSpace.xs,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final tabs = _tabs(app);
    if (!tabs.any((tab) => tab.id == _tab)) {
      _tab = 'sessions';
    }
    final index = tabs.indexWhere((tab) => tab.id == _tab);
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final cupertino = HarnessStyle.isCupertino(context);
    // What the shell has to say (a failed action, a session that needs an
    // answer) is not laid over the pages: each page puts it in its own flow,
    // under its header (see [HarnessChrome]).
    final body = HarnessChrome(
      notices: _notices,
      child: IndexedStack(
        index: index < 0 ? 0 : index,
        children: [for (final tab in tabs) _screen(tab.id)],
      ),
    );

    if (wide) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Row(
          children: [
            _Sidebar(tabs: tabs, selected: _tab, onSelect: _select, app: app),
            VerticalDivider(
              width: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(
              child: Column(
                children: [
                  ConnectionBanner(app: app, safeTop: true),
                  // The banner, when it shows, has kept clear of the status
                  // bar: the page below it need not.  (Always wrapped, so
                  // that the screens are not rebuilt when it comes and goes.)
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: app.isReconnecting,
                      child: body,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (cupertino) {
      return CupertinoPageScaffold(
        child: Column(
          children: [
            Expanded(child: body),
            ConnectionBanner(app: app),
            CupertinoTabBar(
              currentIndex: index < 0 ? 0 : index,
              onTap: (next) => _select(tabs[next].id),
              backgroundColor: CupertinoTheme.of(context).barBackgroundColor,
              activeColor: CupertinoTheme.of(context).primaryColor,
              inactiveColor: CupertinoColors.tertiaryLabel.resolveFrom(context),
              items: [
                for (final tab in tabs)
                  BottomNavigationBarItem(
                    icon: _TabIcon(
                      tab: tab,
                      selected: _tab == tab.id,
                      badge: tab.id == 'tasks'
                          ? (app.tasks?.needsAttention ?? 0)
                          : 0,
                    ),
                    label: tab.label,
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      // Above the navigation bar, in the layout: a banner that stays for as
      // long as the harness cannot be reached must not cover the buttons of
      // the screen above it.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectionBanner(app: app),
          NavigationBar(
            selectedIndex: index < 0 ? 0 : index,
            onDestinationSelected: (next) => _select(tabs[next].id),
            destinations: [
              for (final tab in tabs)
                NavigationDestination(
                  icon: _BadgedIcon(
                    icon: Icon(tab.materialIcon),
                    count: tab.id == 'tasks'
                        ? (app.tasks?.needsAttention ?? 0)
                        : 0,
                  ),
                  selectedIcon: _BadgedIcon(
                    icon: Icon(tab.materialIcon),
                    count: tab.id == 'tasks'
                        ? (app.tasks?.needsAttention ?? 0)
                        : 0,
                  ),
                  label: tab.label,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tab {
  const _Tab(this.id, this.label, this.materialIcon, this.cupertinoIcon);
  final String id;
  final String label;
  final IconData materialIcon;
  final IconData cupertinoIcon;
}

class _TabIcon extends StatelessWidget {
  const _TabIcon({
    required this.tab,
    required this.selected,
    required this.badge,
  });

  final _Tab tab;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      tab.cupertinoIcon,
      color: selected
          ? CupertinoTheme.of(context).primaryColor
          : CupertinoColors.tertiaryLabel.resolveFrom(context),
    );
    if (badge <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(right: -9, top: -5, child: HarnessBadge(count: badge)),
      ],
    );
  }
}

class _BadgedIcon extends StatelessWidget {
  const _BadgedIcon({required this.icon, required this.count});
  final Widget icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return icon;
    return Badge.count(count: count, child: icon);
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.app,
  });

  final List<_Tab> tabs;
  final String selected;
  final ValueChanged<String> onSelect;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width >= 1180 ? 264.0 : 228.0;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
          child: HarnessWordmark(
            size: 30,
            color: theme.colorScheme.onSurface,
            subtitle: 'AGENT CLIENT',
          ),
        ),
        for (final tab in tabs)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: _SidebarItem(
              tab: tab,
              selected: tab.id == selected,
              badge: tab.id == 'tasks' ? (app.tasks?.needsAttention ?? 0) : 0,
              onTap: () => onSelect(tab.id),
            ),
          ),
        const Spacer(),
        // Who this is connected to, and the way out: one block, its two
        // lines left-aligned under the dot.
        Padding(
          padding: const EdgeInsets.all(HarnessSpace.md),
          child: HarnessCard(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                HarnessDot(
                  color: app.isReconnecting
                      ? HarnessColors.amber
                      : HarnessColors.moss,
                  size: 8,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        app.capability?.agentName ?? 'Connected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.rowTitle(context)
                            .copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        app.isReconnecting
                            ? 'Reconnecting…'
                            : shortAddress(app.address),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.caption(context),
                      ),
                    ],
                  ),
                ),
                HarnessIconButton(
                  icon: adaptiveIcon(
                    context,
                    Icons.logout_rounded,
                    CupertinoIcons.square_arrow_right,
                  ),
                  label: 'Disconnect',
                  size: 19,
                  onPressed: app.disconnect,
                ),
              ],
            ),
          ),
        ),
      ],
    );
    if (cupertino) {
      return Container(
        width: width,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGroupedBackground.resolveFrom(context),
          border: Border(
            right: BorderSide(
              color: CupertinoColors.separator.resolveFrom(context),
              width: 0.5,
            ),
          ),
        ),
        child: SafeArea(right: false, child: content),
      );
    }
    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      child: SizedBox(
        width: width,
        child: SafeArea(right: false, child: content),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.tab,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final theme = Theme.of(context);
    final color = selected
        ? (cupertino
              ? CupertinoTheme.of(context).primaryColor
              : theme.colorScheme.onPrimaryContainer)
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? (cupertino
                      ? CupertinoTheme.of(context).primaryColor
                            .withValues(alpha: 0.12)
                      : theme.colorScheme.primaryContainer)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                cupertino ? tab.cupertinoIcon : tab.materialIcon,
                size: 19,
                color: color,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  tab.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
              if (badge > 0) HarnessBadge(count: badge),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionsWorkspace extends StatelessWidget {
  const SessionsWorkspace({
    super.key,
    required this.app,
    required this.onOpenSession,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final selectedId = app.activeSessionId;
    if (!wide) {
      return SessionsScreen(app: app, onOpenSession: onOpenSession);
    }
    // The two panes have no page header between them to put a notice under:
    // what went wrong is above both.  (The list says what needs an answer.)
    final notices = HarnessChrome.maybeOf(context)
        ?.notices(context, attention: false);
    return Column(
      children: [
        notices ?? const SizedBox.shrink(),
        Expanded(child: _panes(context, selectedId)),
      ],
    );
  }

  Widget _panes(BuildContext context, String? selectedId) {
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: SessionsScreen(
            app: app,
            onOpenSession: onOpenSession,
            embedded: true,
          ),
        ),
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(
          child: selectedId == null
              ? const _WideEmptyDetail()
              : SessionScreen(
                  key: ValueKey(selectedId),
                  sessionId: selectedId,
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

class _WideEmptyDetail extends StatelessWidget {
  const _WideEmptyDetail();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HarnessMark(
            size: 58,
            color: theme.colorScheme.primary.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 18),
          Text(
            'Pick a conversation',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'The transcript, tools and requests show here.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
