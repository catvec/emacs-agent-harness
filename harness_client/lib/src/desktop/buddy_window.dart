import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../state/workspace_buddy_controller.dart';
import 'buddy_window_unsupported.dart'
    if (dart.library.io) 'buddy_window_native.dart' as implementation;

/// Builds the compact card for the native buddy window.
///
/// [startDrag] moves the whole window: the card's header is the window's
/// title bar when it has one.  It is null where a native window cannot be
/// dragged.
typedef BuddyWindowContentBuilder =
    Widget Function(BuildContext context, VoidCallback? startDrag);

/// What one native buddy window draws: the workspace call it belongs to, the
/// width the card asked for, and the builder for its view.
@immutable
class BuddyWindowRequest {
  const BuddyWindowRequest({
    required this.controller,
    required this.width,
    required this.builder,
  });

  final WorkspaceBuddyController controller;

  /// The card's width at the current text scale, in logical pixels.
  final double width;

  final BuddyWindowContentBuilder builder;
}

/// The desktop buddy's own window, when the platform can open one.
///
/// The window is a second view of the same engine and the same
/// [WorkspaceBuddyController]: it is not a second app, a second call or a
/// state copy.  It is always-on-top, undecorated, absent from the taskbar
/// and non-activating, so pressing a control or dragging its header neither
/// focuses the app's main window nor makes the card disappear.
///
/// The app falls back to the in-app card when no native window can be opened
/// ([available] is false).  That card stays on screen while the buddy is on:
/// an away-only in-app card cannot be clicked without the click bringing the
/// app forward and hiding it again.
abstract class BuddyWindowService {
  /// Whether the native buddy window can be opened on this device.  It turns
  /// false for the rest of the run if opening one fails.
  ValueListenable<bool> get available;

  /// Whether the buddy window itself is the active one.  A compositor may
  /// give a click on it the focus even though the window asks not to; while
  /// it is active the app's main window is not the one in use, so the card
  /// must stay rather than hide itself under the pointer.
  bool get isActivated;

  /// Notifies when [isActivated] changes, so the host can look again.
  ValueListenable<bool> get activated;

  /// The card in the window reports its activation here.
  void reportActivated(bool active);

  /// Wraps the app in whatever provides the native window registry.  It is
  /// the child itself where no native window is possible.
  Widget wrap(Widget child);

  /// Opens (or reuses) the buddy window and shows it without taking focus.
  void show(BuildContext context, BuddyWindowRequest request);

  /// Hides the buddy window, keeping it ready to be shown again.
  void hide();

  /// Unregisters and destroys the buddy window.
  void destroy();

  /// Brings the app's main window to the front, for the card's workspace
  /// and settings actions.
  void presentMainWindow();

  void dispose();
}

/// The platform's way of opening a buddy window, if it has one.
BuddyWindowService createBuddyWindowService() =>
    implementation.createBuddyWindowService();

/// A service for a platform with no native buddy window: the persistent
/// in-app card is the only surface.
class UnsupportedBuddyWindowService implements BuddyWindowService {
  final ValueNotifier<bool> _available = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _activated = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get available => _available;

  @override
  bool get isActivated => _activated.value;

  @override
  ValueListenable<bool> get activated => _activated;

  @override
  void reportActivated(bool active) {}

  @override
  Widget wrap(Widget child) => child;

  @override
  void show(BuildContext context, BuddyWindowRequest request) {}

  @override
  void hide() {}

  @override
  void destroy() {}

  @override
  void presentMainWindow() {}

  @override
  void dispose() {
    _available.dispose();
    _activated.dispose();
  }
}
