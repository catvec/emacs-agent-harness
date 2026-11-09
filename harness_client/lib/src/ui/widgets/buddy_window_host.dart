import 'dart:async';

import 'package:flutter/material.dart';
// The windowing API is experimental, like the window this widget hosts.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart' as fw;

import '../../state/app_controller.dart';
import '../../state/workspace_buddy_controller.dart';
import '../../desktop/buddy_window.dart';
import 'workspace_buddy.dart';

/// The native buddy window's lifecycle, as part of the app's widget tree.
///
/// It owns no UI of its own: it decides when the away surface is wanted and
/// lets [BuddyWindowService] draw it.  The card inside that window is the
/// same [WorkspaceBuddyView] and the same [WorkspaceBuddyController] the
/// in-app fallback uses, so a click there is a click on the same call.
class BuddyWindowHost extends StatefulWidget {
  const BuddyWindowHost({
    super.key,
    required this.app,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
    required this.child,
  });

  final AppController app;
  final VoidCallback onOpenWorkspace;
  final Future<void> Function() onOpenSettings;
  final Widget child;

  @override
  State<BuddyWindowHost> createState() => _BuddyWindowHostState();
}

class _BuddyWindowHostState extends State<BuddyWindowHost> {
  /// The desktop breakpoint.  The buddy is a desktop surface: a phone keeps
  /// the in-call bar and never shows the card.
  static const double _desktopWidth = 920;

  late final Listenable _listenables = Listenable.merge([
    widget.app,
    widget.app.windowActive,
    widget.app.buddyWindow.available,
    widget.app.buddyWindow.activated,
  ]);

  bool _shown = false;
  bool _scheduled = false;
  double _shownWidth = 0;
  WorkspaceBuddyController? _shownBuddy;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _listenables,
      builder: (context, _) {
        final buddy = widget.app.workspaceBuddy;
        if (buddy == null) {
          _settle(false, null);
          return widget.child;
        }
        return ListenableBuilder(
          listenable: buddy,
          builder: (context, _) {
            _settle(_visible(context, buddy), buddy);
            return widget.child;
          },
        );
      },
    );
  }

  bool _visible(BuildContext context, WorkspaceBuddyController buddy) {
    if (!widget.app.buddyWindow.available.value) return false;
    // The card is the away surface of a call, not of the workspace's opt-in.
    // Opting in with no call leaves the card out of the way until one starts;
    // a starting, ending or failed call keeps it, so a problem and Retry are
    // not hidden with the window.
    if (!buddy.enabled || !buddy.inCall || buddy.callViewOpen) return false;
    // A compositor that activates the card window when it is clicked makes
    // the app resume; the main window is still not the one in use, so the
    // card stays while its own window is the active one.  Once that window
    // loses activation, the app being active means the main window is back.
    if (widget.app.windowActive.value &&
        !widget.app.buddyWindow.isActivated) {
      return false;
    }
    return MediaQuery.sizeOf(context).width >= _desktopWidth;
  }

  /// Applies the wanted state after the current frame: registering a window
  /// makes the window manager rebuild, which must not happen in a build.
  void _settle(bool visible, WorkspaceBuddyController? buddy) {
    if (!mounted) return;
    if (!visible) {
      final hadWindow = _shown || _shownBuddy != null;
      if (_shown) {
        widget.app.buddyWindow.hide();
        _shown = false;
      }
      if (hadWindow && (buddy == null || !buddy.enabled)) {
        widget.app.buddyWindow.destroy();
        _shownBuddy = null;
        _shownWidth = 0;
      }
      return;
    }
    // The text scale decides the card's width; a window that is already up
    // still has to follow it.
    final width = WorkspaceBuddyView.widthFor(context);
    if (identical(buddy, _shownBuddy) && _shown && width == _shownWidth) {
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final app = widget.app;
      final buddy = app.workspaceBuddy;
      if (buddy == null || !app.buddyWindow.available.value) return;
      if (!_visible(context, buddy)) {
        _settle(false, buddy);
        return;
      }
      final width = WorkspaceBuddyView.widthFor(context);
      // The window has a media query and a theme of its own; the card keeps
      // the app's, so it is the same card at the same text size, not a copy
      // that happens to use the same words.
      final theme = Theme.of(context);
      final textScaler = MediaQuery.textScalerOf(context);
      final disableAnimations = MediaQuery.disableAnimationsOf(context);
      app.buddyWindow.show(
        context,
        BuddyWindowRequest(
          controller: buddy,
          width: width,
          builder: (context, startDrag) => BuddyWindowContent(
            buddy: buddy,
            width: width,
            theme: theme,
            textScaler: textScaler,
            disableAnimations: disableAnimations,
            startDrag: startDrag,
            onActivated: app.buddyWindow.reportActivated,
            onContentSize: app.buddyWindow.reportContentSize,
            onOpenWorkspace: widget.onOpenWorkspace,
            onOpenSettings: widget.onOpenSettings,
          ),
        ),
      );
      _shown = true;
      _shownWidth = width;
      _shownBuddy = buddy;
    });
  }
}

/// The card as the native window draws it: the app's theme in a transparent
/// root, the same compact view, and a drag that moves the window.
class BuddyWindowContent extends StatefulWidget {
  const BuddyWindowContent({
    super.key,
    required this.buddy,
    required this.width,
    required this.theme,
    required this.textScaler,
    required this.disableAnimations,
    required this.startDrag,
    required this.onActivated,
    required this.onContentSize,
    required this.onOpenWorkspace,
    required this.onOpenSettings,
  });

  final WorkspaceBuddyController buddy;
  final double width;
  final ThemeData theme;
  final TextScaler textScaler;
  final bool disableAnimations;
  final VoidCallback? startDrag;
  final ValueChanged<bool> onActivated;

  /// The card's size after layout.  The window follows it, so a taller state
  /// grows the window instead of overflowing it.
  final ValueChanged<Size> onContentSize;
  final VoidCallback onOpenWorkspace;
  final Future<void> Function() onOpenSettings;

  @override
  State<BuddyWindowContent> createState() => _BuddyWindowContentState();
}

class _BuddyWindowContentState extends State<BuddyWindowContent> {
  final GlobalKey _cardKey = GlobalKey();
  Size? _reported;
  bool _scheduled = false;

  /// The card is laid out with an unbounded height inside the window's
  /// scroll view, so its own height is the one to make the window, not the
  /// viewport's.  Measure it after the frame, never during one.
  void _scheduleMeasure() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final size = box.size;
      if (size.width <= 0 || size.height <= 0) return;
      if (size == _reported) return;
      _reported = size;
      widget.onContentSize(size);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: widget.theme,
      color: Colors.transparent,
      builder: (context, child) {
        final data = MediaQuery.maybeOf(context) ?? const MediaQueryData();
        return MediaQuery(
          data: data.copyWith(
            textScaler: widget.textScaler,
            disableAnimations: widget.disableAnimations,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: widget.width,
          child: SingleChildScrollView(
            key: const Key('buddy-window-scroll'),
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _scheduleMeasure();
                return true;
              },
              child: SizeChangedLayoutNotifier(
                child: KeyedSubtree(
                  key: _cardKey,
                  child: _ActivatedReporter(
                    onChanged: widget.onActivated,
                    child: WorkspaceBuddy(
                      controller: widget.buddy,
                      onOpenWorkspace: widget.onOpenWorkspace,
                      onOpenSettings: () => unawaited(widget.onOpenSettings()),
                      onDragStart: widget.startDrag,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports whether the window this card is in is the active one.  The window
/// is asked not to activate, but a compositor may still give a click the
/// focus; the app must not hide the card when that happens.
class _ActivatedReporter extends StatefulWidget {
  const _ActivatedReporter({required this.onChanged, required this.child});

  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  State<_ActivatedReporter> createState() => _ActivatedReporterState();
}

class _ActivatedReporterState extends State<_ActivatedReporter> {
  bool? _reported;

  @override
  Widget build(BuildContext context) {
    // The scope is absent in a widget test, where the feature is off; the
    // real window always has one.
    final active = isWindowingEnabled &&
            (fw.WindowScope.maybeIsActivatedOf(context) ?? false);
    if (active != _reported) {
      _reported = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(active);
      });
    }
    return widget.child;
  }
}
