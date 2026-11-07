/// A demo a task's report hands in, running on the harness's machine: where
/// it runs, where its screen is, who is driving it, and the presenter that
/// walks the person through it.
///
/// It is the answer to the harness's `demo/start`, `demo/status`,
/// `demo/stop` and `demo/control`, which all say the same thing about a run
/// in different words: a start and a status say all of it, a control says
/// what changed, and a stop leaves out what the run no longer has.  Every
/// key is read when it is there, so the same reader serves them all.
///
/// Plain Dart, so that it is tested without a widget.
library;

import '../acp/acp_message.dart';
import 'session.dart' show parseTime;

/// The state a demo run is in, as the harness names it.
abstract final class DemoState {
  static const running = 'running';
  static const starting = 'starting';
  static const stopped = 'stopped';
  static const lost = 'lost';
  static const missing = 'missing';
  static const notReady = 'not-ready';
  static const denied = 'denied';
  static const error = 'error';
}

/// A demo run, as the harness describes it.
class DemoSession {
  const DemoSession({
    this.state = '',
    this.reason,
    this.run,
    this.task,
    this.demo,
    this.title,
    this.placement,
    this.workspace,
    this.workspaceName,
    this.commit,
    this.commitVerified,
    this.artifact,
    this.launch,
    this.vnc,
    this.control,
    this.presenter,
    this.at,
    this.stopped = false,
  });

  /// One of [DemoState].
  final String state;

  /// Why the run is not what was asked for, when the harness says.
  final DemoReason? reason;

  /// The id of the run, which every later call about it names.
  final String? run;
  final String? task;
  final String? demo;

  /// What the demo is called, as the report named it.
  final String? title;

  /// `workspace` (a checkout on the harness's machine) or `host` (the
  /// harness's machine itself).
  final String? placement;
  final String? workspace;
  final String? workspaceName;

  /// The commit the worktree was at when the demo was started, and whether
  /// the harness verified it.
  final String? commit;
  final bool? commitVerified;

  /// The page the demo shows, and the command that serves it.
  final DemoArtifact? artifact;
  final DemoLaunch? launch;

  /// The screen of the workspace computer, when the run has one.
  final DemoVnc? vnc;

  /// Who drives: `agent` (the presenter) or `user` (the person).
  final String? control;

  /// The session that presents the demo, when the report has one.
  final DemoPresenter? presenter;

  /// When the harness last said something about the run.
  final DateTime? at;

  /// Whether the harness says the run has stopped.
  final bool stopped;

  /// Whether the run is at work.
  bool get isRunning => state == DemoState.running;

  /// Whether there is a run to go on with: one that runs or is starting,
  /// which a screen may watch and reconnect to.
  bool get reusable =>
      run != null &&
      run!.isNotEmpty &&
      !stopped &&
      (isRunning || state == DemoState.starting);

  /// Whether [other] describes the same run, so that what the harness says of
  /// a run already on screen may replace it.
  bool sameRun(DemoSession other) => run != null && run == other.run;

  /// What this run is, with what [other] says of it: an answer to
  /// `demo/control` names only what changed, and a status names the run
  /// whole.  A field [other] leaves out is kept.
  DemoSession merge(DemoSession other) => DemoSession(
    state: other.state.isEmpty ? state : other.state,
    reason: other.reason ?? reason,
    run: other.run ?? run,
    task: other.task ?? task,
    demo: other.demo ?? demo,
    title: other.title ?? title,
    placement: other.placement ?? placement,
    workspace: other.workspace ?? workspace,
    workspaceName: other.workspaceName ?? workspaceName,
    commit: other.commit ?? commit,
    commitVerified: other.commitVerified ?? commitVerified,
    artifact: other.artifact ?? artifact,
    launch: other.launch ?? launch,
    vnc: other.vnc ?? vnc,
    control: other.control ?? control,
    presenter: other.presenter ?? presenter,
    at: other.at ?? at,
    stopped: other.stopped || stopped,
  );

  /// The run in [wire], which may be the answer to any of the four methods.
  factory DemoSession.fromWire(JsonMap wire) {
    String? field(String name) => _field(wire, name);
    bool? flag(String name) {
      final value = _value(wire, name);
      return value == null ? null : asBool(value);
    }

    return DemoSession(
      state: field('state') ?? '',
      reason: DemoReason.fromWire(_value(wire, 'reason')),
      run: field('run'),
      task: field('task'),
      demo: field('demo'),
      title: field('title'),
      placement: field('placement'),
      workspace: field('workspace'),
      workspaceName: field('workspace-name'),
      commit: field('commit'),
      commitVerified: flag('commit-verified'),
      artifact: DemoArtifact.fromWire(_value(wire, 'artifact')),
      launch: DemoLaunch.fromWire(_value(wire, 'launch')),
      vnc: DemoVnc.fromWire(_value(wire, 'vnc')),
      control: field('control'),
      presenter: DemoPresenter.fromWire(_value(wire, 'presenter')),
      at: parseTime(_value(wire, 'at')),
      stopped: flag('stopped') ?? false,
    );
  }
}

/// Why something about a demo did not happen, as the harness names it.
///
/// [text] is the harness's own words, data to show under a label rather than
/// interface copy to write.
class DemoReason {
  const DemoReason({required this.code, this.text});

  /// One of `no-session`, `no-task`, `no-report`, `no-demo`,
  /// `workspace-missing`, `workspace-unknown`, `box-methods-missing`,
  /// `box-not-running`, `box-status-failed`, `mount-missing`,
  /// `commit-mismatch`, `worktree-dirty`, `demo-not-runnable`,
  /// `spawn-failed`, `vnc-unavailable`, `denied`, `stopped`, `internal`.
  final String code;
  final String? text;

  static DemoReason? fromWire(Object? wire) {
    final map = asMap(wire);
    final code = _field(map, 'code');
    if (code == null || code.isEmpty) return null;
    return DemoReason(code: code, text: _field(map, 'text'));
  }
}

/// The page a demo shows and how it is served.
class DemoArtifact {
  const DemoArtifact({this.name, this.cwd, this.command = const []});

  final String? name;
  final String? cwd;
  final List<String> command;

  static DemoArtifact? fromWire(Object? wire) {
    final map = asMap(wire);
    if (map.isEmpty) return null;
    final name = _field(map, 'name');
    final cwd = _field(map, 'cwd');
    final command = [
      for (final part in asList(_value(map, 'command')))
        if (part is String && part.trim().isNotEmpty) part,
    ];
    if (name == null && cwd == null && command.isEmpty) return null;
    return DemoArtifact(name: name, cwd: cwd, command: command);
  }
}

/// How the demo is started, on the harness's machine.
class DemoLaunch {
  const DemoLaunch({this.command = const [], this.cwd, this.boxCwd});

  final List<String> command;
  final String? cwd;

  /// Where the command runs on the workspace computer, when the demo runs
  /// there.
  final String? boxCwd;

  /// The command as one line, as a person would type it.
  String get commandLine => command.join(' ');

  static DemoLaunch? fromWire(Object? wire) {
    final map = asMap(wire);
    if (map.isEmpty) return null;
    final command = [
      for (final part in asList(_value(map, 'command')))
        if (part is String && part.trim().isNotEmpty) part,
    ];
    final cwd = _field(map, 'cwd');
    final boxCwd = _field(map, 'box-cwd');
    if (command.isEmpty && cwd == null && boxCwd == null) return null;
    return DemoLaunch(command: command, cwd: cwd, boxCwd: boxCwd);
  }
}

/// The screen of the computer the demo runs on: a VNC endpoint, and whether
/// it can be watched from here.
class DemoVnc {
  const DemoVnc({
    this.url,
    this.socket,
    this.state,
    this.available = false,
    this.reason,
  });

  /// The viewer page the harness serves, its noVNC `vnc.html`.  It is not a
  /// screen: only [socket] is watched here.
  final String? url;

  /// The WebSocket endpoint of the RFB server, `ws://HOST:PORT/…`.
  final String? socket;

  /// What the computer is doing: `agent` while the presenter drives, `user`
  /// while the person does, or its own state as the harness names it.
  final String? state;
  final bool available;
  final DemoReason? reason;

  /// Whether there is a screen to watch: an RFB socket, which is not the
  /// noVNC page.
  bool get usable => available && socket != null && socket!.isNotEmpty;

  static DemoVnc? fromWire(Object? wire) {
    final map = asMap(wire);
    if (map.isEmpty) return null;
    return DemoVnc(
      url: _field(map, 'url'),
      socket: _field(map, 'socket'),
      state: _field(map, 'state'),
      available: asBool(_value(map, 'available')),
      reason: DemoReason.fromWire(_value(map, 'reason')),
    );
  }
}

/// The session that presents a demo, and what the harness calls it.
class DemoPresenter {
  const DemoPresenter({this.session, this.name});

  final String? session;
  final String? name;

  static DemoPresenter? fromWire(Object? wire) {
    final map = asMap(wire);
    if (map.isEmpty) return null;
    final session = _field(map, 'session');
    if (session == null || session.isEmpty) return null;
    return DemoPresenter(session: session, name: _field(map, 'name'));
  }
}

/// The key of [wire] as the harness writes it, or as a client that camel
/// cases the same name writes it.
Object? _value(JsonMap wire, String kebab) =>
    wire[kebab] ?? wire[_camel(kebab)];

String? _field(JsonMap wire, String kebab) {
  final value = _value(wire, kebab) ?? wire[kebab.replaceAll('-', '_')];
  final text = asString(value)?.trim();
  return text == null || text.isEmpty ? null : text;
}

String _camel(String kebab) => kebab.replaceAllMapped(
  RegExp(r'-([a-z])'),
  (match) => match[1]!.toUpperCase(),
);
