// Try the desktop buddy's own window without a harness or a real call.
//
//   tool/buddy_window_probe.sh            (or flutter run -d linux -t ...)
//
// The probe draws the real card in the real native window with a scripted
// call, so the window's own behaviour -- its frame, its size, where it
// stacks -- can be looked at and measured.  `--failed` shows the taller card
// of a call that could not start; `--no-window` draws no native window at
// all, for the fallback card.  `--capture=PATH` writes a PNG of the card as
// the window renders it after the first layout, which needs no compositor
// screenshot and works where the sandbox has no GPU.
//
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

// This is a probe, not the app: the call is a fake backend and the host has
// one workspace.  It is not part of the shipped client.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:harness_client/src/desktop/buddy_window.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/workspace_buddy_controller.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/buddy_window_host.dart';
import 'package:harness_client/src/ui/widgets/workspace_buddy.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_models.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

void main(List<String> args) {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();
  final failed = args.contains('--failed');
  final noWindow = args.contains('--no-window');
  final capture = _valueOf(args, '--capture');
  runApp(_ProbeApp(failed: failed, noWindow: noWindow, capture: capture));
}

String? _valueOf(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp({
    required this.failed,
    required this.noWindow,
    this.capture,
  });

  final bool failed;
  final bool noWindow;
  final String? capture;

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  late final BuddyWindowService _window = createBuddyWindowService();
  late final _ProbeHost _host = _ProbeHost();
  late final WorkspaceBuddyController _buddy = WorkspaceBuddyController(
    host: _host,
    backendFactory: (settings, address, bridge) => _ProbeBackend(),
  );
  final GlobalKey _captureKey = GlobalKey();
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    _host.enabled = true;
    if (widget.failed) {
      _host.bridgeAvailable = false;
    }
    await _buddy.start();
    if (!mounted) return;
    if (widget.failed) {
      // A start that could not open its session keeps the failed card, and
      // that card is taller than a running one.
      setState(() {});
    }
  }

  /// The card is a few frames and a window resize old when the window has
  /// settled; capture then, from the probe's own layer tree.
  Future<void> _captureWhenSettled() async {
    final path = widget.capture;
    if (path == null) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final object = _captureKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return;
    final image = await object.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    await File(path).writeAsBytes(data.buffer.asUint8List(), flush: true);
    // ignore: avoid_print
    print('PROBE capture $path ${object.size.width}x${object.size.height}');
  }

  @override
  void dispose() {
    _buddy.dispose();
    _window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _window.wrap(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HarnessTheme.material(Brightness.dark),
        home: Builder(
          builder: (context) {
            if (!widget.noWindow && !_requested) {
              _requested = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                final width = WorkspaceBuddyView.widthFor(context);
                _window.show(
                  context,
                  BuddyWindowRequest(
                    controller: _buddy,
                    width: width,
                    builder: (context, startDrag) => RepaintBoundary(
                      key: _captureKey,
                      child: BuddyWindowContent(
                        buddy: _buddy,
                        width: width,
                        theme: Theme.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                        disableAnimations:
                            MediaQuery.disableAnimationsOf(context),
                        startDrag: startDrag,
                        onActivated: _window.reportActivated,
                        onContentSize: _window.reportContentSize,
                        onOpenWorkspace: () {},
                        onOpenSettings: () async {},
                      ),
                    ),
                  ),
                );
                _captureWhenSettled();
              });
            }
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Buddy window probe'),
                    const SizedBox(height: 8),
                    Text('mode: ${widget.failed ? 'failed' : 'running'}'),
                    const SizedBox(height: 8),
                    Text('window: ${widget.noWindow ? 'none' : 'native'}'),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProbeHost extends ChangeNotifier implements WorkspaceBuddyHost {
  bool enabled = false;
  bool bridgeAvailable = true;
  final _ProbeBridge bridge = _ProbeBridge();

  static const _workspace = WorkspaceSummary(
    id: 'probe-workspace',
    name: 'Home',
    threads: [
      WorkspaceThread(
        id: 'probe-thread',
        title: 'Kitchen renovation',
        state: 'live',
        live: 'probe-session',
      ),
    ],
  );

  @override
  WorkspaceSummary? get buddyWorkspace => _workspace;

  @override
  WorkspaceThread? get buddyThread => _workspace.threads.first;

  @override
  BuddyConnection get buddyConnection => BuddyConnection.connected;

  @override
  String get buddyHarnessAddress => 'ws://probe.test:9999/acp';

  @override
  VoiceSettings get buddyVoiceSettings =>
      const VoiceSettings(clipDelivery: ClipDelivery.audioPrompt);

  @override
  Listenable? get buddyContextListenable => null;

  @override
  bool get buddyEnabled => enabled;

  @override
  Future<void> setBuddyEnabled(bool value) async {
    enabled = value;
    notifyListeners();
  }

  @override
  VoiceSessionBridge? openBuddyBridge(String sessionId) =>
      bridgeAvailable ? bridge : null;

  @override
  Future<void> saveBuddyVoiceSettings(VoiceSettings settings) async {}
}

class _ProbeBridge implements VoiceSessionBridge {
  @override
  bool get working => false;
  @override
  bool get blocked => false;
  @override
  String? get model => 'probe:model';
  @override
  String get sessionId => 'probe-session';
  @override
  String get sessionTitle => 'Kitchen renovation';
  @override
  String get cwd => '/tmp/probe';
  @override
  List<String> get history => const [];
  @override
  Future<void> send(VoicePrompt prompt) async {}
  @override
  void addReplyListener(void Function(String text) listener) {}
  @override
  void removeReplyListener(void Function(String text) listener) {}
  @override
  void addSessionListener(void Function() listener) {}
  @override
  void removeSessionListener(void Function() listener) {}
}

class _ProbeBackend implements VoiceBackend {
  final _events = StreamController<VoiceBackendEvent>.broadcast();

  @override
  Stream<VoiceBackendEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    _events.add(const VoicePhaseEvent(VoicePhase.listening));
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> speak(String text, {String? replyId}) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {
    await _events.close();
  }
}
