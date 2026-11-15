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
import 'computer_platform.dart';
import 'mobile_computer_endpoint.dart';
import 'session_computer_capture_port.dart';

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
    ComputerPlatform? platform,
    SystemControlPort? control,
    ComputerMediaCapture? media,
    ComputerCapturePort? capture,
    ComputerFileStore? files,
  }) : platform = platform ?? computerPlatformFor(),
       control = control ?? systemControlFor(),
       _media = media ?? const NoopComputerMediaCapture(),
       _capture = capture,
       _files = files {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // A pure Dart test has no binding; it does not need lifecycle events.
    }
  }

  final SharedPreferences? preferences;

  /// The phone's own OS: its permission answers, its durable private
  /// directory, its keystore and its settings page for system control.
  final ComputerPlatform platform;

  /// The person's opt-in system control, which is the only pointer and
  /// keyboard this phone offers.  It is [UnsupportedSystemControl] on a
  /// platform with no public input injection (iOS), and nothing advertises it
  /// until the OS says the person enabled it.
  final SystemControlPort control;

  final ComputerMediaCapture _media;
  ComputerCapturePort? _capture;
  ComputerFileStore? _files;

  /// What the OS last said, as a value.  Nothing on the connection path waits
  /// for a channel; [readPlatform] fills it once and again when the person
  /// asks or the app comes back to the front.
  PlatformFacts _facts = const PlatformFacts();
  PlatformFacts get platformFacts => _facts;
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

  /// The capabilities that drive the phone rather than read it.  They are
  /// listed apart on the page, because a person's `pointer` or `keyboard`
  /// grant reaches other apps and the rest do not.
  static const controlCapabilityNames = <String>['pointer', 'keyboard'];

  /// Every capability the phone can offer, in the order a page lists them.
  static const allCapabilityNames = <String>[
    ...capabilityNames,
    ...controlCapabilityNames,
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

  /// Whether the OS says the person's system control is on, so the page can
  /// say `Enabled` or `System control off` without guessing.  Before the OS is
  /// asked it reads [SystemControlState.disabled] on a platform that has the
  /// control at all, which is the true thing to say: it is off until a person
  /// turns it on in the OS.
  SystemControlState get systemControl =>
      _facts.read || !control.supported
      ? _facts.control
      : SystemControlState.disabled;

  /// Whether this platform can drive other apps at all.  A person still has
  /// to enable it in the OS; this only says the door exists.
  bool get controlAvailable => control.supported;

  /// Open the OS's own settings page where the person enables or withdraws
  /// the control.  The app never enables it itself.
  Future<void> openControlSettings() async {
    final opened = await control.openSettings();
    _notice = opened ? null : 'No system control';
    if (!opened && !control.supported) {
      _error = 'No system control on this platform';
    }
    // The person may have just turned it on, so the OS is asked again.
    if (opened) await refreshPlatform();
    notifyListeners();
  }

  /// Re-read what the OS says: a permission the person changed in the system
  /// settings while the app was open, and the system control they enabled.
  /// Nothing is captured and nothing is started.
  Future<void> refreshPlatform() async {
    await readPlatform();
    await _endpoint?.refreshCapabilities();
    await _endpoint?.update();
    notifyListeners();
  }

  /// Hand a freshly read [facts] to the endpoint that is bound now, so its
  /// advertised control follows the OS.  Called from [readPlatform].
  void _pushFacts() {
    final endpoint = _endpoint;
    if (endpoint == null) return;
    unawaited(endpoint.refreshCapabilities());
  }

  /// Ask the OS once, with a bound, and hold what it says.  A channel that does
  /// not answer (a test, the web, a desktop build) leaves the facts unread: the
  /// page then says `Not checked` instead of inventing a permission state, and
  /// nothing on the connection path was ever waiting for it.
  Future<void> readPlatform() async {
    final reading = _reading;
    if (reading != null) {
      await reading;
      return;
    }
    final started = _readPlatform();
    _reading = started;
    try {
      _facts = await started;
    } finally {
      _reading = null;
    }
    // The OS has now answered, so what this phone advertises may change: the
    // endpoint reads the same held value, and is told to look again.
    _pushFacts();
    notifyListeners();
  }

  Future<PlatformFacts>? _reading;

  Future<PlatformFacts> _readPlatform() async {
    try {
      return await platform.facts();
    } catch (_) {
      // No answer: the platform has nothing to say here, and the app goes on.
      // A platform that never answers at all (a widget test's channel, the
      // web) leaves this future open, which is why nothing on the connection
      // path awaits it and no timer is kept to give up on it.
      return _facts;
    }
  }

  /// The capture port this phone actually offers with, for the page's
  /// `Capture` state and for a test that replaces it.
  ComputerCapturePort? get capturePort => _capture;
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
  ///
  /// The identity is kept under the platform's own protection (the Android
  /// Keystore or the iOS Keychain), and the files are the app's durable
  /// private directory.  A platform with neither still starts: a run-only
  /// identity and the process's temporary directory are honest fallbacks, and
  /// [storageDetail] says which one is in use.
  Future<void> ready() async {
    if (_ready) return;
    // The identity and the file store are made from what the OS already said
    // ([readPlatform] is called once from `main`), so this never waits on a
    // channel: a connection must not hang on one, and a test has none.
    try {
      _identity = await loadMobileComputerIdentity(
        preferences: preferences,
        platform: _facts.secure ? platform : null,
        directoryPath: _facts.storageRoot,
      );
    } catch (_) {
      // A test or a platform without the channel still gets an identity,
      // kept for this run only.
      _identity = ComputerIdentity.ephemeral();
    }
    try {
      _files ??= openComputerFileStore(rootPath: _facts.storageRoot);
    } catch (_) {
      // No app documents here (a widget test, the web): an honest store
      // that offers no files.
      _files ??= const UnavailableComputerFileStore();
    }
    _capture ??= SessionComputerCapturePort(
      platform: platform,
      media: _media,
      facts: () => _facts,
    );
    _enabled.addAll(<String, bool>{
      for (final name in allCapabilityNames) name: false,
    });
    _ready = true;
    notifyListeners();
    // The OS is asked after the app is usable, never before it.  It fills the
    // capability states the page shows; nothing waits for it.
    if (!_facts.read) unawaited(readPlatform());
  }

  /// Where the identity and the scoped files are kept, for the page.  It is
  /// a fact about this run, not a promise: `App documents` once the OS gave
  /// the app its own durable directory, `Temporary directory` when it gave
  /// none, and `Not checked` before the OS was asked at all.
  String get storageDetail => !_facts.read
      ? 'Not checked'
      : _facts.storageRoot == null
      ? 'Temporary directory'
      : 'App documents';

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
      capture: _capture ??= SessionComputerCapturePort(
        platform: platform,
        media: _media,
        facts: () => _facts,
      ),
      files: _files!,
      control: control,
      // What the OS last said, not a fresh ask: this is the connection
      // path, and a platform channel is never waited on here.
      controlState: () => systemControl,
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
    if (enabled &&
        controlCapabilityNames.contains(capability) &&
        !controlAvailable) {
      _error = 'No system control on this platform';
      _enabled[capability] = false;
      notifyListeners();
      return;
    }
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
  ComputerPlatform? platform,
  String? directoryPath,
}) => ComputerIdentity.load(
  preferences: preferences,
  platform: platform,
  directoryPath: directoryPath,
);
