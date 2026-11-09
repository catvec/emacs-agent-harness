import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../acp/acp_client.dart';
import 'computer_capabilities.dart';
import 'computer_capture_port.dart';
import 'computer_file_store.dart';
import 'computer_file_store_factory.dart';
import 'computer_identity.dart';
import 'mobile_computer_endpoint.dart';

/// The app's view of this phone as a computer.
///
/// It owns the identity and the scoped file store, binds the endpoint to
/// the ACP connection the app is using, and keeps the per-capability opt-in
/// the person sets on the Computers page.  It is a [WidgetsBindingObserver]:
/// when the app leaves the foreground every capture stops, the capability
/// state says so, and nothing resumes by itself.
class MobileComputerController extends ChangeNotifier
    with WidgetsBindingObserver {
  MobileComputerController({
    this.preferences,
    ComputerCapturePort? capture,
    ComputerFileStore? files,
  }) : _capture = capture ?? NoopComputerCapturePort(),
       _files = files {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // A pure Dart test has no binding; it does not need lifecycle events.
    }
  }

  final SharedPreferences? preferences;
  final ComputerCapturePort _capture;
  ComputerFileStore? _files;
  bool _observing = false;
  bool _disposed = false;

  ComputerIdentity? _identity;
  MobileComputerEndpoint? _endpoint;
  bool _ready = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  final Map<String, bool> _enabled = <String, bool>{};

  static const capabilityNames = <String>[
    'view',
    'camera',
    'audio',
    'files',
    'clipboard',
  ];

  ComputerIdentity? get identity => _identity;
  MobileComputerEndpoint? get endpoint => _endpoint;
  bool get isReady => _ready;
  bool get busy => _busy;
  String? get error => _error;
  String? get notice => _notice;
  bool get registered => _endpoint?.registered ?? false;
  bool get connected => _endpoint?.connected ?? false;
  int get generation => _endpoint?.generation ?? 0;
  ComputerCapabilities get capabilities =>
      _endpoint?.capabilities ?? ComputerCapabilities.empty;
  ComputerCaptureSource? get captureSource => _endpoint?.status.captureSource;
  DateTime? get captureStartedAt => _endpoint?.status.captureStartedAt;
  bool get fileWritesEnabled => _files?.writesEnabled ?? false;
  ComputerFileStore? get files => _files;

  /// The platform label this device shows: Phone, Tablet or Desktop.
  String get formLabel => switch (machineOs) {
    'android' || 'ios' => 'This phone',
    _ => 'This device',
  };

  String get machineName => _identity?.name ?? 'This phone';
  String get machineId => _identity?.id ?? '';
  String get machineOs => _identity?.os ?? computerOs();

  bool isEnabled(String capability) => _enabled[capability] ?? false;

  /// Load the identity, the scoped files and the saved opt-ins.  Called
  /// before the first connection and again when one replaces another.
  Future<void> ready() async {
    if (_ready) return;
    try {
      _identity = await loadMobileComputerIdentity(preferences: preferences);
    } catch (_) {
      // A test or a platform without the preferences channel still gets an
      // identity, kept for this run only.
      _identity = ComputerIdentity.ephemeral();
    }
    try {
      _files ??= openComputerFileStore();
    } catch (_) {
      // No app documents here (a widget test, the web): an honest store
      // that offers no files.
      _files ??= const UnavailableComputerFileStore();
    }
    _enabled.addAll(<String, bool>{
      for (final name in capabilityNames) name: false,
    });
    _ready = true;
    notifyListeners();
  }

  /// Use [transport] for the harness the app is connected to now, and
  /// attach this phone again if it is registered there.  A fresh transport
  /// replaces the old one; the registration is not sent again.
  Future<void> bind(ComputerTransport? transport) async {
    await ready();
    if (_endpoint != null) {
      await _endpoint!.dispose();
      _endpoint = null;
    }
    if (transport == null) {
      notifyListeners();
      return;
    }
    final endpoint = MobileComputerEndpoint(
      identity: _identity!,
      transport: transport,
      capture: _capture,
      files: _files!,
      enabled: _enabled,
    );
    _endpoint = endpoint;
    endpoint.statuses.listen((status) {
      _error = status.lastError;
      notifyListeners();
    });
    MobileComputerEndpoint.clipboardSource = _clipboardSource;
    await endpoint.refreshCapabilities();
    if (transport.supports('computer/attach')) {
      await endpoint.attachIfKnown();
    }
    notifyListeners();
  }

  /// Register this phone; explicit, and only from the person's button.
  Future<void> register() async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      _error = 'No connection';
      notifyListeners();
      return;
    }
    await _run(() async {
      await endpoint.register();
      _notice = 'Registration';
    });
  }

  Future<void> attach() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    await _run(() async {
      final attached = await endpoint.attachIfKnown();
      _notice = attached ? 'Reconnection' : null;
      if (!attached) _error = 'No registration';
    });
  }

  /// Turn one capability on or off for this phone.  Turning it on does not
  /// start a capture; the first tool call asks the OS.  Turning it off
  /// stops a capture that is running and advertises the change.
  Future<void> setEnabled(String capability, bool enabled) async {
    final endpoint = _endpoint;
    _enabled[capability] = enabled;
    if (endpoint != null) {
      endpoint.setEnabled(capability, enabled);
      if (!enabled) {
        for (final source in ComputerCaptureSource.values) {
          if (source.capability == capability) {
            await endpoint.stopCapture(source);
          }
        }
      }
      await endpoint.refreshCapabilities();
      await endpoint.update();
    }
    notifyListeners();
  }

  Future<void> stopCapture() async {
    await _endpoint?.stopCapture();
    _notice = 'Capture off';
    notifyListeners();
  }

  Future<void> disconnect() async {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    await endpoint.disconnected();
    _notice = 'Disconnection';
    notifyListeners();
  }

  /// Give the registration up and forget it.  The identity stays; a later
  /// registration is the same machine.
  Future<void> revoke() async {
    await _run(() async {
      await _endpoint?.revoke();
      _notice = 'Revocation';
    });
  }

  /// Import a person-selected file into the app files.  The picker is the
  /// person's act, never an agent's: the agent only sees the copy.
  Future<void> importFile() async {
    final files = _files;
    if (files == null) return;
    try {
      final picked = await openFile();
      if (picked == null) return;
      final result = await files.importFile(picked.path);
      _notice = result.isError ? null : 'File import';
      if (result.isError) _error = result.text;
      await _endpoint?.update();
      notifyListeners();
    } catch (failure) {
      _error = '$failure';
      notifyListeners();
    }
  }

  Future<void> setFileWriting(bool enabled) async {
    await _files?.setWritesEnabled(enabled);
    await _endpoint?.update();
    notifyListeners();
  }

  /// The harness's requests for this phone's MCP servers; null for any
  /// request that belongs to another handler.
  Future<Object?> handleRequest(String method, Map<String, Object?> params) {
    final endpoint = _endpoint;
    if (endpoint == null) return Future<Object?>.value(null);
    return endpoint.handleRequest(method, params);
  }

  /// The `_harness.computer` description sent in `initialize`.
  Map<String, Object?> clientCapabilities() {
    final endpoint = _endpoint;
    if (endpoint != null) return endpoint.clientCapabilities();
    final identity = _identity;
    if (identity == null) {
      return <String, Object?>{
        'fs': <String, Object?>{'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
        '_harness': <String, Object?>{'sessionRefresh': true},
      };
    }
    return <String, Object?>{
      'fs': <String, Object?>{'readTextFile': false, 'writeTextFile': false},
      'terminal': false,
      '_harness': <String, Object?>{
        'sessionRefresh': true,
        'computer': <String, Object?>{
          ...identity.toWire(),
          'capabilities': const <String>[],
          'servers': const <Object?>[],
        },
      },
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_endpoint?.handleLifecycle(state.name));
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    unawaited(_endpoint?.dispose());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notice = null;
    notifyListeners();
    try {
      await action();
    } catch (failure) {
      _error = failure is AcpException ? failure.message : '$failure';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<({Future<String?> Function() get, Future<void> Function(String) set})?>
  _clipboardSource() async => (
    get: () async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    },
    set: (text) => Clipboard.setData(ClipboardData(text: text)),
  );
}

Future<ComputerIdentity> loadMobileComputerIdentity({
  SharedPreferences? preferences,
}) => ComputerIdentity.load(preferences: preferences);
