import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
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
    final body = Stack(
      children: [
        IndexedStack(
          index: index < 0 ? 0 : index,
          children: [for (final tab in tabs) _screen(tab.id)],
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (app.lastActionError != null)
                  HarnessErrorBanner(
                    message: app.lastActionError!,
                    onDismiss: app.clearActionError,
                  ),
                if (app.attentionCount > 0)
                  _AttentionBanner(
                    count: app.attentionCount,
                    onTap: _openAttentionSession,
                  ),
              ],
            ),
          ),
        ),
      ],
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
            Expanded(child: body),
          ],
        ),
      );
    }

    if (cupertino) {
      return CupertinoPageScaffold(
        child: Column(
          children: [
            Expanded(child: body),
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: index < 0 ? 0 : index,
        onDestinationSelected: (next) => _select(tabs[next].id),
        destinations: [
          for (final tab in tabs)
            NavigationDestination(
              icon: _BadgedIcon(
                icon: Icon(tab.materialIcon),
                count: tab.id == 'tasks' ? (app.tasks?.needsAttention ?? 0) : 0,
              ),
              selectedIcon: _BadgedIcon(
                icon: Icon(tab.materialIcon),
                count: tab.id == 'tasks' ? (app.tasks?.needsAttention ?? 0) : 0,
              ),
              label: tab.label,
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
            subtitle: app.capability?.isHarness == true
                ? 'HARNESS'
                : 'ACP CLIENT',
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
        Padding(
          padding: const EdgeInsets.all(14),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: HarnessColors.moss,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        app.capability?.agentName ?? 'Connected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  shortAddress(app.address),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                HarnessTextButton(
                  label: 'Disconnect',
                  icon: Icons.logout_rounded,
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

class _AttentionBanner extends StatelessWidget {
  const _AttentionBanner({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = HarnessColors.amber;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.front_hand_rounded, size: 16, color: color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    count == 1
                        ? 'One session needs your answer'
                        : '$count sessions need your answer',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.arrow_forward_rounded, size: 15, color: color),
              ],
            ),
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
