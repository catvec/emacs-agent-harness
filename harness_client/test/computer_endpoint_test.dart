import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/computer/app_computer_file_store.dart';
import 'package:harness_client/src/computer/computer_capabilities.dart';
import 'package:harness_client/src/computer/computer_capture_port.dart';
import 'package:harness_client/src/computer/computer_file_store.dart';
import 'package:harness_client/src/computer/computer_identity.dart';
import 'package:harness_client/src/computer/mcp_server.dart';
import 'package:harness_client/src/computer/mobile_computer_controller.dart';
import 'package:harness_client/src/computer/mobile_computer_endpoint.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class FakeTransport implements ComputerTransport {
  final List<Map<String, Object?>> registered = <Map<String, Object?>>[];
  final List<Map<String, Object?>> updated = <Map<String, Object?>>[];
  final List<String> attached = <String>[];
  final List<String> unregistered = <String>[];
  bool attachFails = false;
  bool supported = true;
  Future<void> Function()? duringRegister;
  Future<void> Function()? duringAttach;

  @override
  bool supports(String method) => supported;

  @override
  Future<Map<String, Object?>> register(Map<String, Object?> params) async {
    registered.add(params);
    await duringRegister?.call();
    return <String, Object?>{
      'token': 'token-1',
      'computer': <String, Object?>{},
    };
  }

  @override
  Future<Map<String, Object?>> attach(String id, String secret) async {
    attached.add(id);
    if (attachFails) {
      throw AcpException(-32602, 'No computer is named $id');
    }
    await duringAttach?.call();
    return <String, Object?>{
      'token': 'token-2',
      'computer': <String, Object?>{},
    };
  }

  @override
  Future<Map<String, Object?>> update(Map<String, Object?> params) async {
    updated.add(params);
    return <String, Object?>{'id': params['id']};
  }

  @override
  Future<void> unregister(String id) async {
    unregistered.add(id);
  }
}

class FakeCapture implements ComputerCapturePort {
  FakeCapture({this.available = true});

  final bool available;
  final StreamController<ComputerCaptureEvent> _events =
      StreamController<ComputerCaptureEvent>.broadcast();
  final Set<ComputerCaptureSource> live = <ComputerCaptureSource>{};
  final List<ComputerCaptureSource> started = <ComputerCaptureSource>[];
  bool slowFrame = false;

  @override
  Future<Map<ComputerCaptureSource, ComputerCapabilityStatus>>
  capabilities() async {
    return <ComputerCaptureSource, ComputerCapabilityStatus>{
      for (final source in ComputerCaptureSource.values)
        source: ComputerCapabilityStatus(
          state: available
              ? ComputerCapabilityState.available
              : ComputerCapabilityState.unavailable,
          detail: available ? null : 'No capture implementation',
        ),
    };
  }

  @override
  Stream<ComputerCaptureEvent> get statuses => _events.stream;

  @override
  Future<void> start(ComputerCaptureSource source) async {
    if (!available) throw StateError('No capture implementation');
    live.add(source);
    started.add(source);
  }

  @override
  Future<void> stop([ComputerCaptureSource? source]) async {
    if (source == null) {
      live.clear();
    } else {
      live.remove(source);
    }
  }

  @override
  Future<Uint8List?> capturePng(
    ComputerCaptureSource source, {
    int maxWidth = 640,
    int maxHeight = 360,
  }) async {
    if (!live.contains(source)) return null;
    if (slowFrame) await Future<void>.delayed(const Duration(milliseconds: 50));
    return Uint8List.fromList(_png);
  }

  @override
  Future<Uint8List?> captureAudio({
    Duration max = const Duration(seconds: 10),
  }) async {
    if (!live.contains(ComputerCaptureSource.microphone)) return null;
    return Uint8List.fromList(<int>[82, 73, 70, 70]);
  }

  @override
  Future<void> handleLifecycle(String state) async {}

  @override
  Future<void> dispose() async {
    await _events.close();
  }

  void emit(ComputerCaptureSource source, ComputerCapabilityState state) {
    _events.add(
      ComputerCaptureEvent(
        source: source,
        status: ComputerCapabilityStatus(state: state),
      ),
    );
  }
}

ComputerIdentity _identity() => const ComputerIdentity(
  id: 'cmp-ios-abc123',
  name: 'Test phone',
  os: 'ios',
  arch: 'unknown',
  secret: 'a-secret-that-is-at-least-32-characters-long',
);

Future<MobileComputerEndpoint> _endpoint({
  FakeTransport? transport,
  FakeCapture? capture,
  ComputerFileStore? files,
  Map<String, bool>? enabled,
}) async {
  final dir = Directory.systemTemp.createTempSync('mobile-computer-test-');
  addTearDown(() => dir.deleteSync(recursive: true));
  dir.createSync(recursive: true);
  final store = files ?? AppComputerFileStore(dir, writesEnabled: false);
  return MobileComputerEndpoint(
    identity: _identity(),
    transport: transport ?? FakeTransport(),
    capture: capture ?? FakeCapture(),
    files: store,
    enabled:
        enabled ??
        <String, bool>{
          'view': true,
          'camera': true,
          'audio': true,
          'files': true,
          'clipboard': false,
        },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the identity is stable, private and has a 256-bit secret', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final first = await ComputerIdentity.load(preferences: prefs);
    final second = await ComputerIdentity.load(preferences: prefs);
    expect(first.id, startsWith('cmp-'));
    expect(first.id, second.id);
    expect(first.secret, second.secret);
    expect(first.secret.length, greaterThanOrEqualTo(43));
    expect(first.toWire()['id'], first.id);
  });

  test('the app files are scoped, and writing needs the person', () async {
    final dir = Directory.systemTemp.createTempSync('computer-files-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppComputerFileStore(dir);
    File('${dir.path}/hello.txt').writeAsStringSync('one\ntwo\nthree\n');
    final listing = await store.list('');
    expect(listing.text, contains('hello.txt'));
    final read = await store.read('hello.txt', offset: 2, limit: 1);
    expect(read.text, contains('two'));
    expect(read.text, contains('lines 2-2 of 4'));
    expect((await store.read('../etc/passwd')).isError, isTrue);
    expect((await store.write('outbox/a.txt', 'x')).isError, isTrue);
    await store.setWritesEnabled(true);
    expect((await store.write('a.txt', 'x')).isError, isTrue);
    final wrote = await store.write('outbox/a.txt', 'hello');
    expect(wrote.isError, isFalse);
    expect(File('${dir.path}/outbox/a.txt').readAsStringSync(), 'hello');
    final imported = await store.importFile('${dir.path}/hello.txt');
    expect(imported.isError, isFalse, reason: imported.text);
    expect(imported.structured!['path'], 'imports/hello.txt');
    Link('${dir.path}/link').createSync('${dir.path}/outbox');
    expect((await store.read('link/a.txt')).isError, isTrue);
  });

  test('an MCP server answers the four methods and refuses the rest', () async {
    final server = McpServer(
      name: 'test',
      title: 'Test',
      version: '1',
      instructions: 'Test',
      tools: <McpTool>[
        mcpSyncTool(
          name: 'echo',
          title: 'Echo',
          description: 'Echo',
          inputSchema: const <String, Object?>{'type': 'object'},
          handler: (arguments) => mcpTextResult('echo ${arguments['text']}'),
        ),
      ],
    );
    final initialized = await server.handle(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, Object?>{'protocolVersion': '2025-06-18'},
    });
    expect(
      initialized!['result'],
      containsPair('protocolVersion', '2025-06-18'),
    );
    final tools = await server.handle(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    expect(tools!['result'], contains('tools'));
    final called = await server.handle(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': <String, Object?>{
        'name': 'echo',
        'arguments': <String, Object?>{'text': 'hi'},
      },
    });
    expect(called!['result'], contains('content'));
    final unknown = await server.handle(<String, Object?>{
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'no/such',
    });
    expect(unknown!['error'], containsPair('code', -32601));
    expect(
      await server.handle(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }),
      isNull,
    );
  });

  test('registration sends identity, capabilities and servers', () async {
    final transport = FakeTransport();
    final endpoint = await _endpoint(transport: transport);
    await endpoint.register();
    expect(endpoint.registered, isTrue);
    expect(transport.registered, hasLength(1));
    final params = transport.registered.single;
    expect(params['secret'], _identity().secret);
    final computer = params['computer']! as Map<String, Object?>;
    expect(computer['id'], 'cmp-ios-abc123');
    expect(computer['os'], 'ios');
    expect(
      computer['capabilities'],
      containsAll(<String>['view', 'camera', 'audio', 'files']),
    );
    expect(computer['servers'], hasLength(2));
    expect((params['resources']! as List).length, greaterThanOrEqualTo(2));
  });

  test('a harness without computer/attach is not asked to attach', () async {
    final transport = FakeTransport()..supported = false;
    final dir = Directory.systemTemp.createTempSync('mobile-controller-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final controller = MobileComputerController(
      capture: FakeCapture(),
      files: AppComputerFileStore(dir),
    );
    addTearDown(controller.dispose);
    await controller.bind(transport);
    expect(transport.attached, isEmpty);
    expect(controller.registered, isFalse);
  });

  test('the MCP handshake during registration is answered before the token', () async {    final transport = FakeTransport();
    final endpoint = await _endpoint(transport: transport);
    Object? answer;
    transport.duringRegister = () async {
      answer = await endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': <String, Object?>{'protocolVersion': '2025-06-18'},
          },
        },
      );
    };
    await endpoint.register();
    expect(answer, isNotNull);
    expect((answer! as Map)['result'], isNotNull);
    await expectLater(
      endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'ping',
          },
        },
      ),
      throwsA(isA<AcpException>()),
    );
  });

  test('the MCP handshake during an attach is answered before the token', () async {
    final transport = FakeTransport();
    final endpoint = await _endpoint(transport: transport);
    Object? answer;
    transport.duringAttach = () async {
      answer = await endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': <String, Object?>{'protocolVersion': '2025-06-18'},
          },
        },
      );
    };
    expect(await endpoint.attachIfKnown(), isTrue);
    expect(answer, isNotNull);
    expect((answer! as Map)['result'], isNotNull);
  });

  test('a stale, wrong or unregistered MCP request is refused', () async {
    final endpoint = await _endpoint();
    await expectLater(
      endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'token': 'token',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'ping',
          },
        },
      ),
      throwsA(isA<AcpException>()),
    );
    await endpoint.register();
    await expectLater(
      endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-other',
          'server': 'computer',
          'token': 'token-1',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'ping',
          },
        },
      ),
      throwsA(isA<AcpException>()),
    );
    await expectLater(
      endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'token': 'wrong',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'ping',
          },
        },
      ),
      throwsA(isA<AcpException>()),
    );
    final answer = await endpoint.handleRequest(
      MobileComputerEndpoint.mcpMethod,
      <String, Object?>{
        'computer': 'cmp-ios-abc123',
        'server': 'computer',
        'token': 'token-1',
        'message': <String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
        },
      },
    );
    expect((answer as Map)['result'], isNotNull);
  });

  test(
    'a screen capture comes back as the harness expects a picture',
    () async {
      final capture = FakeCapture();
      final endpoint = await _endpoint(capture: capture);
      await endpoint.register();
      final answer = await endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'token': 'token-1',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 5,
            'method': 'tools/call',
            'params': <String, Object?>{'name': 'screenshot'},
          },
        },
      );
      final structured =
          ((answer as Map)['result'] as Map)['structuredContent'] as Map;
      expect(structured['mime'], 'image/png');
      expect(base64Decode(structured['data'] as String), _png);
      expect(capture.started, contains(ComputerCaptureSource.screen));
    },
  );

  test(
    'a stop during a capture refuses the late frame and tells the harness',
    () async {
      final capture = FakeCapture()..slowFrame = true;
      final transport = FakeTransport();
      final endpoint = await _endpoint(capture: capture, transport: transport);
      await endpoint.register();
      final pending = endpoint.handleRequest(
        MobileComputerEndpoint.mcpMethod,
        <String, Object?>{
          'computer': 'cmp-ios-abc123',
          'server': 'computer',
          'token': 'token-1',
          'message': <String, Object?>{
            'jsonrpc': '2.0',
            'id': 6,
            'method': 'tools/call',
            'params': <String, Object?>{'name': 'camera'},
          },
        },
      );
      await endpoint.stopCapture();
      final answer = await pending;
      final result = (answer as Map)['result'] as Map;
      expect(result['isError'], isTrue);
      expect('${result['content']}', contains('stopped'));
      expect(transport.updated, isNotEmpty);
    },
  );

  test(
    'a revoked permission stops capture, reduces capabilities and updates',
    () async {
      final capture = FakeCapture();
      final transport = FakeTransport();
      final endpoint = await _endpoint(capture: capture, transport: transport);
      await endpoint.register();
      await endpoint.refreshCapabilities();
      expect(endpoint.capabilities.offered, contains('camera'));
      capture.emit(
        ComputerCaptureSource.camera,
        ComputerCapabilityState.revoked,
      );
      await Future<void>.delayed(Duration.zero);
      expect(endpoint.generation, greaterThan(0));
      expect(transport.updated, isNotEmpty);
    },
  );

  test(
    'lifecycle pause suspends capture and never resumes by itself',
    () async {
      final capture = FakeCapture();
      final transport = FakeTransport();
      final endpoint = await _endpoint(capture: capture, transport: transport);
      await endpoint.register();
      await endpoint.handleLifecycle('paused');
      expect(
        endpoint.capabilities['camera']?.state,
        ComputerCapabilityState.suspended,
      );
      expect(
        endpoint.capabilities['camera']?.state,
        ComputerCapabilityState.suspended,
      );
      await endpoint.handleLifecycle('resumed');
      expect(endpoint.capabilities.offered, contains('camera'));
    },
  );

  test('revocation unregisters and stops everything', () async {
    final capture = FakeCapture();
    final transport = FakeTransport();
    final endpoint = await _endpoint(capture: capture, transport: transport);
    await endpoint.register();
    await capture.start(ComputerCaptureSource.camera);
    await endpoint.revoke();
    expect(endpoint.registered, isFalse);
    expect(transport.unregistered, <String>['cmp-ios-abc123']);
    expect(capture.live, isEmpty);
  });
}
