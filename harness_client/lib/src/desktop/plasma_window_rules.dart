// Keeps the buddy card above other windows on a KDE Plasma Wayland session.
//
// A Wayland client cannot ask for "keep above" or "skip taskbar": xdg-shell
// has no such state, and KWin ignores the X11 hints GTK sends.  KWin does
// expose its own window properties through the scripting interface, so the
// card's own window can be given the two properties with a small script.
// The script matches the app's pid and the card's caption, so it can touch
// no other window; it is unloaded when the card is disposed.
//
// This is the Plasma fix for a platform limit, not a general one: other
// compositors have no equivalent, and there the card stays a normal window.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// The Plasma scripting interface, as far as this client uses it.
class PlasmaWindowRules {
  PlasmaWindowRules({
    required this.pid,
    required this.caption,
    DBusClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? DBusClient.session;

  /// The process whose window the rules apply to.
  final int pid;

  /// The window's caption.  KWin's scripting sees the title GTK gives it.
  final String caption;

  final DBusClient Function() _clientFactory;

  DBusClient? _client;
  String? _pluginName;
  int? _scriptId;
  Directory? _directory;
  bool _disposed = false;

  /// Whether this is a Plasma Wayland session, where the rules can work.
  static bool get isSupported {
    if (!Platform.isLinux) return false;
    if ((Platform.environment['WAYLAND_DISPLAY'] ?? '').isEmpty) return false;
    final desktop = (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '')
        .toLowerCase();
    return desktop.contains('kde') || desktop.contains('plasma');
  }

  /// The script KWin runs.  It is a pure function of [pid] and [caption], so
  /// a test can read it without a window manager.
  static String scriptFor({required int pid, required String caption}) {
    final title = jsonEncode(caption);
    return '''
// Installed by the Harness client for its buddy card.  It touches only the
// window whose process and caption match, and nothing else.
var harnessPid = $pid;
var harnessCaption = $title;
function harnessBuddy(w) {
  if (!w || w.pid !== harnessPid || w.caption !== harnessCaption) return;
  w.keepAbove = true;
  w.skipTaskbar = true;
  w.noBorder = true;
}
workspace.windowList().forEach(harnessBuddy);
workspace.windowAdded.connect(harnessBuddy);
''';
  }

  /// Loads and runs the script.  A session without KWin scripting (or a
  /// D-Bus that refuses the call) leaves the card working, just without the
  /// extra properties; it is not an error the person needs to see.
  Future<void> install() async {
    if (_disposed || _scriptId != null || !isSupported) return;
    try {
      final directory = await Directory.systemTemp.createTemp('harness-buddy-');
      _directory = directory;
      final file = File('${directory.path}/buddy-window.js');
      await file.writeAsString(
        scriptFor(pid: pid, caption: caption),
        flush: true,
      );
      final pluginName = 'harness-buddy-$pid';
      final client = _clientFactory();
      _client = client;
      final loaded = await client.callMethod(
        destination: 'org.kde.KWin',
        path: DBusObjectPath('/Scripting'),
        interface: 'org.kde.kwin.Scripting',
        name: 'loadScript',
        values: [DBusString(file.path), DBusString(pluginName)],
        replySignature: DBusSignature('i'),
      );
      final id = loaded.returnValues.first.asInt32();
      if (id < 0) {
        throw StateError('KWin already has a buddy script');
      }
      _pluginName = pluginName;
      _scriptId = id;
      // The card may have been disposed while the script loaded; unload it
      // now instead of running a script nothing will unload.
      if (_disposed) {
        await _close();
        return;
      }
      await client.callMethod(
        destination: 'org.kde.KWin',
        path: DBusObjectPath('/Scripting/Script$id'),
        interface: 'org.kde.kwin.Script',
        name: 'run',
        replySignature: DBusSignature(''),
      );
    } catch (error) {
      debugPrint('Harness: no Plasma window rules for the buddy: $error');
      await _close();
    }
  }

  Future<void> _close() async {
    final client = _client;
    final pluginName = _pluginName;
    _client = null;
    _pluginName = null;
    _scriptId = null;
    if (client != null) {
      if (pluginName != null) {
        try {
          await client.callMethod(
            destination: 'org.kde.KWin',
            path: DBusObjectPath('/Scripting'),
            interface: 'org.kde.kwin.Scripting',
            name: 'unloadScript',
            values: [DBusString(pluginName)],
            replySignature: DBusSignature('b'),
          );
        } catch (_) {}
      }
      try {
        await client.close();
      } catch (_) {}
    }
    final directory = _directory;
    _directory = null;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _close();
  }
}
