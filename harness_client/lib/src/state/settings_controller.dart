import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PreviewPlatform { system, material, cupertino }

/// Local preferences, and what this device remembers of the harness it signed
/// in to: its address and the session secret the harness gave it.  The secret
/// is kept only when "Remember" is on; it is the device's own session, which
/// the harness can end, not an account password.
///
/// What is remembered is what lets the app open on its harness without asking
/// for anything again: see [canResume].
class SettingsController extends ChangeNotifier {
  SettingsController({SharedPreferences? preferences}) : _prefs = preferences;

  SharedPreferences? _prefs;
  ThemeMode _themeMode = ThemeMode.system;
  PreviewPlatform _previewPlatform = PreviewPlatform.system;
  bool _showThinking = true;
  bool _rememberConnection = true;
  bool _reconnectOnLaunch = true;
  String _address = '';
  String _token = '';
  bool _loaded = false;
  Object? _loadError;

  /// Whether the address and secret, or [reconnectOnLaunch], were set or
  /// forgotten since the app started: what [load] reads late must not
  /// overwrite them.
  bool _detailsChanged = false;
  bool _flagChanged = false;

  /// Completes once [load] is over, whether or not the store answered.
  final Completer<void> _ready = Completer<void>();

  /// The writes of the connection details, one after the other.  Each writes
  /// the details as they are *when it runs*, so the last thing set is what
  /// ends up on the device, whatever order the platform finishes its writes
  /// in.  (Two saves that overlapped used to be able to leave the older
  /// secret behind, which the harness no longer honours: the next launch
  /// would have had to sign in again.)
  late Future<void> _saving = _ready.future;

  ThemeMode get themeMode => _themeMode;
  PreviewPlatform get previewPlatform => _previewPlatform;
  bool get showThinking => _showThinking;
  bool get rememberConnection => _rememberConnection;

  /// Whether the app connects again by itself when it opens.  It does, unless
  /// the person left the harness on purpose ("Disconnect"): that is
  /// remembered too, and a new connection makes it true again.
  bool get reconnectOnLaunch => _reconnectOnLaunch;
  String get address => _address;
  String get token => _token;
  bool get loaded => _loaded;

  /// Whether the app should connect by itself when it opens, with the
  /// address and secret kept here: the device was told to remember a harness,
  /// knows where it is, and did not leave it on purpose.  A device that
  /// signed in thus opens on its sessions, not on a form; it is asked for
  /// something only when the harness asks.
  bool get canResume =>
      _loaded &&
      _rememberConnection &&
      _reconnectOnLaunch &&
      _address.isNotEmpty;

  /// Whether settings can be written back.  False when the platform's
  /// preference store could not be reached; the app keeps working with its
  /// defaults and simply does not remember anything.
  bool get persistenceAvailable => _prefs != null;

  /// Why the stored values could not be read, when [loaded] is true but the
  /// platform store failed.
  Object? get loadError => _loadError;

  bool get useCupertino => switch (_previewPlatform) {
    PreviewPlatform.cupertino => true,
    PreviewPlatform.material => false,
    PreviewPlatform.system =>
      defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS,
  };

  Future<void> load() async {
    if (_loaded) return;
    try {
      _prefs ??= await SharedPreferences.getInstance();
    } catch (error) {
      // A missing, blocked or broken preference store only means the client
      // cannot remember the connection.  It must not keep the app from
      // starting, so fall back to the in-memory defaults.
      _loadError = error;
      _prefs = null;
      debugPrint('Harness: local settings are unavailable: $error');
    }
    final prefs = _prefs;
    if (prefs != null) {
      try {
        _themeMode = switch (prefs.getString('themeMode')) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        _previewPlatform = switch (prefs.getString('previewPlatform')) {
          'material' => PreviewPlatform.material,
          'cupertino' => PreviewPlatform.cupertino,
          _ => PreviewPlatform.system,
        };
        _showThinking = prefs.getBool('showThinking') ?? true;
        _rememberConnection = prefs.getBool('rememberConnection') ?? true;
        // A store that answers late must not undo a connection made meanwhile.
        if (!_detailsChanged) {
          _address = prefs.getString('address') ?? '';
          _token = prefs.getString('token') ?? '';
        }
        if (!_flagChanged) {
          _reconnectOnLaunch = prefs.getBool('reconnectOnLaunch') ?? true;
        }
      } catch (error) {
        // Corrupt or unreadable values: keep the defaults above and go on.
        _loadError = error;
        debugPrint('Harness: local settings could not be read: $error');
      }
    }
    _loaded = true;
    if (!_ready.isCompleted) _ready.complete();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _setString('themeMode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> setPreviewPlatform(PreviewPlatform platform) async {
    _previewPlatform = platform;
    notifyListeners();
    await _setString('previewPlatform', switch (platform) {
      PreviewPlatform.system => 'system',
      PreviewPlatform.material => 'material',
      PreviewPlatform.cupertino => 'cupertino',
    });
  }

  Future<void> setShowThinking(bool value) async {
    _showThinking = value;
    notifyListeners();
    await _setBool('showThinking', value);
  }

  /// Turn remembering the harness on or off.  Off forgets what was kept; on
  /// keeps the connection the app has now, if it has one.
  Future<void> setRememberConnection(bool value) async {
    _rememberConnection = value;
    notifyListeners();
    await _setBool('rememberConnection', value);
    if (value) {
      await _saveConnection();
    } else {
      await clearConnection();
    }
  }

  /// Keep the address of the harness this device is signed in to and the
  /// session [token] it holds, and that the app goes back in by itself when
  /// it opens next.  Called each time a connection is made, and again when
  /// the harness replaces the secret.
  Future<void> rememberConnectionDetails(String address, String token) {
    _detailsChanged = _flagChanged = true;
    _address = address;
    _token = token;
    _reconnectOnLaunch = true;
    notifyListeners();
    return _saveConnection();
  }

  /// Keep, or not, that the app connects again by itself when it opens: the
  /// person leaves the harness on purpose, so it waits to be told to connect
  /// (and a new connection makes it true again).
  Future<void> setReconnectOnLaunch(bool value) {
    _flagChanged = true;
    _reconnectOnLaunch = value;
    return _saveConnection();
  }

  /// Forget the address and secret, as signing out and turning "Remember"
  /// off do.
  Future<void> clearConnection() {
    _detailsChanged = _flagChanged = true;
    _address = '';
    _token = '';
    _reconnectOnLaunch = true;
    notifyListeners();
    return _enqueue(() async {
      await _remove('address');
      await _remove('token');
      await _remove('reconnectOnLaunch');
    });
  }

  Future<void> _saveConnection() => _enqueue(() async {
    // Read here, when the write runs: see [_saving].
    if (!_rememberConnection || _address.isEmpty) return;
    await _setString('address', _address);
    await _setString('token', _token);
    await _setBool('reconnectOnLaunch', _reconnectOnLaunch);
  });

  /// Run [write] after the writes before it, and after [load] is over: a
  /// connection made while the store was still being read is kept once it
  /// can be.
  Future<void> _enqueue(Future<void> Function() write) {
    final done = _saving.then((_) => write());
    // The next write goes on even if this one fails (they do not throw).
    _saving = done.catchError((Object _) {});
    return done;
  }

  /// Persistence is best-effort.  A write that fails or a store that never
  /// answers must not take the caller down with it.
  Future<void> _setString(String key, String value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setString(key, value);
    } catch (error) {
      debugPrint('Harness: could not save "$key": $error');
    }
  }

  Future<void> _setBool(String key, bool value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setBool(key, value);
    } catch (error) {
      debugPrint('Harness: could not save "$key": $error');
    }
  }

  Future<void> _remove(String key) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.remove(key);
    } catch (error) {
      debugPrint('Harness: could not remove "$key": $error');
    }
  }
}
