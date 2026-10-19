import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PreviewPlatform { system, material, cupertino }

/// Local, non-secret preferences.  The connection token is kept only when
/// "Remember" is on; it is a shared secret for one harness, not an account
/// password.
class SettingsController extends ChangeNotifier {
  SettingsController({SharedPreferences? preferences}) : _prefs = preferences;

  SharedPreferences? _prefs;
  ThemeMode _themeMode = ThemeMode.system;
  PreviewPlatform _previewPlatform = PreviewPlatform.system;
  bool _showThinking = true;
  bool _rememberConnection = true;
  String _address = '';
  String _token = '';
  bool _loaded = false;
  Object? _loadError;

  ThemeMode get themeMode => _themeMode;
  PreviewPlatform get previewPlatform => _previewPlatform;
  bool get showThinking => _showThinking;
  bool get rememberConnection => _rememberConnection;
  String get address => _address;
  String get token => _token;
  bool get loaded => _loaded;

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
        _address = prefs.getString('address') ?? '';
        _token = prefs.getString('token') ?? '';
      } catch (error) {
        // Corrupt or unreadable values: keep the defaults above and go on.
        _loadError = error;
        debugPrint('Harness: local settings could not be read: $error');
      }
    }
    _loaded = true;
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

  Future<void> setRememberConnection(bool value) async {
    _rememberConnection = value;
    notifyListeners();
    await _setBool('rememberConnection', value);
    if (!value) await clearConnection();
  }

  Future<void> rememberConnectionDetails(String address, String token) async {
    _address = address;
    _token = token;
    notifyListeners();
    if (!_rememberConnection) return;
    await _setString('address', address);
    await _setString('token', token);
  }

  Future<void> clearConnection() async {
    _address = '';
    _token = '';
    notifyListeners();
    await _remove('address');
    await _remove('token');
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
