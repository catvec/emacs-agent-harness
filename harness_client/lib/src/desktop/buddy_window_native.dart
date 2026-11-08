// The desktop buddy's own window.  Flutter's windowing API is still marked
// experimental; this file uses it on purpose, and is the only place that
// does.  See docs/design/workspace-voice-buddy.md.
//
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart' as fw;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' as na;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' hide WindowManager;
import 'package:nativeapi_flutter/windowing.dart';

import '../state/workspace_buddy_controller.dart';
import 'buddy_window.dart';

/// Opens a buddy window on a desktop that can have one.  A platform with no
/// windowing support, or a run that asked for the in-app card, gets the
/// fallback service instead.
BuddyWindowService createBuddyWindowService() {
  if (!isWindowingEnabled) {
    return UnsupportedBuddyWindowService();
  }
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
    return UnsupportedBuddyWindowService();
  }
  // A support switch for a machine whose compositor cannot draw a
  // non-activating window: the in-app card is used instead.
  if (Platform.environment['HARNESS_BUDDY_WINDOW'] == 'off') {
    return UnsupportedBuddyWindowService();
  }
  return _NativeBuddyWindowService();
}

/// One regular window of the app's engine, styled as a floating card.
///
/// The window is kept between shows, so the buddy comes back where it was
/// left and its next appearance does not pay for a new view.  It is
/// destroyed when the call's controller is destroyed or another controller
/// takes its place.
class _NativeBuddyWindowService implements BuddyWindowService {
  _NativeBuddyWindowService() {
    try {
      _mainWindow = na.WindowManager.instance.getCurrent();
    } catch (error) {
      debugPrint('Harness: could not find the main window: $error');
    }
    _delegate = _BuddyWindowDelegate(
      onClose: () => _window?.hide(),
      onDestroyed: _windowDestroyed,
    );
  }

  final _available = ValueNotifier<bool>(true);
  final _activated = ValueNotifier<bool>(false);

  late final _BuddyWindowDelegate _delegate;

  fw.RegularWindowController? _controller;
  fw.WindowRegistry? _registry;
  fw.WindowEntry? _entry;
  na.Window? _window;
  na.Window? _mainWindow;
  WorkspaceBuddyController? _boundTo;
  BuddyWindowRequest? _request;
  double _width = 0;
  bool _placed = false;
  bool _destroying = false;
  bool _disposed = false;

  @override
  ValueListenable<bool> get available => _available;

  @override
  bool get isActivated => _controller?.isActivated ?? _activated.value;

  @override
  ValueListenable<bool> get activated => _activated;

  @override
  void reportActivated(bool active) {
    if (_disposed) return;
    if (_activated.value != active) _activated.value = active;
  }

  @override
  Widget wrap(Widget child) => fw.WindowManager(child: child);

  @override
  void show(BuildContext context, BuddyWindowRequest request) {
    if (_disposed || !_available.value) return;
    try {
      final sameCall =
          _controller != null && identical(request.controller, _boundTo);
      if (_controller != null && !sameCall) {
        _destroyWindow();
      }
      _request = request;
      if (_controller == null) {
        _createWindow(context, request);
      } else if (request.width != _width) {
        _width = request.width;
        _controller?.setConstraints(_constraintsFor(request.width));
      }
      _window?.showInactive();
    } catch (error) {
      debugPrint('Harness: could not open the buddy window: $error');
      _fallBack();
    }
  }

  void _createWindow(BuildContext context, BuddyWindowRequest request) {
    final registry = fw.WindowRegistry.maybeOf(context);
    if (registry == null) {
      throw StateError('the app has no window registry');
    }
    final controller = fw.RegularWindowController.sizedToContent(
      constraints: _constraintsFor(request.width),
      title: 'Buddy',
      delegate: _delegate,
    );
    final window = controller.nativeWindow;
    if (window == null) {
      controller.destroy();
      throw StateError('the platform gave no native window');
    }
    _controller = controller;
    _registry = registry;
    _window = window;
    _boundTo = request.controller;
    _width = request.width;
    _style(window);
    final entry = fw.WindowEntry(
      controller: controller,
      // The request is read when the window is built, not captured: a later
      // width or controller takes effect in the same view.
      builder: (context) =>
          _request?.builder(context, _startDrag) ?? const SizedBox.shrink(),
    );
    _entry = entry;
    registry.register(entry);
    _placeWhenReady();
  }

  /// The card's width is fixed; its height follows the content.
  BoxConstraints _constraintsFor(double width) => BoxConstraints(
    minWidth: width,
    maxWidth: width,
    minHeight: 120,
    maxHeight: 720,
  );

  void _style(na.Window window) {
    window.setFrameless(true);
    window.isAlwaysOnTop = true;
    window.isVisibleInTaskbar = false;
    // The whole point of the window: a click or a drag stays a click or a
    // drag.  It does not bring the app forward, and it does not take the
    // keyboard from whatever the person is working in.
    window.isNonActivating = true;
    window.isFocusable = false;
    window.isResizable = false;
    window.hasShadow = true;
    window.backgroundColor = const Color(0x00000000).toNative();
  }

  void _startDrag() {
    try {
      _window?.startDragging();
    } catch (error) {
      debugPrint('Harness: could not drag the buddy window: $error');
    }
  }

  /// The first placement is bottom-right of the primary display's work
  /// area.  After that the window keeps wherever the person dragged it; a
  /// compositor that does not allow placing a window chooses for it.
  void _placeWhenReady() {
    if (_placed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (_disposed || _window == null) return;
          _placeBottomRight();
          _placed = true;
        }),
      );
    });
  }

  void _placeBottomRight() {
    final window = _window;
    if (window == null) return;
    try {
      final display = na.DisplayManager.instance.getPrimary();
      final area = display?.workArea.toRect();
      if (area == null) return;
      final size = window.size.toSize();
      if (size.width <= 0 || size.height <= 0) return;
      window.position = Offset(
        area.right - size.width - 16,
        area.bottom - size.height - 16,
      ).toNative();
    } catch (error) {
      // A compositor that does not let an app place a window is not a
      // failure: it will place the card itself.
      debugPrint('Harness: could not place the buddy window: $error');
    }
  }

  @override
  void hide() {
    try {
      _window?.hide();
    } catch (error) {
      debugPrint('Harness: could not hide the buddy window: $error');
    }
    reportActivated(false);
  }

  @override
  void destroy() => _destroyWindow();

  void _destroyWindow() {
    if (_destroying) return;
    _destroying = true;
    final entry = _entry;
    final registry = _registry;
    final controller = _controller;
    _entry = null;
    _registry = null;
    _controller = null;
    _window = null;
    _boundTo = null;
    _request = null;
    _width = 0;
    _placed = false;
    reportActivated(false);
    try {
      if (entry != null && registry != null) registry.unregister(entry);
    } catch (_) {}
    try {
      controller?.destroy();
    } catch (_) {}
    _destroying = false;
  }

  void _windowDestroyed() {
    if (_destroying) return;
    // The compositor took the window away.  Let the card be made again when
    // it is next wanted.
    _entry = null;
    _registry = null;
    _controller = null;
    _window = null;
    _boundTo = null;
    _request = null;
    _width = 0;
    _placed = false;
    reportActivated(false);
  }

  /// A window that cannot be made leaves the persistent in-app card as the
  /// surface.  It stays while the buddy is on, because an away-only card in
  /// the window cannot be clicked without the click hiding it.
  void _fallBack() {
    _destroyWindow();
    if (_disposed) return;
    if (_available.value) _available.value = false;
  }

  @override
  void presentMainWindow() {
    try {
      final window =
          _mainWindow ?? na.WindowManager.instance.getCurrent();
      _mainWindow = window;
      window?.show();
      window?.focus();
    } catch (error) {
      debugPrint('Harness: could not present the main window: $error');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroyWindow();
    _available.dispose();
    _activated.dispose();
  }
}

/// A close request hides the buddy instead of destroying its window; a
/// destroy from the compositor is reported so the service can forget it.
class _BuddyWindowDelegate extends fw.RegularWindowControllerDelegate {
  _BuddyWindowDelegate({required this.onClose, required this.onDestroyed});

  final VoidCallback onClose;
  final VoidCallback onDestroyed;

  @override
  void onWindowCloseRequested(fw.RegularWindowController controller) {
    onClose();
  }

  @override
  void onWindowDestroyed() {
    onDestroyed();
  }
}
