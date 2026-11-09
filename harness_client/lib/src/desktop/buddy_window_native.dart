// The desktop buddy's own window.  Flutter's windowing API is still marked
// experimental; this file uses it on purpose, and is the only place that
// does.  See docs/design/workspace-voice-buddy.md.
//
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// The Flutter windowing API keeps the native GtkWindow handle here.
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart' as fw;
import 'package:flutter/src/widgets/_window_linux.dart' as fw_linux;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' as na;
import 'package:nativeapi_flutter/nativeapi_flutter.dart' hide WindowManager;
import 'package:nativeapi_flutter/windowing.dart';

import '../state/workspace_buddy_controller.dart';
import 'buddy_window.dart';
import 'buddy_window_linux.dart';
import 'plasma_window_rules.dart';

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
///
/// On Linux the card is the window's content from corner to corner: the
/// window's frame is client-side and zero-height (see [BuddyWindowGtk]), its
/// size follows the card in [reportContentSize], and a Plasma session gives
/// it keep-above through KWin's own rules.  Other desktops honour the
/// window properties where their compositors allow it; the card is still
/// usable where they do not, because the app never relies on the window
/// manager to decide visibility.
class _NativeBuddyWindowService implements BuddyWindowService {
  _NativeBuddyWindowService() {
    try {
      _mainWindow = na.WindowManager.instance.getCurrent();
    } catch (error) {
      debugPrint('Harness: could not find the main window: $error');
    }
    _delegate = _BuddyWindowDelegate(
      onClose: hide,
      onDestroyed: _windowDestroyed,
    );
  }

  /// The height a window has before its card has been measured.  The card's
  /// first layout reports its real height, and the window follows it.
  static const double _initialHeight = 120;
  static const double _minHeight = 120;
  static const double _maxHeight = 720;

  final _available = ValueNotifier<bool>(true);
  final _activated = ValueNotifier<bool>(false);

  late final _BuddyWindowDelegate _delegate;

  fw.RegularWindowController? _controller;
  fw.WindowRegistry? _registry;
  fw.WindowEntry? _entry;
  na.Window? _window;
  na.Window? _mainWindow;
  BuddyWindowGtk? _gtk;
  PlasmaWindowRules? _plasma;
  WorkspaceBuddyController? _boundTo;
  BuddyWindowRequest? _request;
  double _width = 0;
  Size _contentSize = Size.zero;
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
        _resizeToCard();
      }
      _showWindow();
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
    // On Linux the window's size belongs to the card: the fixed-size
    // constructor gives it the card's width and a provisional height, and
    // [reportContentSize] replaces the height with the one the card asks
    // for.  Flutter's sized-to-content window is still the right thing on
    // the platforms where it works.
    final controller = Platform.isLinux
        ? fw.RegularWindowController(
            size: Size(request.width, _initialHeight),
            constraints: _constraintsFor(request.width),
            title: 'Buddy',
            delegate: _delegate,
          )
        : fw.RegularWindowController.sizedToContent(
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
    _styleWindow(controller, window);
    final entry = fw.WindowEntry(
      controller: controller,
      // The request is read when the window is built, not captured: a later
      // width or controller takes effect in the same view.
      builder: (context) =>
          _request?.builder(context, _startDrag) ?? const SizedBox.shrink(),
    );
    _entry = entry;
    registry.register(entry);
    _installPlasmaRules();
    if (!Platform.isLinux) _placeWhenReady();
  }

  /// The card's width is fixed; its height follows the content.
  BoxConstraints _constraintsFor(double width) => BoxConstraints(
    minWidth: width,
    maxWidth: width,
    minHeight: _minHeight,
    maxHeight: _maxHeight,
  );

  void _styleWindow(fw.RegularWindowController controller, na.Window window) {
    if (Platform.isLinux) {
      final handle = _linuxHandle(controller);
      if (handle != null) {
        final gtk = BuddyWindowGtk(handle);
        _gtk = gtk;
        gtk.makeFrameless();
        gtk.makeNonActivating();
        gtk.hideFromTaskbar();
        gtk.setResizable(false);
        // X11 honours this; Wayland leaves it to the compositor, and Plasma
        // gets its keep-above from the KWin rules instead.
        gtk.keepAbove(true);
        return;
      }
    }
    _style(window);
  }

  /// The GtkWindow behind Flutter's own window controller.
  static ffi.Pointer<ffi.Void>? _linuxHandle(
    fw.RegularWindowController controller,
  ) {
    if (controller is! fw_linux.WindowControllerLinux) return null;
    try {
      return (controller as fw_linux.WindowControllerLinux).windowHandle;
    } catch (error) {
      debugPrint('Harness: could not reach the buddy window: $error');
      return null;
    }
  }

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

  void _installPlasmaRules() {
    if (_disposed || !Platform.isLinux) return;
    if (!PlasmaWindowRules.isSupported) return;
    final rules = PlasmaWindowRules(pid: pid, caption: 'Buddy');
    _plasma = rules;
    unawaited(rules.install());
  }

  @override
  void reportContentSize(Size size) {
    // Other platforms keep Flutter's sized-to-content window: only the Linux
    // window is sized here, because it is the one the platform does not size.
    if (!Platform.isLinux) return;
    if (_disposed || _controller == null) return;
    // A first frame with no laid-out card is not a size to follow.
    if (size.width < 80 || size.height < 40) return;
    final width = _width.roundToDouble();
    final height = size.height.clamp(_minHeight, _maxHeight).roundToDouble();
    if (height == _contentSize.height && width == _contentSize.width) {
      _schedulePlacement();
      return;
    }
    _contentSize = Size(width, height);
    _resizeToCard();
    _schedulePlacement();
  }

  /// The window follows the card: the card's width, and the height it asked
  /// for.  A card taller than the window's maximum scrolls inside it.
  void _resizeToCard() {
    if (_disposed || _controller == null) return;
    // macOS and Windows use Flutter's sized-to-content window; only the
    // Linux window is sized here.
    if (!Platform.isLinux) return;
    final height = _contentSize.height > 0
        ? _contentSize.height.round()
        : _initialHeight.round();
    try {
      if (_gtk case final gtk?) {
        gtk.setSize(_width.round(), height);
      } else {
        _controller?.setSize(
          Size(_width, height.toDouble()),
        );
      }
    } catch (error) {
      debugPrint('Harness: could not size the buddy window: $error');
    }
  }

  void _showWindow() {
    final gtk = _gtk;
    if (gtk != null) {
      _resizeToCard();
      gtk.show();
      // A window that is being mapped can ignore a resize until the
      // compositor has configured it; the card's own height is applied
      // again after that first configure.
      _resizeAfterMap();
      return;
    }
    _window?.showInactive();
  }

  void _resizeAfterMap() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (_disposed) return;
          _resizeToCard();
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 160), () {
              if (!_disposed) _resizeToCard();
            }),
          );
        }),
      );
    });
  }

  void _schedulePlacement() {
    if (_placed || _disposed) return;
    if (_gtk == null) return;
    _placed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (_disposed || _gtk == null) return;
          final height = _contentSize.height > 0
              ? _contentSize.height.round()
              : _initialHeight.round();
          _gtk!.placeBottomRight(_width.round(), height);
        }),
      );
    });
  }

  void _startDrag() {
    final gtk = _gtk;
    if (gtk != null) {
      gtk.startDrag();
      return;
    }
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
    final gtk = _gtk;
    if (gtk != null) {
      gtk.hide();
      reportActivated(false);
      return;
    }
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
    final plasma = _plasma;
    _entry = null;
    _registry = null;
    _controller = null;
    _window = null;
    _gtk = null;
    _plasma = null;
    _boundTo = null;
    _request = null;
    _width = 0;
    _contentSize = Size.zero;
    _placed = false;
    reportActivated(false);
    try {
      if (entry != null && registry != null) registry.unregister(entry);
    } catch (_) {}
    try {
      controller?.destroy();
    } catch (_) {}
    if (plasma != null) unawaited(plasma.dispose());
    _destroying = false;
  }

  void _windowDestroyed() {
    if (_destroying) return;
    // The compositor took the window away.  Let the card be made again when
    // it is next wanted.
    final plasma = _plasma;
    _entry = null;
    _registry = null;
    _controller = null;
    _window = null;
    _gtk = null;
    _plasma = null;
    _boundTo = null;
    _request = null;
    _width = 0;
    _contentSize = Size.zero;
    _placed = false;
    reportActivated(false);
    if (plasma != null) unawaited(plasma.dispose());
  }

  /// A window that cannot be made leaves the persistent in-app card as the
  /// surface.  It stays while the buddy is on and the workspace has a call,
  /// because an away-only card in the window cannot be clicked without the
  /// click hiding it.
  void _fallBack() {
    _destroyWindow();
    if (_disposed) return;
    if (_available.value) _available.value = false;
  }

  @override
  void presentMainWindow() {
    final gtk = _gtk;
    if (gtk != null) {
      gtk.presentMainWindow();
      return;
    }
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
