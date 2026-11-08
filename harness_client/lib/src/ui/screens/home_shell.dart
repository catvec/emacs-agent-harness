import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../state/quick_search_catalogue.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/connection_banner.dart';
import '../widgets/voice_settings_sheet.dart';
import '../widgets/workspace_buddy.dart';
import '../widgets/quick_search_entry.dart';
import 'quick_search_screen.dart';
import 'session_screen.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';
import 'usage_screen.dart';
import 'workspace_screen.dart';
import 'server_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.app});

  final AppController app;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> implements QuickSearchHost {
  String _tab = 'sessions';

  /// The compact buddy's settings use the same voice sheet as the full
  /// voice screen; a change is saved and applied to a running call.
  Future<void> _openBuddySettings() async {
    final buddy = widget.app.workspaceBuddy;
    if (buddy == null) return;
    final next = await showVoiceSettingsSheet(
      context,
      settings: widget.app.settings.voiceSettings,
      harnessAddress: widget.app.address ?? widget.app.settings.address,
    );
    if (next != null) await buddy.applyVoiceSettings(next);
  }

  /// The away buddy floats over whichever shell is showing, only while the
  /// window is not the one in use.  While it is, the in-call bar and the
  /// full call view are the call's surfaces; below the desktop breakpoint
  /// the bar is, so no microphone is left behind an absent card.
  Widget _withBuddy(Widget child) {
    final buddy = widget.app.workspaceBuddy;
    if (buddy == null) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: widget.app.windowActive,
      builder: (context, active, _) => Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned.fill(
            child: WorkspaceBuddyLayer(
              controller: buddy,
              away: !active,
              onOpenWorkspace: () => _select('workspace'),
              onOpenSettings: _openBuddySettings,
            ),
          ),
        ],
      ),
    );
  }

  List<_Tab> _tabs(AppController app) => [
    const _Tab(
      'sessions',
      'Sessions',
      Icons.forum_outlined,
      CupertinoIcons.chat_bubble_2,
    ),
    if (app.hasWorkspace)
      const _Tab(
        'workspace',
        'Workspace',
        Icons.workspaces_outline,
        CupertinoIcons.square_grid_2x2,
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
      Navigator.of(context).push(
        harnessRoute(
          context,
          // The conversation has the quick search too, which then knows
          // whose it is: what it finds leaves this session out.
          (context) => QuickSearchEntry(
            open: () => _searchFrom(
              QuickSearchPlace.chat(
                id,
                title: widget.app.summaryFor(id)?.displayTitle,
              ),
            ),
            child: SessionScreen(sessionId: id),
          ),
        ),
      );
    }
  }

  /// The quick search of the screen that is open.
  void _openQuickSearch() =>
      _searchFrom(QuickSearchPlace(SearchOrigin.ofTab(_tab)));

  /// Open the quick search from [place], and do what it is closed with: the
  /// page closes first, so that what is chosen is done on the screens, not
  /// on it.
  Future<void> _searchFrom(QuickSearchPlace place) async {
    final choice = await Navigator.of(context).push<QuickSearchChoice>(
      harnessRoute(
        context,
        (context) => QuickSearchScreen(app: widget.app, place: place),
      ),
    );
    if (choice != null && mounted) await choice(this);
  }

  @override
  void openTab(String tab) {
    final navigator = Navigator.of(context);
    // A conversation on top of the screens is left first, and told so, rather
    // than leaving that to its screen as it goes: it would tell the screens
    // that listen while the framework takes it down, when they cannot be
    // rebuilt.  (With the conversation beside the list, on a wide screen, it
    // stays where it is.)
    if (navigator.canPop()) widget.app.closeSession();
    navigator.popUntil((route) => route.isFirst);
    _select(tab);
  }

  @override
  void openSession(String sessionId) => _openSession(sessionId);

  @override
  bool openNeedsYou() {
    for (final session in widget.app.sessions) {
      if (widget.app.needsAttention(session.id)) {
        _openSession(session.id);
        return true;
      }
    }
    return false;
  }

  Widget _screen(String id) {
    final app = widget.app;
    return switch (id) {
      'workspace' => WorkspaceScreen(app: app, onOpenSession: _openSession),
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
    // Every page under the shell has the way into the quick search in its
    // header (see `HarnessPage`).
    return QuickSearchEntry(open: _openQuickSearch, child: _shell(context));
  }

  Widget _shell(BuildContext context) {
    final app = widget.app;
    final tabs = _tabs(app);
    if (!tabs.any((tab) => tab.id == _tab)) {
      _tab = 'sessions';
    }
    final index = tabs.indexWhere((tab) => tab.id == _tab);
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 920;
    final cupertino = HarnessStyle.isCupertino(context);
    final labels = [for (final tab in tabs) tab.label];
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
        body: _withBuddy(
          Row(
            children: [
              _Sidebar(
                tabs: tabs,
                selected: _tab,
                onSelect: _select,
                onSearch: _openQuickSearch,
                app: app,
              ),
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
        ),
      );
    }

    if (cupertino) {
      // The names under the icons fit their destinations in one line, at a
      // size they share (see `_fittedLabelScale`).
      final fitted = _fittedLabelScale(
        context,
        labels: labels,
        barWidth: width,
        style: CupertinoTheme.of(context).textTheme.tabLabelTextStyle,
      );
      return CupertinoPageScaffold(
        child: Column(
          children: [
            Expanded(child: _withBuddy(body)),
            ConnectionBanner(app: app),
            _withFittedLabels(
              fitted,
              CupertinoTabBar(
                currentIndex: index < 0 ? 0 : index,
                onTap: (next) => _select(tabs[next].id),
                backgroundColor: CupertinoTheme.of(context).barBackgroundColor,
                activeColor: CupertinoTheme.of(context).primaryColor,
                inactiveColor: CupertinoColors.tertiaryLabel.resolveFrom(
                  context,
                ),
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
            ),
          ],
        ),
      );
    }

    final theme = Theme.of(context);
    final fitted = _fittedLabelScale(
      context,
      labels: labels,
      barWidth: width,
      style:
          theme.navigationBarTheme.labelTextStyle?.resolve(<WidgetState>{}) ??
          theme.textTheme.labelSmall ??
          const TextStyle(fontSize: 11),
    );

    return Scaffold(
      body: _withBuddy(body),
      // Above the navigation bar, in the layout: a banner that stays for as
      // long as the harness cannot be reached must not cover the buttons of
      // the screen above it.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectionBanner(app: app),
          _withFittedLabels(
            fitted,
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
          ),
        ],
      ),
    );
  }
}

/// The largest scale of the text at which every one of [labels] fits the
/// destination the bottom bar gives it, or null when the size in use already
/// fits.
///
/// A phone has room for six destinations only just: at 320 points each one
/// has 53 for its name, and a name that does not fit there is broken in the
/// middle of the word.  The bar draws every name at one size, smaller than
/// the text is set when the names are long and the phone is narrow, so that
/// no name is ever two lines.  `null` leaves the bar as it is: the names of
/// a wide phone, or of a harness with three destinations, still grow with
/// the text as a person sets it.
double? _fittedLabelScale(
  BuildContext context, {
  required List<String> labels,
  required double barWidth,
  required TextStyle style,
}) {
  if (labels.isEmpty || barWidth <= 0) return null;
  // The bar gives each destination the same width.  What is left after this
  // margin is where a label's line has to end; it keeps a name off the edge
  // of its destination when a font rounds a width up.
  const gap = 4.0;
  final cell = barWidth / labels.length;
  if (cell <= gap) return null;
  final direction = Directionality.of(context);
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: direction,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  if (widest <= 0) return null;
  final fits = (cell - gap) / widest;
  final size = style.fontSize ?? 14;
  final inUse = MediaQuery.textScalerOf(context).scale(size) / size;
  return fits < inUse ? fits : null;
}

/// [bar] with its labels at no more than [scale] of the text size in use;
/// the bar itself when [scale] is null.
Widget _withFittedLabels(double? scale, Widget bar) => scale == null
    ? bar
    : MediaQuery.withClampedTextScaling(maxScaleFactor: scale, child: bar);

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
    required this.onSearch,
    required this.app,
  });

  final List<_Tab> tabs;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onSearch;
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
        // The search is not a place: it is the way to any of them.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: _SidebarSearch(onTap: onSearch),
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

/// The row of the sidebar that opens the quick search.
class _SidebarSearch extends StatelessWidget {
  const _SidebarSearch({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: QuickSearchEntry.buttonLabel,
      child: HarnessTap(
        key: const Key('sidebar-quick-search'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                cupertino ? CupertinoIcons.search : Icons.search_rounded,
                size: 19,
                color: muted,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  'Search',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: muted,
                  ),
                ),
              ),
            ],
          ),
        ),
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
