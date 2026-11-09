import 'dart:async';
import 'dart:convert';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../services/harness_api.dart';
import 'computer_capabilities.dart';
import 'computer_capture_port.dart';
import 'computer_file_store.dart';
import 'computer_identity.dart';
import 'mcp_server.dart';

/// The three ACP calls a registration makes, behind an interface so the
/// endpoint can be tried with a stand-in for a harness.
abstract class ComputerTransport {
  /// Whether the harness offers [method], such as `computer/attach`.
  bool supports(String method);

  Future<JsonMap> register(Map<String, Object?> params);
  Future<JsonMap> attach(String id, String secret);
  Future<JsonMap> update(Map<String, Object?> params);
  Future<void> unregister(String id);
}

/// A [ComputerTransport] over the app's ACP connection.
class HarnessComputerTransport implements ComputerTransport {
  HarnessComputerTransport(this.api);

  final HarnessApi api;

  @override
  bool supports(String method) => api.can(method);

  @override
  Future<JsonMap> register(Map<String, Object?> params) async =>
      asMap(await api.extension('computer/register', params));

  @override
  Future<JsonMap> attach(String id, String secret) async => asMap(
    await api.extension('computer/attach', <String, Object?>{
      'id': id,
      'secret': secret,
    }),
  );

  @override
  Future<JsonMap> update(Map<String, Object?> params) async =>
      asMap(await api.extension('computer/update', params));

  @override
  Future<void> unregister(String id) async {
    await api.extension('computer/unregister', <String, Object?>{'id': id});
  }
}

/// What the Computers page and the app show of this phone's registration.
class MobileComputerStatus {
  const MobileComputerStatus({
    required this.registered,
    required this.connected,
    required this.capabilities,
    this.lastError,
    this.captureSource,
    this.captureStartedAt,
  });

  final bool registered;
  final bool connected;
  final ComputerCapabilities capabilities;
  final String? lastError;
  final ComputerCaptureSource? captureSource;
  final DateTime? captureStartedAt;

  MobileComputerStatus copyWith({
    bool? registered,
    bool? connected,
    ComputerCapabilities? capabilities,
    String? lastError,
    bool clearError = false,
    ComputerCaptureSource? captureSource,
    DateTime? captureStartedAt,
  }) => MobileComputerStatus(
    registered: registered ?? this.registered,
    connected: connected ?? this.connected,
    capabilities: capabilities ?? this.capabilities,
    lastError: clearError ? null : (lastError ?? this.lastError),
    captureSource: captureSource ?? this.captureSource,
    captureStartedAt: captureStartedAt ?? this.captureStartedAt,
  );
}

/// This phone as a computer: the ACP registration, the MCP servers it runs
/// and the capability/lifecycle rules that keep it honest.
///
/// The harness is the only place state lives.  This object keeps the secret
/// and token in memory, answers one request at a time, and refuses a call
/// that names another computer, another server or with the wrong token.  A
/// stop, a permission loss or a lifecycle transition increments
/// [generation]; a tool call that was in flight across that boundary fails
/// instead of returning a frame from before it.
class MobileComputerEndpoint {
  MobileComputerEndpoint({
    required this.identity,
    required this.transport,
    required this.capture,
    required this.files,
    Map<String, bool> enabled = const <String, bool>{},
  }) : _enabled = <String, bool>{} {
    _enabled.addAll(enabled);
    _statusSubscription = capture.statuses.listen(_onCaptureEvent);
  }

  static const mcpMethod = '_harness/computer/mcp';
  static const computerServer = 'computer';
  static const filesServer = 'files';
  static const serverNames = <String>[computerServer, filesServer];

  final ComputerIdentity identity;
  final ComputerTransport transport;
  final ComputerCapturePort capture;
  final ComputerFileStore files;

  final Map<String, bool> _enabled;
  final Map<String, ComputerCapabilityStatus> _captureStates =
      <String, ComputerCapabilityStatus>{};
  final StreamController<MobileComputerStatus> _statuses =
      StreamController<MobileComputerStatus>.broadcast();

  StreamSubscription<ComputerCaptureEvent>? _statusSubscription;
  String? _token;
  bool _registered = false;
  bool _connected = false;
  /// True while `register` or `attachIfKnown` waits for the harness's answer.
  /// The harness attaches the MCP servers before it answers, so their
  /// handshake arrives before the client has the token that binds it.
  bool _binding = false;
  bool _disposed = false;
  int _generation = 0;
  String? _lastError;
  ComputerCaptureSource? _captureSource;
  DateTime? _captureStartedAt;
  ComputerCapabilities _capabilities = ComputerCapabilities.empty;

  Stream<MobileComputerStatus> get statuses => _statuses.stream;
  MobileComputerStatus get status => MobileComputerStatus(
    registered: _registered,
    connected: _connected,
    capabilities: _capabilities,
    lastError: _lastError,
    captureSource: _captureSource,
    captureStartedAt: _captureStartedAt,
  );

  bool get registered => _registered;
  bool get connected => _connected;
  int get generation => _generation;
  ComputerCapabilities get capabilities => _capabilities;
  String get id => identity.id;

  /// Whether the person turned [capability] on for this phone.
  bool isEnabled(String capability) => _enabled[capability] ?? false;

  /// Set the person's opt-in for [capability]; [update] advertises it.
  void setEnabled(String capability, bool value) =>
      _enabled[capability] = value;

  /// The description this phone advertises in `initialize`.  It carries no
  /// capability the person has not enabled; capabilities are refreshed
  /// before a registration.
  Map<String, Object?> clientCapabilities() => <String, Object?>{
    'fs': <String, Object?>{'readTextFile': false, 'writeTextFile': false},
    'terminal': false,
    '_harness': <String, Object?>{
      'sessionRefresh': true,
      'computer': computerInfo(),
    },
  };

  /// The computer description sent with `computer/register` and `update`.
  Map<String, Object?> computerInfo() => <String, Object?>{
    ...identity.toWire(),
    'capabilities': _capabilities.offered,
    'capabilityStates': _capabilities.statesWire,
    'servers': <Object?>[
      <String, Object?>{'name': computerServer, 'title': 'Computer'},
      <String, Object?>{'name': filesServer, 'title': 'Files'},
    ],
  };

  /// Refresh what the platform can capture, then advertise it.  The phone
  /// never prompts for a permission here: a source the OS has not answered
  /// yet reads available, and the first tool call asks.
  Future<void> refreshCapabilities() async {
    final states = await capture.capabilities();
    final next = <String, ComputerCapabilityStatus>{};
    for (final source in ComputerCaptureSource.values) {
      final status =
          states[source] ??
          const ComputerCapabilityStatus(
            state: ComputerCapabilityState.unavailable,
          );
      final enabled = isEnabled(source.capability);
      next[source.capability] = enabled
          ? (_captureStates[source.capability] ?? status)
          : ComputerCapabilityStatus(
              state: ComputerCapabilityState.unavailable,
              detail: 'Off on this phone',
            );
    }
    next['files'] = isEnabled('files') && files.available
        ? ComputerCapabilityStatus(
            state: ComputerCapabilityState.available,
            detail: 'App documents and imported files',
          )
        : ComputerCapabilityStatus(
            state: files.available
                ? ComputerCapabilityState.unavailable
                : ComputerCapabilityState.unavailable,
            detail: files.available ? 'Off on this phone' : 'No app files',
          );
    next['clipboard'] = isEnabled('clipboard')
        ? const ComputerCapabilityStatus(
            state: ComputerCapabilityState.available,
          )
        : const ComputerCapabilityStatus(
            state: ComputerCapabilityState.unavailable,
            detail: 'Off on this phone',
          );
    _capabilities = ComputerCapabilities(next);
    _notify();
  }

  /// Register this phone with the harness, or update the registration it
  /// already has.  Registration is an explicit act: nothing calls this but
  /// the person's button.
  Future<void> register() async {
    _lastError = null;
    await refreshCapabilities();
    _binding = true;
    try {
      final answer = await transport.register(<String, Object?>{
        'computer': computerInfo(),
        'secret': identity.secret,
        'resources': await resources(),
        'servers': serverNames,
      });
      _adoptAnswer(answer);
      _registered = true;
      _connected = true;
    } finally {
      _binding = false;
    }
    _notify();
  }

  /// Attach again after a reconnect, when this phone has a registration
  /// with the harness.  A harness that has no record says so and this
  /// leaves the phone unregistered; it is not a registration.
  Future<bool> attachIfKnown() async {
    _lastError = null;
    _binding = true;
    try {
      final answer = await transport.attach(identity.id, identity.secret);
      _adoptAnswer(answer);
      _registered = true;
      _connected = true;
      await update();
      return true;
    } on AcpException catch (failure) {
      if (failure.isMethodNotFound) {
        _connected = false;
        return false;
      }
      _lastError = failure.message;
      _registered = false;
      _connected = false;
      _notify();
      return false;
    } catch (failure) {
      _lastError = '$failure';
      _registered = false;
      _connected = false;
      _notify();
      return false;
    } finally {
      _binding = false;
    }
  }

  /// Send the harness this phone's current capabilities and resources.
  Future<void> update() async {
    if (!_registered) return;
    await refreshCapabilities();
    try {
      await transport.update(<String, Object?>{
        'id': identity.id,
        'secret': identity.secret,
        'capabilities': _capabilities.offered,
        'capabilityStates': _capabilities.statesWire,
        'resources': await resources(),
      });
      _lastError = null;
    } catch (failure) {
      _lastError = _message(failure);
    }
    _notify();
  }

  /// The harness's requests that belong to this phone: one MCP message, on
  /// the connection of the client that registered it, with its token.
  Future<Object?> handleRequest(String method, JsonMap params) async {
    if (method != mcpMethod) return null;
    if (!_registered && !_binding) {
      throw const AcpException(-32600, 'This phone is not registered.');
    }
    final computer = asString(params['computer']);
    final server = asString(params['server']);
    final token = asString(params['token']);
    if (computer != identity.id) {
      throw AcpException(-32600, 'This request is for another computer.');
    }
    if (!serverNames.contains(server)) {
      throw AcpException(-32600, 'This phone runs no server $server.');
    }
    if (!_binding &&
        (_token == null || token == null || !_sameToken(_token!, token))) {
      throw const AcpException(-32000, 'The MCP token does not match.');
    }
    final message = asMap(params['message']);
    final answer = await _server(server!).handle(message);
    return answer ?? const <String, Object?>{};
  }

  /// Stop every source and advertise what is left.  A call that was in
  /// flight fails rather than answer with a frame from before the stop.
  Future<void> stopCapture([ComputerCaptureSource? source]) async {
    _generation++;
    _captureSource = null;
    _captureStartedAt = null;
    await capture.stop(source);
    await update();
  }

  /// The app moved to another lifecycle state: capture stops, and a
  /// capability that is only live in the foreground says so.  It never
  /// resumes by itself.
  Future<void> handleLifecycle(String state) async {
    await capture.handleLifecycle(state);
    if (state == 'paused' ||
        state == 'inactive' ||
        state == 'hidden' ||
        state == 'detached') {
      _generation++;
      _captureSource = null;
      _captureStartedAt = null;
      for (final source in ComputerCaptureSource.values) {
        _captureStates[source.capability] = ComputerCapabilityStatus(
          state: ComputerCapabilityState.suspended,
          detail: 'App $state',
        );
      }
      await update();
    } else if (state == 'resumed') {
      for (final source in ComputerCaptureSource.values) {
        _captureStates.remove(source.capability);
      }
      await update();
    }
  }

  /// Give the registration up: stop everything, unregister, forget the
  /// token.  The identity and its secret stay, so a later registration is
  /// the same machine.
  Future<void> revoke() async {
    _generation++;
    await capture.stop();
    try {
      await transport.unregister(identity.id);
    } catch (failure) {
      _lastError = _message(failure);
    }
    _token = null;
    _registered = false;
    _connected = false;
    _captureSource = null;
    _captureStartedAt = null;
    _notify();
  }

  /// The ACP connection is gone.  The registration stays; the next
  /// connection attaches again.
  Future<void> disconnected() async {
    _generation++;
    _connected = false;
    _captureSource = null;
    _captureStartedAt = null;
    await capture.stop();
    _notify();
  }

  Future<List<Object?>> resources() async {
    final out = <Object?>[];
    final info = await files.info();
    final root = asString(info['root']);
    if (files.available && root != null) {
      out.add(<String, Object?>{
        'kind': 'directory',
        'name': 'App documents',
        'path': root,
      });
    }
    if (_capabilities.offered.contains('view')) {
      out.add(const <String, Object?>{'kind': 'display', 'name': 'Screen'});
    }
    if (_capabilities.offered.contains('camera')) {
      out.add(const <String, Object?>{'kind': 'camera', 'name': 'Camera'});
    }
    if (_capabilities.offered.contains('audio')) {
      out.add(const <String, Object?>{'kind': 'audio', 'name': 'Microphone'});
    }
    return out;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _statusSubscription?.cancel();
    await capture.dispose();
    await _statuses.close();
  }

  McpServer _server(String name) =>
      name == filesServer ? _filesServer() : _computerServer();

  McpServer _computerServer() => McpServer(
    name: computerServer,
    title: 'Computer',
    version: '1.0.0',
    instructions:
        'The phone this client runs on: screen and camera pictures, a '
        'microphone clip and its clipboard. It offers no pointer, keyboard '
        'or window control.',
    tools: <McpTool>[
      McpTool(
        name: 'info',
        title: 'Computer information',
        description:
            'Say what this phone is and which capabilities it offers now.',
        inputSchema: const <String, Object?>{'type': 'object'},
        readOnly: true,
        handler: (arguments) async => mcpTextResult(
          'This phone is ${identity.name} (${identity.id}, ${identity.os})',
          structured: <String, Object?>{
            'computer': computerInfo(),
            'capabilities': _capabilities.statesWire,
            'servers': serverNames,
          },
        ),
      ),
      McpTool(
        name: 'screenshot',
        title: 'Screen capture',
        description: 'Capture the phone screen as a PNG, with the OS screen capture permission.',
        inputSchema: const <String, Object?>{'type': 'object'},
        readOnly: true,
        handler: (arguments) => _captureImage(ComputerCaptureSource.screen),
      ),
      McpTool(
        name: 'camera',
        title: 'Camera picture',
        description: 'Take one picture with the phone camera, with the OS camera permission.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'width': <String, Object?>{'type': 'integer'},
            'height': <String, Object?>{'type': 'integer'},
          },
        },
        readOnly: true,
        handler: (arguments) => _captureImage(
          ComputerCaptureSource.camera,
          width: asInt(arguments['width']),
          height: asInt(arguments['height']),
        ),
      ),
      McpTool(
        name: 'audio',
        title: 'Microphone clip',
        description: 'Record a bounded clip from the phone microphone, with the OS microphone permission.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'seconds': <String, Object?>{'type': 'integer'},
          },
        },
        readOnly: false,
        handler: (arguments) => _captureAudio(arguments),
      ),
      McpTool(
        name: 'clipboard',
        title: 'Clipboard',
        description: 'Read or write the phone clipboard, in the foreground.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'action': <String, Object?>{
              'type': 'string',
              'enum': <Object?>['get', 'set'],
            },
            'text': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['action'],
        },
        readOnly: false,
        handler: (arguments) => _clipboard(arguments),
      ),
    ],
  );

  McpServer _filesServer() => McpServer(
    name: filesServer,
    title: 'Files',
    version: '1.0.0',
    instructions:
        'The app files this phone offers: <app documents>/harness-computer, '
        'with imported files under imports/. Writes go to outbox/ only and '
        'only when the person allowed them.',
    tools: <McpTool>[
      mcpSyncTool(
        name: 'info',
        title: 'Files information',
        description:
            'Say where the scoped files are and whether writing is allowed.',
        inputSchema: const <String, Object?>{'type': 'object'},
        readOnly: true,
        handler: (arguments) => mcpTextResult(
          'App files; writing ${files.writesEnabled ? 'on' : 'off'}',
        ),
      ),
      mcpSyncTool(
        name: 'list_dir',
        title: 'List files',
        description: 'List a directory in the app files, with size and type.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['path'],
        },
        readOnly: true,
        handler: (arguments) async {
          final result = await files.list(asString(arguments['path']) ?? '');
          return result.toMcpResult();
        },
      ),
      mcpSyncTool(
        name: 'read_file',
        title: 'Read file',
        description: 'Read a text file in the app files, by line range.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{'type': 'string'},
            'offset': <String, Object?>{'type': 'integer'},
            'limit': <String, Object?>{'type': 'integer'},
          },
          'required': <Object?>['path'],
        },
        readOnly: true,
        handler: (arguments) async {
          final result = await files.read(
            asString(arguments['path']) ?? '',
            offset: asInt(arguments['offset']),
            limit: asInt(arguments['limit']),
          );
          return result.toMcpResult();
        },
      ),
      mcpSyncTool(
        name: 'file_info',
        title: 'File info',
        description: 'Metadata for a path in the app files.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['path'],
        },
        readOnly: true,
        handler: (arguments) async {
          final result = await files.fileInfo(
            asString(arguments['path']) ?? '',
          );
          return result.toMcpResult();
        },
      ),
      mcpSyncTool(
        name: 'write_file',
        title: 'Write file',
        description:
            'Write a text file under outbox/, when the person allowed writing.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{'type': 'string'},
            'content': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['path', 'content'],
        },
        handler: (arguments) async {
          final result = await files.write(
            asString(arguments['path']) ?? '',
            asString(arguments['content']) ?? '',
          );
          return result.toMcpResult();
        },
      ),
    ],
  );

  Future<Map<String, Object?>> _captureImage(
    ComputerCaptureSource source, {
    int? width,
    int? height,
  }) async {
    final capability = source.capability;
    final status = _capabilities[capability];
    if (status == null || !status.offered) {
      return mcpTextResult(
        '${computerCapabilityLabels[capability] ?? capability} is not offered by this phone: ${status?.label ?? 'unavailable'}',
        isError: true,
      );
    }
    final generation = _generation;
    try {
      await capture.start(source);
      _captureSource = source;
      _captureStartedAt = DateTime.now();
      _notify();
      final png = await capture.capturePng(
        source,
        maxWidth: width ?? 640,
        maxHeight: height ?? 360,
      );
      if (generation != _generation) {
        return mcpTextResult(
          'Capture stopped before the frame was ready',
          isError: true,
        );
      }
      if (png == null) {
        return mcpTextResult('No frame: $source is not live', isError: true);
      }
      return mcpImageResult(png, width: width ?? 640, height: height ?? 360);
    } catch (failure) {
      final state = _captureStates[capability];
      return mcpTextResult(
        state == null
            ? 'Cannot capture: $failure'
            : 'Cannot capture: ${state.label}${state.detail == null ? '' : ' (${state.detail})'}',
        isError: true,
      );
    }
  }

  Future<Map<String, Object?>> _captureAudio(
    Map<String, Object?> arguments,
  ) async {
    final status = _capabilities['audio'];
    if (status == null || !status.offered) {
      return mcpTextResult(
        'Microphone is not offered by this phone: ${status?.label ?? 'unavailable'}',
        isError: true,
      );
    }
    final generation = _generation;
    final seconds = (asInt(arguments['seconds']) ?? 5).clamp(1, 15);
    try {
      await capture.start(ComputerCaptureSource.microphone);
      _captureSource = ComputerCaptureSource.microphone;
      _captureStartedAt = DateTime.now();
      _notify();
      final wav = await capture.captureAudio(max: Duration(seconds: seconds));
      if (generation != _generation) {
        return mcpTextResult(
          'Capture stopped before the clip was ready',
          isError: true,
        );
      }
      if (wav == null) {
        return mcpTextResult(
          'No audio: the microphone is not live',
          isError: true,
        );
      }
      return mcpTextResult(
        'Audio ${wav.length} B, $seconds s',
        structured: <String, Object?>{
          'data': base64Encode(wav),
          'mime': 'audio/wav',
          'seconds': seconds,
        },
      );
    } catch (failure) {
      return mcpTextResult('Cannot record: $failure', isError: true);
    }
  }

  Future<Map<String, Object?>> _clipboard(
    Map<String, Object?> arguments,
  ) async {
    if (!isEnabled('clipboard')) {
      return mcpTextResult('Clipboard is off on this phone', isError: true);
    }
    // Imported lazily so a pure unit test needs no Flutter binding.
    final services = await _clipboardServices();
    if (services == null) {
      return mcpTextResult('This platform has no clipboard', isError: true);
    }
    final action = asString(arguments['action']) ?? 'get';
    if (action == 'set') {
      final text = asString(arguments['text']) ?? '';
      await services.set(text);
      return mcpTextResult('Put ${text.length} characters on the clipboard');
    }
    final text = await services.get();
    return mcpTextResult(text ?? '');
  }

  Future<({Future<String?> Function() get, Future<void> Function(String) set})?>
  _clipboardServices() async {
    try {
      return await clipboardSource?.call();
    } catch (_) {
      return null;
    }
  }

  /// Set by the Flutter controller, which can import `flutter/services.dart`;
  /// a pure Dart test leaves it null and gets an honest "no clipboard".
  static Future<
    ({Future<String?> Function() get, Future<void> Function(String) set})?
  >
  Function()?
  clipboardSource;

  void _onCaptureEvent(ComputerCaptureEvent event) {
    final previous = _captureStates[event.source.capability];
    _captureStates[event.source.capability] = event.status;
    if (!event.status.offered ||
        event.status.state == ComputerCapabilityState.suspended) {
      _generation++;
      _captureSource = null;
      _captureStartedAt = null;
    }
    if (previous?.state != event.status.state) {
      _notify();
      unawaited(update());
    }
  }

  void _adoptAnswer(JsonMap answer) {
    final token = asString(answer['token']);
    if (token != null && token.isNotEmpty) _token = token;
  }

  bool _sameToken(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
    }
    return difference == 0;
  }

  String _message(Object failure) =>
      failure is AcpException ? failure.message : '$failure';

  void _notify() {
    if (!_disposed && !_statuses.isClosed) _statuses.add(status);
  }
}
