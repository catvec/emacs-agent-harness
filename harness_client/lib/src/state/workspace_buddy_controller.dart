import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/workspace.dart';
import '../voice/voice_backend.dart';
import '../voice/voice_buddy.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_media_buttons.dart';
import '../voice/voice_models.dart';
import '../voice/voice_settings.dart';

/// What the buddy needs from the app: the selected workspace and thread,
/// the connection it depends on, the device's voice settings, the existing
/// session bridge and the per-workspace opt-in.  It is an interface so the
/// lifecycle can be tested with a scripted host and no harness.
abstract class WorkspaceBuddyHost implements Listenable {
  WorkspaceSummary? get buddyWorkspace;

  /// The thread a new call would attach to: the workspace's active thread.
  WorkspaceThread? get buddyThread;

  BuddyConnection get buddyConnection;

  String get buddyHarnessAddress;

  VoiceSettings get buddyVoiceSettings;

  /// The workspace controller, whose thread selection can change while the
  /// buddy is on screen.
  Listenable? get buddyContextListenable;

  bool get buddyEnabled;

  Future<void> setBuddyEnabled(bool enabled);

  /// The existing session bridge for [sessionId], or null when there is no
  /// such conversation.  This is the same bridge `VoiceScreen` uses.
  VoiceSessionBridge? openBuddyBridge(String sessionId);

  Future<void> saveBuddyVoiceSettings(VoiceSettings settings);
}

/// What a buddy call opens its backend with: the existing platform seam,
/// resolved for the bridge of the call being started.  It keeps the buddy on
/// the same backend factory as the full voice screen, one call at a time.
typedef WorkspaceBuddyBackendFactory = VoiceBackend Function(
  VoiceSettings settings,
  String harnessAddress,
  VoiceSessionBridge session,
);

/// One workspace's compact voice presence: at most one voice call, the
/// existing [VoiceController] and [VoiceSessionBridge], and the safe
/// lifecycle around them.
///
/// It never starts a call on its own, never resumes after a reconnect and
/// never leaves a hidden call recording: every path out of a running call
/// goes through [end], which stops the backend before the card goes away.
class WorkspaceBuddyController extends ChangeNotifier {
  WorkspaceBuddyController({
    required this.host,
    required WorkspaceBuddyBackendFactory backendFactory,
    VoiceMediaButtons? mediaButtons,
  }) : _backendFactory = backendFactory,
       _mediaButtons = mediaButtons {
    host.addListener(_hostChanged);
    _context = host.buddyContextListenable;
    _context?.addListener(_hostChanged);
  }

  final WorkspaceBuddyHost host;
  final WorkspaceBuddyBackendFactory _backendFactory;
  final VoiceMediaButtons? _mediaButtons;

  Listenable? _context;
  VoiceController? _voice;

  /// Calls that were stopped and let go.  They are disposed when the next
  /// call opens or when this controller does, never straight after a stop: a
  /// call view that is still on screen must be able to remove its listener
  /// from the controller it showed, which a controller disposed under it
  /// would refuse.
  final List<VoiceController> _retired = <VoiceController>[];
  VoiceProblem? _startProblem;

  String? _callWorkspaceId;
  String? _callWorkspaceName;
  String? _callThreadTitle;
  VoiceProvider? _callProvider;

  bool _starting = false;
  bool _ending = false;
  bool _connectionLost = false;
  bool _callLost = false;
  bool _disposed = false;
  int _generation = 0;

  /// Whether the buddy is opted in for the selected workspace.
  bool get enabled => host.buddyEnabled && host.buddyWorkspace != null;

  /// Whether a call is running or being opened.
  bool get running => _starting || (_voice != null && !_voice!.phase.finished);

  /// Whether this workspace has a call surface: opening, running, ending or
  /// failed.  The in-call bar shows while this is true; a call that ended
  /// normally, or was lost, leaves nothing behind.
  bool get inCall => _ending || _starting || _voice != null;

  /// A name for the page's actions: the buddy owns a call for the
  /// workspace, so its full-screen Call action gives way.
  bool get callActive => running;

  /// Whether the full call view is on screen.  The in-call bar gives way to
  /// it; the call itself is the same one.
  bool get callViewOpen => _callViewOpen;
  bool _callViewOpen = false;

  set callViewOpen(bool open) {
    if (_callViewOpen == open) return;
    _callViewOpen = open;
    if (!_disposed) notifyListeners();
  }

  bool get starting => _starting;
  bool get ending => _ending;
  bool get muted => _voice?.muted ?? false;
  bool get paused => _voice?.paused ?? false;

  VoiceController? get voice => _voice;

  /// The thread a call is pinned to while it runs, else the active one.
  String? get threadTitle => _callThreadTitle ?? host.buddyThread?.title;

  String get workspaceName {
    final name = _callWorkspaceName ?? host.buddyWorkspace?.name ?? '';
    return name.trim().isEmpty ? 'Workspace' : name;
  }

  bool get _configured =>
      host.buddyVoiceSettings.configuredFor(host.buddyHarnessAddress);

  bool get _connected => host.buddyConnection == BuddyConnection.connected;

  bool get canStart =>
      !_disposed &&
      !_ending &&
      !running &&
      _connected &&
      _configured &&
      host.buddyThread?.live != null;

  /// Whether End has something to clear: a call opening, running, or failed
  /// with the controller still held, so a fatal problem can be dismissed
  /// without opening another call.
  bool get canEnd =>
      !_disposed &&
      !_ending &&
      (_starting || _voice != null);

  bool get canMute =>
      _voice != null && !_voice!.phase.finished && !_voice!.paused;

  bool get canPause => _voice != null && !_voice!.phase.finished;

  bool get canInterrupt =>
      _voice != null && !_voice!.phase.finished && !_voice!.paused;

  VoiceProblem? get problem => _voice?.problem ?? _startProblem;

  bool get canRetry {
    if (_disposed || _ending || _starting) return false;
    if (!_connected) return false;
    if (problem == null) return false;
    if (_voice != null && !_voice!.phase.finished) return true;
    return host.buddyThread?.live != null;
  }

  /// The safe-lifecycle note: what happened to a call, or why Start is not
  /// available.  Null when there is nothing to say.
  String? get note {
    if (_connectionLost) return 'Connection lost';
    if (_callLost) return 'Call lost';
    if (running) return null;
    if (host.buddyThread?.live == null) return 'No live episode';
    if (!_configured) return 'Voice setup';
    return null;
  }

  /// The whole card state, resolved from what is actually reported.
  BuddyViewModel get model {
    final voice = _voice;
    final BuddyStatus status;
    if (_ending) {
      status = const BuddyStatus(
        phase: BuddyPhase.ending,
        mic: BuddyMic.closing,
      );
    } else if (voice != null) {
      status = buddyStatusFor(voice);
    } else if (_starting) {
      status = const BuddyStatus(
        phase: BuddyPhase.starting,
        mic: BuddyMic.starting,
      );
    } else if (_startProblem != null) {
      status = const BuddyStatus(phase: BuddyPhase.failed, mic: BuddyMic.off);
    } else {
      status = const BuddyStatus(phase: BuddyPhase.off, mic: BuddyMic.off);
    }
    return BuddyViewModel(
      workspaceName: workspaceName,
      threadTitle: threadTitle,
      connection: host.buddyConnection,
      connectionDetail: host.buddyHarnessAddress,
      providerLabel: switch (_callProvider ??
          host.buddyVoiceSettings.provider) {
        VoiceProvider.clip => 'Clip',
        VoiceProvider.live => 'Live',
      },
      status: status,
      muted: voice?.muted ?? false,
      paused: voice?.paused ?? false,
      starting: _starting,
      running: running,
      canStart: canStart,
      canEnd: canEnd,
      canMute: canMute,
      canPause: canPause,
      canInterrupt: canInterrupt,
      canRetry: canRetry,
      problem: voice?.problem ?? _startProblem,
      note: note,
      level: voice?.level ?? 0,
    );
  }

  /// Opt in for the selected workspace.  It shows the card and starts no
  /// call.
  Future<void> enable() async {
    if (_disposed) return;
    _connectionLost = false;
    _callLost = false;
    _startProblem = null;
    await host.setBuddyEnabled(true);
    if (!_disposed) notifyListeners();
  }

  /// Opt out for the selected workspace.  It only removes the away card:
  /// a call the workspace has is the in-call bar's and the full call view's
  /// now, with its microphone and End in sight, so hiding the card does not
  /// stop it.  Nothing is left recording behind a surface that is not there.
  Future<void> disable() async {
    if (_disposed) return;
    await host.setBuddyEnabled(false);
    if (!_disposed) notifyListeners();
  }

  /// The workspace page's action: off when on, on when off.
  Future<void> toggle() => enabled ? disable() : enable();

  /// Start a call on the active thread's live session.  A second start, a
  /// double tap or a start while ending is ignored.
  Future<void> start() async {
    if (_disposed || _ending || running) return;
    final workspace = host.buddyWorkspace;
    final thread = host.buddyThread;
    final sessionId = thread?.live;
    if (workspace == null || thread == null || sessionId == null) {
      notifyListeners();
      return;
    }
    if (!_connected || !_configured) {
      notifyListeners();
      return;
    }
    // A finished controller from an earlier call is let go before a new
    // one is made: its microphone was already released by stop or failure.
    _disposeRetired();
    final previous = _voice;
    if (previous != null && previous.phase.finished) {
      previous.removeListener(_voiceChanged);
      _voice = null;
      await previous.stop();
      previous.dispose();
    }
    final generation = ++_generation;
    _starting = true;
    _connectionLost = false;
    _callLost = false;
    _startProblem = null;
    _callWorkspaceId = workspace.id;
    _callWorkspaceName = workspace.name;
    _callThreadTitle = thread.title;
    _callProvider = host.buddyVoiceSettings.provider;
    notifyListeners();
    VoiceSessionBridge? bridge;
    try {
      bridge = host.openBuddyBridge(sessionId);
    } catch (error) {
      bridge = null;
      if (generation == _generation && !_disposed) {
        _startProblem = VoiceProblem(
          'Session unavailable',
          detail: _oneLine(error),
          recoverable: true,
        );
      }
    }
    if (bridge == null) {
      if (generation == _generation && !_disposed) {
        _starting = false;
        _startProblem ??= const VoiceProblem(
          'Session unavailable',
          recoverable: true,
        );
        notifyListeners();
      }
      return;
    }
    if (generation != _generation || _disposed) return;
    final voice = VoiceController(
      settings: host.buddyVoiceSettings,
      bridge: bridge,
      harnessAddress: host.buddyHarnessAddress,
      backendFactory: (settings, address) =>
          _backendFactory(settings, address, bridge!),
      onSettingsChanged: host.saveBuddyVoiceSettings,
      mediaButtons: _mediaButtons,
    );
    voice.addListener(_voiceChanged);
    _voice = voice;
    _starting = false;
    notifyListeners();
    await voice.start();
    if (generation != _generation || _disposed) return;
    notifyListeners();
  }

  /// End the call: microphone, player and provider connection.  The agent's
  /// work keeps running; this is the voice screen's End, not a cancel.
  Future<void> end({bool connectionLost = false, bool callLost = false}) async {
    if (_disposed || _ending) return;
    _generation++;
    _starting = false;
    _startProblem = null;
    if (connectionLost) _connectionLost = true;
    if (callLost) _callLost = true;
    _ending = true;
    notifyListeners();
    final voice = _voice;
    if (voice != null) {
      voice.removeListener(_voiceChanged);
      await voice.stop();
      // Kept until the next call or this controller's end: a call view that
      // is still on screen may have a listener to remove from it.
      _retired.add(voice);
    }
    _voice = null;
    _ending = false;
    _clearCallIdentity();
    if (!_disposed) notifyListeners();
  }

  /// Retry after a problem.  A recoverable problem in a running call retries
  /// that call; a fatal one starts a new one through the guarded Start.
  Future<void> retry() async {
    if (_disposed || _ending || _starting) return;
    final voice = _voice;
    if (voice != null && !voice.phase.finished && voice.problem != null) {
      _startProblem = null;
      await voice.retry();
      if (!_disposed) notifyListeners();
      return;
    }
    await start();
  }

  Future<void> toggleMute() async {
    final voice = _voice;
    if (voice == null || _disposed || _ending) return;
    await voice.toggleMute();
    if (!_disposed) notifyListeners();
  }

  Future<void> togglePause() async {
    final voice = _voice;
    if (voice == null || _disposed || _ending) return;
    await voice.togglePause();
    if (!_disposed) notifyListeners();
  }

  Future<void> interrupt() async {
    final voice = _voice;
    if (voice == null || _disposed || _ending) return;
    await voice.interrupt();
    if (!_disposed) notifyListeners();
  }

  /// Save a changed voice setup and, when a call is running, let the
  /// existing controller apply it (which may restart the backend).
  Future<void> applyVoiceSettings(VoiceSettings settings) async {
    if (_disposed) return;
    await host.saveBuddyVoiceSettings(settings);
    _startProblem = null;
    final voice = _voice;
    if (voice != null && !voice.phase.finished) {
      await voice.updateSettings(settings);
    }
    if (!_disposed) notifyListeners();
  }

  void _voiceChanged() {
    if (_disposed || _ending) return;
    final voice = _voice;
    if (voice != null && voice.phase == VoicePhase.ended) {
      // The backend ended on its own: stop it and let go of the provider
      // rather than leaving a call the card can no longer control.
      _callLost = true;
      unawaited(end(callLost: true));
      return;
    }
    notifyListeners();
  }

  void _hostChanged() {
    if (_disposed) return;
    final context = host.buddyContextListenable;
    if (!identical(context, _context)) {
      _context?.removeListener(_hostChanged);
      _context = context;
      _context?.addListener(_hostChanged);
    }
    final workspace = host.buddyWorkspace;
    if (workspace == null) {
      if (voice != null || _starting) unawaited(end());
    } else if (_callWorkspaceId != null && workspace.id != _callWorkspaceId) {
      unawaited(end());
    } else if (!_connected && running) {
      unawaited(end(connectionLost: true));
    }
    if (!_disposed) notifyListeners();
  }

  /// Let go of the controllers of calls that are already stopped.  Their
  /// microphone was released by [end]; only their listeners are removed
  /// here, after any view that showed them has had a frame to let go.
  void _disposeRetired() {
    for (final voice in _retired) {
      voice.dispose();
    }
    _retired.clear();
  }

  void _clearCallIdentity() {
    _callWorkspaceId = null;
    _callWorkspaceName = null;
    _callThreadTitle = null;
    _callProvider = null;
  }

  static String _oneLine(Object error) {
    final line = '$error'.trim().split('\n').first.trim();
    if (line.isEmpty) return error.runtimeType.toString();
    return line.length <= 160 ? line : '${line.substring(0, 159)}…';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    host.removeListener(_hostChanged);
    _context?.removeListener(_hostChanged);
    final voice = _voice;
    _voice = null;
    if (voice != null) {
      voice.removeListener(_voiceChanged);
      unawaited(voice.stop().whenComplete(voice.dispose));
    }
    _disposeRetired();
    super.dispose();
  }
}
