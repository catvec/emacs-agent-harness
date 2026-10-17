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

  ThemeMode get themeMode => _themeMode;
  PreviewPlatform get previewPlatform => _previewPlatform;
  bool get showThinking => _showThinking;
  bool get rememberConnection => _rememberConnection;
  String get address => _address;
  String get token => _token;
  bool get loaded => _loaded;

  bool get useCupertino => switch (_previewPlatform) {
    PreviewPlatform.cupertino => true,
    PreviewPlatform.material => false,
    PreviewPlatform.system =>
      defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS,
  };

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;
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
    _loaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _prefs?.setString('themeMode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> setPreviewPlatform(PreviewPlatform platform) async {
    _previewPlatform = platform;
    notifyListeners();
    await _prefs?.setString('previewPlatform', switch (platform) {
      PreviewPlatform.system => 'system',
      PreviewPlatform.material => 'material',
      PreviewPlatform.cupertino => 'cupertino',
    });
  }

  Future<void> setShowThinking(bool value) async {
    _showThinking = value;
    notifyListeners();
    await _prefs?.setBool('showThinking', value);
  }

  Future<void> setRememberConnection(bool value) async {
    _rememberConnection = value;
    notifyListeners();
    await _prefs?.setBool('rememberConnection', value);
    if (!value) await clearConnection();
  }

  Future<void> rememberConnectionDetails(String address, String token) async {
    _address = address;
    _token = token;
    notifyListeners();
    if (!_rememberConnection) return;
    await _prefs?.setString('address', address);
    await _prefs?.setString('token', token);
  }

  Future<void> clearConnection() async {
    _address = '';
    _token = '';
    notifyListeners();
    await _prefs?.remove('address');
    await _prefs?.remove('token');
  }
}
