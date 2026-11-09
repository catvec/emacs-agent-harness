import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/capabilities.dart';
import 'package:harness_client/src/acp/websocket_transport.dart';
import 'package:harness_client/src/computer/app_computer_file_store.dart';
import 'package:harness_client/src/computer/computer_capabilities.dart';
import 'package:harness_client/src/computer/computer_capture_port.dart';
import 'package:harness_client/src/computer/mobile_computer_controller.dart';
import 'package:harness_client/src/computer/mobile_computer_endpoint.dart';
import 'package:harness_client/src/services/harness_api.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

class _Capture implements ComputerCapturePort {
  final _events = StreamController<ComputerCaptureEvent>.broadcast();
  final Set<ComputerCaptureSource> live = <ComputerCaptureSource>{};

  @override
  Future<Map<ComputerCaptureSource, ComputerCapabilityStatus>> capabilities() async => {
    for (final source in ComputerCaptureSource.values)
      source: const ComputerCapabilityStatus(state: ComputerCapabilityState.available),
  };

  @override
  Stream<ComputerCaptureEvent> get statuses => _events.stream;

  @override
  Future<void> start(ComputerCaptureSource source) async => live.add(source);

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
  }) async => live.contains(source) ? Uint8List.fromList(_png) : null;

  @override
  Future<Uint8List?> captureAudio({Duration max = const Duration(seconds: 10)}) async =>
      live.contains(ComputerCaptureSource.microphone)
          ? Uint8List.fromList(<int>[82, 73, 70, 70])
          : null;

  @override
  Future<void> handleLifecycle(String state) async {}

  @override
  Future<void> dispose() async => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final token = Platform.environment['HARNESS_SERVER_TOKEN'] ?? '';
  final enabled =
      Platform.environment['HARNESS_MOBILE_E2E'] == '1' && token.isNotEmpty;
  test(
    'a real harness registers the phone and its tools answer over ACP',
    () async {
      final repo = Directory.current.parent.path;
      final state = Directory.systemTemp.createTempSync('mobile-e2e-state-');
      final filesRoot = Directory.systemTemp.createTempSync('mobile-e2e-files-');
      addTearDown(() {
        if (state.existsSync()) state.deleteSync(recursive: true);
        if (filesRoot.existsSync()) filesRoot.deleteSync(recursive: true);
      });
      Directory('${state.path}/state').createSync(recursive: true);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final wsPort = probe.port;
      await probe.close();
      final config = File('${state.path}/server.el')
        ..writeAsStringSync('''
(setq harness-enabled-modules t)
(setq harness-acp-remote t)
(setq harness-acp-remote-host "127.0.0.1")
(setq harness-acp-remote-port $wsPort)
(setq harness-model "demo:scripted")
(setq harness-supervisor nil)
(setq harness-permission-mode 'yolo)
(setq harness-state-directory "${state.path}/state/")
''');
      final process = await Process.start(
        '$repo/scripts/harness-server',
        const <String>[],
        workingDirectory: repo,
        environment: <String, String>{
          ...Platform.environment,
          'HARNESS_SERVER_HOST': '127.0.0.1',
          'HARNESS_SERVER_PORT': '0',
          'HARNESS_SERVER_TOKEN': token,
          'HARNESS_SERVER_CONFIG': config.path,
        },
      );
      addTearDown(() => process.kill());
      final lines = <String>[];
      final address = Completer<String>();
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            lines.add(line);
            if (line.startsWith('HARNESS-ACP-ADDRESS ') && !address.isCompleted) {
              address.complete(line.substring('HARNESS-ACP-ADDRESS '.length));
            }
          });
      await address.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw StateError('server did not listen:\n${lines.join('\n')}'),
      );
      final uri = Uri.parse('ws://127.0.0.1:$wsPort/acp');
      final transport = await WebSocketAcpTransport.connect(
        uri,
        token: token,
      );
      final client = AcpClient(transport);
      addTearDown(client.close);
      final files = AppComputerFileStore(filesRoot);
      Directory('${filesRoot.path}/imports').createSync(recursive: true);
      File('${filesRoot.path}/imports/hello.txt').writeAsStringSync('hello from the phone\n');
      final controller = MobileComputerController(
        capture: _Capture(),
        files: files,
      );
      addTearDown(controller.dispose);
      final initialized = await client.initialize(
        clientTitle: 'Mobile E2E',
        clientCapabilities: controller.clientCapabilities(),
      );
      await client.authenticate(methodId: 'token', token: token);
      final api = HarnessApi(client, HarnessCapabilities.fromInitialize(initialized));
      addTearDown(api.dispose);
      await controller.bind(HarnessComputerTransport(api));
      await controller.setEnabled('camera', true);
      await controller.setEnabled('view', true);
      await controller.setEnabled('files', true);
      client.requestHandler = (method, params) async {
        final answer = await controller.handleRequest(method, params);
        if (answer != null) return answer;
        throw AcpException(-32601, 'Method not found: $method');
      };
      await controller.register();
      expect(controller.registered, isTrue, reason: controller.error);
      final computers = await api.computers();
      expect(
        computers.map((computer) => computer.id),
        contains(controller.machineId),
      );
      final session = await client.request('session/new', <String, Object?>{
        'cwd': filesRoot.path,
        'mcpServers': const <Object?>[],
        '_harness': <String, Object?>{'model': 'demo:scripted'},
      });
      final sessionId = (session as Map)['sessionId'] as String;
      await client.request('session/set_mode', <String, Object?>{
        'sessionId': sessionId,
        'modeId': 'yolo',
      });
      await client.request(
        'session/prompt',
        <String, Object?>{
          'sessionId': sessionId,
          'prompt': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'mobile computer demo'},
          ],
        },
        const Duration(seconds: 120),
      );
      final nodes = await api.sessionNodes(sessionId);
      final calls = <String>[
        for (final node in nodes)
          if (node['kind'] == 'tool-call') '${node['tool']}',
      ];
      final results = <Map<String, Object?>>[
        for (final node in nodes)
          if (node['kind'] == 'tool-result') node,
      ];
      expect(calls, containsAll(<String>['computer_camera', 'computer_view', 'computer_call']));
      expect(results, isNotEmpty);
      expect(
        results.where((node) => node['is-error'] == true),
        isEmpty,
        reason: results.map((node) => node['output']).join('\n'),
      );
      final output = results.map((node) => '${node['output']}').join('\n');
      expect(output, contains('Camera of'));
      expect(output, contains('Screen of'));
      expect(output, contains('hello.txt'));
      expect(output, contains('hello from the phone'));
      // The registration is the phone's, not a local machine's.
      final record = computers.firstWhere((c) => c.id == controller.machineId);
      expect(record.kind, 'client');
      expect(record.connected, isTrue);
    },
    skip: enabled ? false : 'Set HARNESS_MOBILE_E2E=1 with emacs on PATH',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
