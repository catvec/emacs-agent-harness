import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_controller.dart';
import '../../state/quick_search_catalogue.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../harness_keys.dart';
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

  @override
  void initState() {
    super.initState();
    widget.app.requestedTab.addListener(_buddyRequestedTab);
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.requestedTab.removeListener(_buddyRequestedTab);
      widget.app.requestedTab.addListener(_buddyRequestedTab);
    }
  }

  @override
  void dispose() {
    widget.app.requestedTab.removeListener(_buddyRequestedTab);
    super.dispose();
  }

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

  /// The buddy as the app draws it when it has no window of its own.  On a
  /// desktop the separate window is the buddy's surface; where that is
  /// impossible (the web, or a compositor that refuses one), the card has to
  /// stay over the page, because an away-only in-app card would vanish the
  /// moment the person clicked it.  The call's bar is not touched by either:
  /// it is the app's own surface.
  Widget _withBuddy(Widget child) {
    final buddy = widget.app.workspaceBuddy;
    if (buddy == null) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: widget.app.buddyWindow.available,
      builder: (context, available, _) {
        if (available) return child;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: WorkspaceBuddyLayer(
                controller: buddy,
                onOpenWorkspace: () => _select('workspace'),
                onOpenSettings: _openBuddySettings,
              ),
            ),
          ],
        );
      },
    );
  }

  /// The buddy window's workspace action comes through the app, because the
  /// window is outside this shell.  Select the tab it asks for; an empty
  /// request is the idle state.
  void _buddyRequestedTab() {
    final tab = widget.app.requestedTab.value;
    if (tab.isEmpty || !mounted) return;
    widget.app.requestedTab.value = '';
    _select(tab);
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
                ? '1 session · your answer'
                : '$count sessions · your answer',
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
    final body = HarnessKeyLayer(
      // The search is the one function every page of the shell has; a
      // conversation adds its own commands in its own layer.
      commands: {LogicalKeyboardKey.keyS: _openQuickSearch},
      child: HarnessChrome(
        notices: _notices,
        child: IndexedStack(
          index: index < 0 ? 0 : index,
          children: [for (final tab in tabs) _screen(tab.id)],
        ),
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
          // Fluent's bar is a panel of the window, with a rule above it.
          if (HarnessStyle.isWindows(context))
            Divider(
              height: 1,
              thickness: 1,
              color: theme.colorScheme.outlineVariant,
            ),
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
    // Windows' navigation pane is a little wider than GNOME's, and GNOME's
    // a little wider than Android's.
    final look = HarnessStyle.lookOf(context);
    final wide = MediaQuery.sizeOf(context).width >= 1180;
    final width = switch (look) {
      HarnessPlatformStyle.windows => wide ? 300.0 : 256.0,
      HarnessPlatformStyle.linux => wide ? 268.0 : 232.0,
      _ => wide ? 264.0 : 228.0,
    };
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
    // A desktop pane is a panel of the window, with a rule where the page
    // starts; Android's sidebar is the page's own surface.
    final desktop =
        HarnessStyle.isWindows(context) || HarnessStyle.isLinux(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: desktop
            ? Border(right: BorderSide(color: theme.colorScheme.outlineVariant))
            : null,
      ),
      child: SafeArea(right: false, child: content),
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
    final windows = HarnessStyle.isWindows(context);
    final linux = HarnessStyle.isLinux(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // The field is a Fluent search box, a GNOME search entry, or the app's
    // own row: its corners, padding and type follow the look.
    final radius = windows
        ? 4.0
        : linux
        ? 8.0
        : 12.0;
    return Semantics(
      button: true,
      label: QuickSearchEntry.buttonLabel,
      child: HarnessTap(
        key: const Key('sidebar-quick-search'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: windows
                ? 12
                : linux
                ? 14
                : 13,
            vertical: windows
                ? 8
                : linux
                ? 9
                : 11,
          ),
          decoration: BoxDecoration(
            color: windows || linux
                ? theme.colorScheme.surfaceContainerLow
                : null,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                cupertino ? CupertinoIcons.search : Icons.search_rounded,
                size: windows
                    ? 18
                    : linux
                    ? 20
                    : 19,
                color: muted,
              ),
              SizedBox(
                width: windows
                    ? 10
                    : linux
                    ? 12
                    : 11,
              ),
              Expanded(
                child: Text(
                  'Search',
                  style: TextStyle(
                    fontSize: windows
                        ? 13
                        : linux
                        ? 15
                        : 14,
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
    final windows = HarnessStyle.isWindows(context);
    final linux = HarnessStyle.isLinux(context);
    final theme = Theme.of(context);
    final primary = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : theme.colorScheme.primary;
    // Fluent's rows are compact, GNOME's are roomy, Android's are in between.
    final fontSize = windows
        ? 13.0
        : linux
        ? 15.0
        : 14.0;
    final iconSize = windows
        ? 18.0
        : linux
        ? 20.0
        : 19.0;
    final gap = windows
        ? 10.0
        : linux
        ? 12.0
        : 11.0;
    final vertical = windows
        ? 8.0
        : linux
        ? 10.0
        : 11.0;
    final horizontal = windows
        ? 12.0
        : linux
        ? 14.0
        : 13.0;
    final weight = selected
        ? (linux
              ? FontWeight.w700
              : windows
              ? FontWeight.w600
              : FontWeight.w700)
        : (windows ? FontWeight.w400 : FontWeight.w500);
    // Each look marks the page in use the way its own system does: a tint
    // and a bar at the start on Windows, a tinted pill on GNOME, the
    // primary container on Android, an accent wash on Apple.
    final radius = windows
        ? 4.0
        : linux
        ? 10.0
        : 12.0;
    final selectedColor = windows
        ? theme.colorScheme.surfaceContainerHigh
        : linux
        ? primary.withValues(alpha: 0.16)
        : cupertino
        ? primary.withValues(alpha: 0.12)
        : theme.colorScheme.primaryContainer;
    final color = !selected
        ? theme.colorScheme.onSurfaceVariant
        : cupertino
        ? primary
        : windows || linux
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimaryContainer;
    final iconColor = selected && (windows || linux) ? primary : color;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: AnimatedContainer(
          key: Key('sidebar-item-${tab.id}'),
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(
            horizontal: horizontal,
            vertical: vertical,
          ),
          decoration: BoxDecoration(
            color: selected ? selectedColor : Colors.transparent,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  Icon(
                    cupertino ? tab.cupertinoIcon : tab.materialIcon,
                    size: iconSize,
                    color: iconColor,
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: weight,
                        color: color,
                      ),
                    ),
                  ),
                  if (badge > 0) HarnessBadge(count: badge),
                ],
              ),
              // Fluent's selection mark: a bar at the leading edge, over the
              // row's padding, so the name does not move when it is chosen.
              if (selected && windows)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      key: const Key('sidebar-accent-bar'),
                      width: 3,
                      height: 16,
                      decoration: BoxDecoration(
                        color: primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
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
            'Transcript · tools · requests',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
