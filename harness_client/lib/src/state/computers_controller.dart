import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../models/computer.dart';
import '../services/harness_api.dart';

/// The Computers page's state: the machines the harness may use, what the
/// open session may do there, and the resources they offer.
///
/// A page with no session still lists the computers: viewing is not a
/// session's permission.  Grants, revocations and the control toggle are the
/// session's, so they are offered only when [sessionId] names one.
class ComputersController extends ChangeNotifier {
  ComputersController(HarnessApi? api, {this.sessionId})
    : _api = api,
      preview = false;

  /// A controller with sample data and no harness behind it, for the widget
  /// tests and the pictures.  Its actions change nothing.
  ComputersController.preview({this.sessionId = 's1'})
    : _api = null,
      preview = true {
    computers = _previewComputers();
    access = _previewAccess();
    resources = [
      for (final computer in computers) ...computer.resources,
    ];
  }

  final HarnessApi? _api;
  final String? sessionId;
  final bool preview;

  List<Computer> computers = const [];
  ComputerAccess? access;
  List<ComputerResource> resources = const [];
  bool loading = false;
  bool busy = false;
  String? error;
  String? notice;

  bool get canLoad => preview || (_api?.can('computer/list') ?? false);
  bool get hasSession => (sessionId ?? '').isNotEmpty;
  bool get canManage => !preview && hasSession && !busy;
  bool get canControl => !preview && !busy;

  Computer? get preferred {
    final id = access?.preferred;
    if (id == null) return null;
    for (final computer in computers) {
      if (computer.id == id) return computer;
    }
    return null;
  }

  Future<void> load({bool showSpinner = true}) async {
    if (preview) {
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null || !api.can('computer/list')) {
      computers = const [];
      access = null;
      resources = const [];
      error = null;
      notifyListeners();
      return;
    }
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      final id = sessionId ?? '';
      final results = await Future.wait<Object>([
        api.computers(sessionId: id.isEmpty ? null : id),
        api.computerResources(),
        if (id.isNotEmpty) api.computerAccess(id),
      ]);
      computers = results[0] as List<Computer>;
      resources = results[1] as List<ComputerResource>;
      access = id.isEmpty ? null : results[2] as ComputerAccess;
    } on AcpException catch (failure) {
      error = failure.isMethodNotFound ? null : failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() => load(showSpinner: false);

  Future<void> grant(Computer computer, {List<String>? capabilities}) =>
      _sessionChange(
        (api, id) => api.computerGrant(
          id,
          computer.id,
          capabilities: capabilities,
        ),
        'Granted',
      );

  Future<void> revoke(Computer computer) => _sessionChange(
    (api, id) => api.computerRevoke(id, computer.id),
    'Revoked',
  );

  Future<void> toggleCapability(Computer computer, String capability) {
    final on = !computer.allows(capability);
    return _sessionChange(
      (api, id) => api.computerGrantCapability(
        id,
        computer.id,
        capability,
        on,
      ),
      on ? 'Capability granted' : 'Capability revoked',
    );
  }

  Future<void> prefer(Computer computer) => _sessionChange(
    (api, id) => api.computerPrefer(id, computer.id),
    'Preferred',
  );

  Future<void> _sessionChange(
    Future<ComputerAccess> Function(HarnessApi api, String id) change,
    String done,
  ) async {
    final api = _api;
    final id = sessionId ?? '';
    if (preview || api == null || id.isEmpty || busy) return;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      access = await change(api, id);
      notice = done;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> takeControl(Computer computer) => _control(
    computer,
    (api) => api.computerTakeControl(computer.id),
    'Watching',
  );

  Future<void> releaseControl(Computer computer) => _control(
    computer,
    (api) => api.computerReleaseControl(computer.id),
    'Returned',
  );

  Future<void> _control(
    Computer computer,
    Future<Computer> Function(HarnessApi api) change,
    String done,
  ) async {
    final api = _api;
    if (preview || api == null || busy) return;
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final changed = await change(api);
      computers = [
        for (final item in computers)
          if (item.id == changed.id) changed else item,
      ];
      notice = done;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  static List<Computer> _previewComputers() => [
    Computer.preview(
      resources: const [
        ComputerResource(
          id: 'git-repo-harness',
          kind: 'git-repo',
          name: 'harness',
          path: '/home/noah/documents/ai/emacs-agent-harness',
          branch: 'main',
          computer: 'local',
          computerName: 'marcuse',
          project: true,
        ),
        ComputerResource(
          id: 'dir-screens',
          kind: 'directory',
          name: 'screens',
          path: '/home/noah/screens',
          computer: 'local',
          computerName: 'marcuse',
        ),
      ],
    ),
    Computer(
      id: 'cmp-studio-a1b2c3',
      name: 'studio',
      kind: 'client',
      state: 'connected',
      connected: true,
      host: 'studio',
      os: 'darwin',
      arch: 'arm64',
      display: ':0',
      vnc: 'http://studio:6080/vnc_lite.html',
      vncSocket: 'ws://studio:6080/websockify',
      capabilities: const [
        ComputerCapability(name: 'view', doc: 'See the screen, or one window'),
        ComputerCapability(name: 'pointer', doc: 'Move, click, scroll, drag'),
        ComputerCapability(name: 'keyboard', doc: 'Type text, press a key'),
      ],
      capabilityNames: const ['view', 'pointer', 'keyboard'],
      servers: const ['computer'],
      resources: const [
        ComputerResource(
          id: 'git-repo-atlas',
          kind: 'git-repo',
          name: 'atlas',
          path: '/Users/noah/src/atlas',
          branch: 'trunk',
          computer: 'cmp-studio-a1b2c3',
          computerName: 'studio',
          project: true,
        ),
      ],
      allowed: false,
      why: 'a grant is not held',
      control: 'agent',
      lastSeen: DateTime(2026, 11, 8, 11, 30),
    ),
  ];

  static ComputerAccess _previewAccess() => const ComputerAccess(
    session: 's1',
    policy: 'local',
    preferred: 'local',
    available: ['local', 'cmp-studio-a1b2c3'],
    entries: [
      ComputerAccessEntry(
        id: 'local',
        name: 'marcuse',
        kind: 'local',
        state: 'connected',
        connected: true,
        allowed: true,
        why: 'the local computer',
        capabilitiesAllowed: [
          'view',
          'windows',
          'pointer',
          'keyboard',
          'sandbox',
        ],
      ),
      ComputerAccessEntry(
        id: 'cmp-studio-a1b2c3',
        name: 'studio',
        kind: 'client',
        state: 'connected',
        connected: true,
        allowed: false,
        why: 'a grant is not held',
      ),
    ],
  );
}
