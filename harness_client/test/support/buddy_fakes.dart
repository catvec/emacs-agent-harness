import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:harness_client/src/models/workspace.dart';
import 'package:harness_client/src/state/workspace_buddy_controller.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_buddy.dart';
import 'package:harness_client/src/voice/voice_settings.dart';

import 'voice_fakes.dart';

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

WorkspaceSummary home({String? live = 's1'}) => WorkspaceSummary(
  id: 'w1',
  name: 'Home',
  lastThread: 't1',
  threads: [
    WorkspaceThread(
      id: 't1',
      title: 'Kitchen renovation',
      state: live == null ? 'parked' : 'live',
      live: live,
    ),
  ],
);

WorkspaceSummary work() => const WorkspaceSummary(
  id: 'w2',
  name: 'Work',
  lastThread: 't2',
  threads: [WorkspaceThread(id: 't2', title: 'Release notes', state: 'parked')],
);

/// The app seam, with a scripted workspace and the existing fake session.
class BuddyHost extends ChangeNotifier implements WorkspaceBuddyHost {
  BuddyHost({WorkspaceSummary? workspace})
    : _workspace = workspace ?? home(),
      _thread = (workspace ?? home()).threads.first;

  WorkspaceSummary? _workspace;
  WorkspaceThread? _thread;
  final ChangeNotifier context = ChangeNotifier();
  final FakeSession session = FakeSession();
  BuddyConnection connection = BuddyConnection.connected;
  VoiceSettings voiceSettings = const VoiceSettings(
    clipDelivery: ClipDelivery.audioPrompt,
  );
  final Set<String> enabledIds = <String>{};
  final List<bool> writes = <bool>[];
  final List<String> opened = <String>[];
  int opens = 0;
  bool noBridge = false;
  Object? bridgeError;

  @override
  WorkspaceSummary? get buddyWorkspace => _workspace;

  @override
  WorkspaceThread? get buddyThread => _thread;

  @override
  BuddyConnection get buddyConnection => connection;

  @override
  String get buddyHarnessAddress => 'ws://harness.test:9999/acp';

  @override
  VoiceSettings get buddyVoiceSettings => voiceSettings;

  @override
  Listenable? get buddyContextListenable => context;

  @override
  bool get buddyEnabled =>
      _workspace != null && enabledIds.contains(_workspace!.id);

  @override
  Future<void> setBuddyEnabled(bool enabled) async {
    final id = _workspace?.id;
    if (id == null) return;
    if (enabled) {
      enabledIds.add(id);
    } else {
      enabledIds.remove(id);
    }
    writes.add(enabled);
    notifyListeners();
  }

  @override
  VoiceSessionBridge? openBuddyBridge(String sessionId) {
    opens++;
    opened.add(sessionId);
    if (bridgeError != null) throw bridgeError!;
    if (noBridge) return null;
    return session;
  }

  @override
  Future<void> saveBuddyVoiceSettings(VoiceSettings next) async {
    voiceSettings = next;
    notifyListeners();
  }

  void showWorkspace(WorkspaceSummary next, {WorkspaceThread? thread}) {
    _workspace = next;
    _thread = thread ?? (next.threads.isEmpty ? null : next.threads.first);
    notifyListeners();
  }

  void showThread(WorkspaceThread thread) {
    _thread = thread;
    notifyListeners();
  }

  void setConnection(BuddyConnection next) {
    connection = next;
    notifyListeners();
  }
}

class BuddyRig {
  BuddyRig({WorkspaceSummary? workspace, FakeBackend Function()? backends})
    : host = BuddyHost(workspace: workspace),
      backendBuilder = backends ?? FakeBackend.new {
    controller = WorkspaceBuddyController(
      host: host,
      backendFactory: (settings, address, bridge) {
        final backend = backendBuilder();
        this.backends.add(backend);
        return backend;
      },
      mediaButtons: FakeMediaButtons(),
    );
  }

  final BuddyHost host;
  final FakeBackend Function() backendBuilder;
  final List<FakeBackend> backends = <FakeBackend>[];
  late final WorkspaceBuddyController controller;

  Future<void> start() async {
    await controller.enable();
    await controller.start();
    await settle();
  }

  Future<void> dispose() async {
    controller.dispose();
    await settle();
  }
}
