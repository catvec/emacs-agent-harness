// The buddy card's GTK window, handled directly.
//
// Flutter's windowing API hands out the GtkWindow it made, but it offers no
// way to colour outside its own window model: no frame policy, no place, no
// keep-above, no drag.  nativeapi's window object does expose those, but on
// this GTK 3 embedder several of them are requests the compositor may ignore
// (notably on Wayland) and one of them -- the frame -- can be had without the
// compositor's cooperation at all: a window with a titlebar of its own is
// drawn by GTK, and the window manager leaves its title bar off.  This file
// makes that titlebar zero-height and also keeps the size under the card's
// control instead of the platform's.
//
// Linux only: other platforms keep nativeapi's window object.
// ignore_for_file: implementation_imports
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The GTK 3 calls the buddy window needs, and nothing more.
///
/// Every method is a no-op on a platform without GTK, because the service
/// only makes one on Linux.  The window is a `GtkWindow*` from Flutter's
/// window controller.
class BuddyWindowGtk {
  BuddyWindowGtk(this.window) : _bindings = _Gtk3.instance;

  final ffi.Pointer<ffi.Void> window;
  final _Gtk3 _bindings;

  bool _framed = false;

  /// Whether this machine's GTK window manager draws a server-side frame
  /// itself, as opposed to GTK's own client-side one.
  static bool get isWayland =>
      (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

  /// Gives the window a client-side frame with a zero-height titlebar and no
  /// buttons: the compositor then has no title bar of its own to add, and the
  /// card's rounded surface is the only thing drawn.  GTK's shadow around the
  /// client-side frame stays, which is what a floating card wants.
  void makeFrameless() {
    if (_framed) return;
    _framed = true;
    final box = _bindings.gtkBoxNew(1 /* vertical */, 0);
    if (box == ffi.nullptr) return;
    final context = _bindings.gtkWidgetGetStyleContext(box);
    if (context != ffi.nullptr) {
      final provider = _bindings.gtkCssProviderNew();
      if (provider != ffi.nullptr) {
        final css =
            '''
.titlebar {
  min-height: 0px;
  padding: 0px;
  margin: 0px;
  border: none;
  background: transparent;
  box-shadow: none;
}
'''
                .toNativeUtf8();
        _bindings.gtkCssProviderLoadFromData(provider, css.cast(), -1, ffi.nullptr);
        malloc.free(css);
        // The style context holds its own reference.
        _bindings.gtkStyleContextAddProvider(context, provider, 600);
        _bindings.gObjectUnref(provider);
      }
    }
    _bindings.gtkWidgetShow(box);
    _bindings.gtkWindowSetTitlebar(window, box);
  }

  /// The window never takes the keyboard from what the person is doing; a
  /// compositor that ignores this still keeps the card usable, because the
  /// app's away rule does not depend on the card's window being inactive.
  void makeNonActivating() {
    _bindings.gtkWindowSetAcceptFocus(window, 0);
    _bindings.gtkWindowSetFocusOnMap(window, 0);
  }

  void hideFromTaskbar() {
    _bindings.gtkWindowSetSkipTaskbarHint(window, 1);
  }

  /// A request the compositor may ignore: X11 honours it, KWin's Wayland
  /// session does not (see [PlasmaWindowRules] for that session).
  void keepAbove(bool above) {
    _bindings.gtkWindowSetKeepAbove(window, above ? 1 : 0);
  }

  /// The card's width is fixed and its height follows the measured content.
  /// Toggling resizability lets a mapped window change width as well as
  /// height -- GTK ignores a width change on a window that is not resizable --
  /// and leaves it non-resizable between changes.
  void setSize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    _bindings.gtkWindowSetResizable(window, 1);
    _bindings.gtkWindowResize(window, width, height);
    _bindings.gtkWindowSetResizable(window, 0);
  }

  /// The window's client size, in GTK's own coordinates.
  (int, int) get size {
    final width = calloc<ffi.Int32>();
    final height = calloc<ffi.Int32>();
    try {
      _bindings.gtkWindowGetSize(window, width, height);
      return (width.value, height.value);
    } finally {
      calloc.free(width);
      calloc.free(height);
    }
  }

  void setResizable(bool resizable) {
    _bindings.gtkWindowSetResizable(window, resizable ? 1 : 0);
  }

  /// Places the card at the bottom right of the primary monitor's work area.
  /// A Wayland compositor places its clients itself and ignores the move;
  /// there the card keeps wherever the compositor put it until it is dragged.
  void placeBottomRight(int width, int height) {
    final display = _bindings.gdkDisplayGetDefault();
    if (display == ffi.nullptr) return;
    final monitor = _bindings.gdkDisplayGetPrimaryMonitor(display);
    if (monitor == ffi.nullptr) return;
    final area = calloc<_GdkRectangle>();
    try {
      _bindings.gdkMonitorGetWorkarea(monitor, area);
      final x = area.ref.x + area.ref.width - width - 16;
      final y = area.ref.y + area.ref.height - height - 16;
      if (x < area.ref.x) return;
      if (y < area.ref.y) return;
      _bindings.gtkWindowMove(window, x, y);
    } finally {
      calloc.free(area);
    }
  }

  void show() {
    _bindings.gtkWidgetShow(window);
  }

  void hide() {
    _bindings.gtkWidgetHide(window);
  }

  bool get isVisible => _bindings.gtkWidgetGetVisible(window) != 0;

  bool get isActive => _bindings.gtkWindowIsActive(window) != 0;

  /// Starts a compositor move from the pointer's current position: on
  /// Wayland xdg-shell's interactive move, on X11 the window manager's.
  void startDrag() {
    final time = _bindings.gtkGetCurrentEventTime();
    _bindings.gtkWindowBeginMoveDrag(window, 1, 0, 0, time);
  }

  /// Brings the app's own window forward, for the card's workspace and
  /// settings actions.  The card's window is the one that is not being
  /// presented; any other visible toplevel is the app.
  void presentMainWindow() {
    final list = _bindings.gtkWindowListToplevels();
    if (list == ffi.nullptr) return;
    ffi.Pointer<ffi.Void>? chosen;
    try {
      final count = _bindings.gListLength(list);
      for (var i = 0; i < count; i++) {
        final candidate = _bindings.gListNthData(list, i);
        if (candidate == ffi.nullptr || candidate == window) continue;
        if (_bindings.gtkWidgetGetVisible(candidate) == 0) continue;
        final title = _bindings.gtkWindowGetTitle(candidate);
        if (title != ffi.nullptr) {
          final text = title.cast<Utf8>().toDartString();
          if (text == 'Harness') {
            chosen = candidate;
            break;
          }
        }
        chosen ??= candidate;
      }
    } finally {
      _bindings.gListFree(list);
    }
    if (chosen != null) _bindings.gtkWindowPresent(chosen);
  }
}

/// The few GTK and GDK entry points above, resolved once.
class _Gtk3 {
  _Gtk3._() : _lib = ffi.DynamicLibrary.process();

  static final _Gtk3 instance = _Gtk3._();

  final ffi.DynamicLibrary _lib;

  late final void Function(ffi.Pointer<ffi.Void>) gtkWidgetShow = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('gtk_widget_show');

  late final void Function(ffi.Pointer<ffi.Void>) gtkWidgetHide = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('gtk_widget_hide');

  late final int Function(ffi.Pointer<ffi.Void>) gtkWidgetGetVisible = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)>('gtk_widget_get_visible');

  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
  gtkWidgetGetStyleContext = _lib.lookupFunction<
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
  >('gtk_widget_get_style_context');

  late final ffi.Pointer<ffi.Void> Function(int, int) gtkBoxNew = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Int32, ffi.Int32),
          ffi.Pointer<ffi.Void> Function(int, int)>('gtk_box_new');

  late final ffi.Pointer<ffi.Void> Function() gtkCssProviderNew = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(),
          ffi.Pointer<ffi.Void> Function()>('gtk_css_provider_new');

  late final int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Char>,
    int,
    ffi.Pointer<ffi.Void>,
  )
  gtkCssProviderLoadFromData = _lib.lookupFunction<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.IntPtr,
      ffi.Pointer<ffi.Void>,
    ),
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      int,
      ffi.Pointer<ffi.Void>,
    )
  >('gtk_css_provider_load_from_data');

  late final void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    int,
  )
  gtkStyleContextAddProvider = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Uint32),
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, int)
  >('gtk_style_context_add_provider');

  late final void Function(ffi.Pointer<ffi.Void>) gObjectUnref = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('g_object_unref');

  late final void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
  )
  gtkWindowSetTitlebar = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
  >('gtk_window_set_titlebar');

  late final void Function(ffi.Pointer<ffi.Void>, int) gtkWindowSetAcceptFocus =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int)
      >('gtk_window_set_accept_focus');

  late final void Function(ffi.Pointer<ffi.Void>, int) gtkWindowSetFocusOnMap =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int)
      >('gtk_window_set_focus_on_map');

  late final void Function(ffi.Pointer<ffi.Void>, int)
  gtkWindowSetSkipTaskbarHint = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32),
    void Function(ffi.Pointer<ffi.Void>, int)
  >('gtk_window_set_skip_taskbar_hint');

  late final void Function(ffi.Pointer<ffi.Void>, int) gtkWindowSetKeepAbove =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int)
      >('gtk_window_set_keep_above');

  late final void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
  )
  gtkWindowGetSize = _lib.lookupFunction<
    ffi.Void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
    ),
    void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
    )
  >('gtk_window_get_size');

  late final void Function(ffi.Pointer<ffi.Void>, int) gtkWindowSetResizable =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int)
      >('gtk_window_set_resizable');

  late final void Function(ffi.Pointer<ffi.Void>, int, int) gtkWindowResize =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int, int)
      >('gtk_window_resize');

  late final void Function(ffi.Pointer<ffi.Void>, int, int) gtkWindowMove =
      _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32),
        void Function(ffi.Pointer<ffi.Void>, int, int)
      >('gtk_window_move');

  late final void Function(ffi.Pointer<ffi.Void>) gtkWindowPresent = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('gtk_window_present');

  late final int Function(ffi.Pointer<ffi.Void>) gtkWindowIsActive = _lib
      .lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)>('gtk_window_is_active');

  late final void Function(
    ffi.Pointer<ffi.Void>,
    int,
    int,
    int,
    int,
  )
  gtkWindowBeginMoveDrag = _lib.lookupFunction<
    ffi.Void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Uint32,
    ),
    void Function(ffi.Pointer<ffi.Void>, int, int, int, int)
  >('gtk_window_begin_move_drag');

  late final int Function() gtkGetCurrentEventTime = _lib.lookupFunction<
    ffi.Uint32 Function(),
    int Function()
  >('gtk_get_current_event_time');

  late final ffi.Pointer<ffi.Void> Function() gtkWindowListToplevels = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(),
          ffi.Pointer<ffi.Void> Function()>('gtk_window_list_toplevels');

  late final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)
  gtkWindowGetTitle = _lib.lookupFunction<
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>),
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)
  >('gtk_window_get_title');

  late final ffi.Pointer<ffi.Void> Function() gdkDisplayGetDefault = _lib
      .lookupFunction<ffi.Pointer<ffi.Void> Function(),
          ffi.Pointer<ffi.Void> Function()>('gdk_display_get_default');

  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
  gdkDisplayGetPrimaryMonitor = _lib.lookupFunction<
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
  >('gdk_display_get_primary_monitor');

  late final void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_GdkRectangle>)
  gdkMonitorGetWorkarea = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_GdkRectangle>),
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_GdkRectangle>)
  >('gdk_monitor_get_workarea');

  late final int Function(ffi.Pointer<ffi.Void>) gListLength = _lib
      .lookupFunction<ffi.Uint32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)>('g_list_length');

  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
  gListNthData = _lib.lookupFunction<
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int)
  >('g_list_nth_data');

  late final void Function(ffi.Pointer<ffi.Void>) gListFree = _lib
      .lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('g_list_free');
}

final class _GdkRectangle extends ffi.Struct {
  @ffi.Int32()
  external int x;

  @ffi.Int32()
  external int y;

  @ffi.Int32()
  external int width;

  @ffi.Int32()
  external int height;
}
