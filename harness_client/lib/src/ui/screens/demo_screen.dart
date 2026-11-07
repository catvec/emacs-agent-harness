import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/demo_session.dart';
import '../../services/voice_runtime.dart';
import '../../state/app_controller.dart';
import '../../state/session_controller.dart';
import '../../voice/voice_controller.dart';
import '../../voice/voice_models.dart';
import '../../vnc/rfb.dart';
import '../../vnc/vnc_view.dart';
import '../../vnc/websocket_transport.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../app_scope.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/markdown_view.dart';
import '../widgets/voice_settings_sheet.dart';

/// One demo of a report, running: the screen of the computer the harness
/// started it on, and the presenter that walks the person through it.
///
/// The screen comes from the harness as a VNC endpoint ([DemoVnc]), which is
/// watched with the app's own RFB client ([VncView]); the presenter is the
/// session `demo/start` made, heard and answered with the voice machinery of
/// a conversation ([VoiceController]) and typed to in a field of its own.
/// The walkthrough itself is not sent here: `demo/start` sends it, and this
/// page only listens to the answer.
///
/// Leaving the page is not ending the demo: the run belongs to the harness
/// and goes on for the next visit, so only *Stop demo* stops it (and only
/// this screen's run).
class DemoScreen extends StatefulWidget {
  const DemoScreen({
    super.key,
    required this.session,
    this.voiceBackendFactory,
    this.vncTransportFactory,
  });

  /// What `demo/start` answered: the run, its screen, who drives it, and the
  /// presenter.
  final DemoSession session;

  /// What the presenter's voice opens with.  The app leaves it null and
  /// builds the real backend; a test hands it a scripted one.
  final VoiceBackendFactory? voiceBackendFactory;

  /// Where the RFB bytes come from.  The app leaves it null and opens the
  /// endpoint's WebSocket; a test hands it a transport of its own, so that
  /// the RFB client under it is the real one.
  final RfbTransport Function(String url)? vncTransportFactory;

  /// Open the page of [session] over the one [context] is on.
  static Future<void> show(
    BuildContext context,
    DemoSession session, {
    VoiceBackendFactory? voiceBackendFactory,
    RfbTransport Function(String url)? vncTransportFactory,
  }) {
    return Navigator.of(context).push<void>(
      harnessRoute<void>(
        context,
        (_) => DemoScreen(
          session: session,
          voiceBackendFactory: voiceBackendFactory,
          vncTransportFactory: vncTransportFactory,
        ),
      ),
    );
  }

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  late DemoSession _demo = widget.session;
  AppController? _app;
  SessionController? _presenter;
  VoiceController? _voice;
  final _ask = TextEditingController();
  bool _bound = false;
  bool _appConnected = true;
  bool _stopping = false;
  bool _changingControl = false;
  bool _checking = false;

  /// The screen's connection dropped: the last picture stays, dimmed, until
  /// the run is asked about and a new connection is made.
  bool _lost = false;

  /// A new VNC connection is a new [VncView]: this names the one on screen,
  /// and the transport it reads.
  int _generation = 0;
  RfbTransport? _transport;
  int _transportGeneration = -1;

  DemoVnc? get _vnc => _demo.vnc;

  bool get _hasScreen => _vnc?.usable == true && _demo.reusable;

  bool get _gone => !_demo.reusable;

  String get _control => _demo.control ?? 'agent';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    _bound = true;
    final app = HarnessScope.appOf(context);
    _app = app;
    _appConnected = app.isConnected;
    app.addListener(_appChanged);
    _bindPresenter(app);
  }

  void _bindPresenter(AppController app) {
    final id = _demo.presenter?.session;
    if (id == null) return;
    final presenter = app.sessionController(id);
    _presenter = presenter;
    // The presenter is a conversation of its own: its replies are what is
    // heard here, and what is said back is a message in it.  It is read, not
    // opened as the app's active session, so that leaving the demo leaves
    // whatever the person was reading where it was.
    unawaited(presenter.open());
    final bridge = SessionVoiceBridge(presenter);
    final voice = VoiceController(
      settings: app.settings.voiceSettings,
      bridge: bridge,
      harnessAddress: app.address ?? app.settings.address,
      backendFactory:
          widget.voiceBackendFactory ??
          (settings, address) => createVoiceBackend(settings, address, bridge),
      onSettingsChanged: app.settings.setVoiceSettings,
    );
    voice.addListener(_voiceChanged);
    // The presenter narrates the demo from the moment the run starts, before
    // the person has asked to hear it: the page shows what it says.
    voice.follow();
    _voice = voice;
  }

  void _voiceChanged() {
    if (mounted) setState(() {});
  }

  void _appChanged() {
    final app = _app;
    if (app == null) return;
    final connected = app.isConnected;
    if (connected && !_appConnected) {
      _appConnected = true;
      unawaited(_afterConnection());
    } else {
      _appConnected = connected;
    }
  }

  /// The app is in touch with the harness again: the run is asked about
  /// once.  A run that is gone is over; one that runs keeps the page, on a
  /// screen connected again.
  Future<void> _afterConnection() async {
    if (_gone) return;
    await _reconnect();
  }

  Future<void> _reconnect() async {
    if (_checking) return;
    final run = _demo.run;
    final api = _app?.api;
    if (run == null || api == null) return;
    setState(() => _checking = true);
    try {
      final answer = await api.demoStatus(run);
      if (!mounted) return;
      setState(() {
        _checking = false;
        _demo = _demo.merge(answer);
        if (_demo.reusable) {
          _lost = false;
          // A connection of its own, whether the old one had dropped or the
          // app only went away for a moment.
          _generation++;
        } else {
          _lost = false;
        }
      });
    } catch (_) {
      if (!mounted) return;
      // The run cannot be asked about yet: the button can be tried again.
      setState(() => _checking = false);
    }
  }

  Future<void> _setControl(String control) async {
    if (_changingControl || _gone) return;
    final run = _demo.run;
    final api = _app?.api;
    if (run == null || api == null) return;
    setState(() => _changingControl = true);
    try {
      final answer = await api.demoControl(run, control);
      if (!mounted) return;
      setState(() {
        _changingControl = false;
        _demo = _demo.merge(answer);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _changingControl = false);
      _snack('Control failed');
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    final run = _demo.run;
    final api = _app?.api;
    if (run == null || api == null) return;
    setState(() => _stopping = true);
    try {
      await api.stopDemo(run);
    } catch (_) {
      if (!mounted) return;
      setState(() => _stopping = false);
      _snack('Stop failed');
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _talk() async {
    final voice = _voice;
    if (voice == null) return;
    await voice.start();
  }

  Future<void> _mute() async {
    final voice = _voice;
    if (voice == null) return;
    await voice.toggleMute();
  }

  Future<void> _interrupt() async {
    final voice = _voice;
    if (voice == null) return;
    await voice.interrupt();
  }

  Future<void> _setUp() async {
    final voice = _voice;
    if (voice == null) return;
    final next = await showVoiceSettingsSheet(
      context,
      settings: voice.settings,
      harnessAddress: voice.harnessAddress,
    );
    if (next == null || !mounted) return;
    await voice.updateSettings(next);
  }

  /// A direction for the presenter: a message in its session, as speaking to
  /// it would be, so that it is heard even while the presenter talks.
  void _askPresenter(String text) {
    final trimmed = text.trim();
    final presenter = _presenter;
    if (trimmed.isEmpty || presenter == null) return;
    _ask.clear();
    unawaited(presenter.sendVoice(text: trimmed));
  }

  @override
  void dispose() {
    _app?.removeListener(_appChanged);
    _voice?.removeListener(_voiceChanged);
    // The demo is the harness's: leaving the page leaves it running.  Only
    // *Stop demo* stops the run, and only the one this screen was opened on.
    unawaited(_voice?.stop());
    _voice?.dispose();
    _ask.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HarnessPage(
      title: _demo.title ?? 'Demo',
      subtitle: HarnessStatusLabel(
        label: _stateLabel,
        color: _stateColor(context),
        icon: _stateIcon,
      ),
      actions: [
        HarnessTextButton(
          key: const Key('demo-stop'),
          label: 'Stop demo',
          onPressed: _stopping ? null : _stop,
        ),
      ],
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900 && _voice != null;
          if (!wide) {
            return Column(
              children: [
                Expanded(child: _screenArea(context)),
                if (_voice != null) _presenterDock(context),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _screenArea(context)),
              SizedBox(
                width: math.max(320, constraints.maxWidth * 0.28),
                child: _presenterPanel(context),
              ),
            ],
          );
        },
      ),
    );
  }

  String get _stateLabel {
    if (_lost) return 'Reconnecting';
    return switch (_demo.state) {
      DemoState.running || DemoState.starting => 'Demo running',
      DemoState.stopped || DemoState.missing => 'Demo stopped',
      DemoState.lost => 'Demo lost',
      DemoState.notReady => 'Not ready',
      DemoState.denied || DemoState.error => 'Demo failed',
      _ => 'Demo stopped',
    };
  }

  Color _stateColor(BuildContext context) {
    final theme = Theme.of(context);
    if (_lost) return HarnessColors.amber;
    return switch (_demo.state) {
      DemoState.running ||
      DemoState.starting => HarnessColors.status('running', theme.brightness),
      DemoState.notReady => HarnessColors.amber,
      DemoState.denied || DemoState.error => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
  }

  IconData? get _stateIcon => switch (_demo.state) {
    DemoState.denied || DemoState.error => Icons.error_outline_rounded,
    DemoState.notReady => Icons.hourglass_empty_rounded,
    _ => null,
  };

  /// The screen of the computer, with the takeover pill at its bottom edge
  /// and, while the presenter drives, a caption that says so.
  Widget _screenArea(BuildContext context) {
    final theme = Theme.of(context);
    final vnc = _vnc;
    final surface = Container(
      key: const Key('demo-screen'),
      color: const Color(0xFF0B0B0D),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _picture(context),
          if (_hasScreen)
            PositionedDirectional(
              start: 12,
              top: 12,
              child: _Caption(
                label: 'Screen',
                background: theme.colorScheme.surface.withValues(alpha: 0.82),
              ),
            ),
          // A commit is named only when the harness verified it: a box that
          // named none is not to be read as one that checked.
          if (_demo.commitVerified == true && _demo.commit != null)
            PositionedDirectional(
              end: 12,
              top: 12,
              child: _Caption(
                label: 'Commit ${_demo.commit}',
                background: theme.colorScheme.surface.withValues(alpha: 0.82),
              ),
            ),
          if (_hasScreen && !_lost && _control != 'user')
            PositionedDirectional(
              start: 12,
              bottom: 56,
              child: _Caption(
                label: 'Presenter driving',
                background: theme.colorScheme.surface.withValues(alpha: 0.82),
              ),
            ),
          if (_lost && vnc != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Connection lost',
                        style: HarnessText.rowTitle(context)
                            .copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Reconnecting',
                        style: HarnessText.caption(context)
                            .copyWith(color: Colors.white70),
                      ),
                      const SizedBox(height: 10),
                      HarnessTextButton(
                        key: const Key('demo-reconnect'),
                        label: 'Reconnect',
                        onPressed: _checking ? null : _reconnect,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_hasScreen)
            PositionedDirectional(
              start: 0,
              end: 0,
              bottom: 12,
              child: Center(
                child: HarnessPill(
                  key: const Key('demo-control'),
                  label: _control == 'user'
                      ? 'Control · you'
                      : 'Control · agent',
                  selected: _control == 'user',
                  icon: Icons.touch_app_outlined,
                  onTap: _changingControl || _gone
                      ? null
                      : () =>
                            _setControl(_control == 'user' ? 'agent' : 'user'),
                ),
              ),
            ),
        ],
      ),
    );
    return surface;
  }

  /// The screen's picture, or what stands in its place when there is none:
  /// the harness's machine itself, or why no screen can be watched.
  Widget _picture(BuildContext context) {
    final vnc = _vnc;
    if (_hasScreen && !_gone) {
      final socket = vnc?.socket;
      if (socket != null) {
        final transport = _transportFor(socket);
        if (transport != null) {
          return VncView(
            key: ValueKey('demo-vnc-$_generation'),
            transport: transport,
            enabled: _control == 'user' && !_lost,
            onLost: (_) {
              if (mounted && !_lost) setState(() => _lost = true);
            },
          );
        }
        // A page is not a socket: the box offered no screen this app can
        // watch, and the page is never opened as one.
        return _missing(context, caption: 'VNC unavailable');
      }
    }
    if (_gone || _demo.state == DemoState.stopped) {
      return _missing(context, caption: 'Demo stopped');
    }
    if (_demo.placement == 'host') {
      final command = _launchCommand();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HarnessSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.computer_rounded,
                size: 30,
                color: Colors.white54,
              ),
              const SizedBox(height: 8),
              Text(
                'On the harness machine',
                style: HarnessText.rowTitle(context)
                    .copyWith(color: Colors.white),
              ),
              if (command.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  command,
                  textAlign: TextAlign.center,
                  style: HarnessText.mono(context)
                      .copyWith(color: Colors.white70, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (vnc != null && vnc.available) {
      // The box said it has a screen but named no socket: there is still no
      // screen to draw.
      return _missing(context, caption: 'VNC unavailable');
    }
    return _missing(
      context,
      caption: vnc?.reason?.text ?? _demo.reason?.text ?? 'VNC unavailable',
    );
  }

  /// The transport of this generation, made once: a rebuild is the same
  /// connection, and a reconnect is a new view with a new one.  The box's
  /// loopback socket is asked of [VncEndpoint], which puts it on the harness
  /// this device is signed in to; a value that is not a socket (the box's
  /// noVNC page) has no transport.
  RfbTransport? _transportFor(String socket) {
    if (_transport == null || _transportGeneration != _generation) {
      final resolved = VncEndpoint.resolve(
        socket,
        _app?.address ?? _app?.settings.address,
      );
      if (resolved == null) return null;
      final factory = widget.vncTransportFactory;
      _transport = factory != null
          ? factory(resolved)
          : WebSocketTransport.connect(
              resolved,
              token: _app?.sessionSecret ?? '',
            );
      _transportGeneration = _generation;
    }
    return _transport;
  }

  String _launchCommand() {
    final launch = _demo.launch;
    if (launch != null && launch.command.isNotEmpty) return launch.commandLine;
    final artifact = _demo.artifact;
    if (artifact != null && artifact.command.isNotEmpty) {
      return artifact.command.join(' ');
    }
    return '';
  }

  Widget _missing(BuildContext context, {String? caption}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HarnessSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.desktop_access_disabled_rounded,
              size: 30,
              color: Colors.white54,
            ),
            const SizedBox(height: 8),
            Text(
              'No screen',
              style: HarnessText.rowTitle(context)
                  .copyWith(color: Colors.white),
            ),
            if (caption != null && caption.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                caption,
                textAlign: TextAlign.center,
                style: HarnessText.caption(context)
                    .copyWith(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The presenter, under the screen on a phone: who is talking, the last
  /// two lines, the controls, and a field to direct it.
  Widget _presenterDock(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('demo-presenter'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        HarnessSpace.gutter,
        HarnessSpace.sm,
        HarnessSpace.gutter,
        HarnessSpace.sm,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _presenterHeader(context),
            const SizedBox(height: 4),
            _captions(context, maxLines: 3),
            const SizedBox(height: 6),
            _presenterControls(context),
          ],
        ),
      ),
    );
  }

  Widget _presenterPanel(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('demo-presenter'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.all(HarnessSpace.gutter),
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _presenterHeader(context),
            const SizedBox(height: 8),
            Expanded(child: _captions(context)),
            const SizedBox(height: 8),
            _presenterControls(context),
          ],
        ),
      ),
    );
  }

  Widget _presenterHeader(BuildContext context) {
    final voice = _voice;
    return Row(
      children: [
        const Icon(Icons.record_voice_over_rounded, size: 17),
        const SizedBox(width: 8),
        Text('Presenter', style: HarnessText.rowTitle(context)),
        const Spacer(),
        if (voice != null)
          Flexible(
            child: HarnessStatusLabel(
              label: _presenterStatus(voice),
              color: _presenterColor(context, voice),
            ),
          ),
      ],
    );
  }

  String _presenterStatus(VoiceController voice) {
    if (!voice.configured) return 'Voice not set up';
    final phase = voice.displayPhase;
    if (phase == VoicePhase.failed) return 'Voice failed';
    if (voice.muted || phase == VoicePhase.muted) return 'Muted';
    if (phase == VoicePhase.interrupted) return 'Interrupted';
    if (phase == VoicePhase.thinking || phase == VoicePhase.transcribing) {
      return 'Thinking';
    }
    if (phase == VoicePhase.listening ||
        phase == VoicePhase.hearing ||
        phase == VoicePhase.connecting) {
      return 'Listening';
    }
    return 'Narration';
  }

  Color _presenterColor(BuildContext context, VoiceController voice) {
    final theme = Theme.of(context);
    if (!voice.configured ||
        voice.displayPhase == VoicePhase.failed ||
        voice.displayPhase == VoicePhase.interrupted) {
      return theme.colorScheme.onSurfaceVariant;
    }
    return switch (voice.displayPhase) {
      VoicePhase.listening ||
      VoicePhase.hearing => HarnessColors.status('running', theme.brightness),
      VoicePhase.thinking || VoicePhase.transcribing => HarnessColors.amber,
      _ => theme.colorScheme.onSurfaceVariant,
    };
  }

  Widget _captions(BuildContext context, {int maxLines = 8}) {
    final voice = _voice;
    if (voice == null) return const SizedBox.shrink();
    final captions = voice.captions.length > 2
        ? voice.captions.sublist(voice.captions.length - 2)
        : voice.captions;
    if (captions.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxLines * 20.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final caption in captions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: caption.speaker == VoiceSpeaker.agent
                    ? HarnessMarkdown(text: caption.text, compact: true)
                    : Text(
                        caption.text,
                        style: HarnessText.body(context).copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _presenterControls(BuildContext context) {
    final voice = _voice;
    if (voice == null) return const SizedBox.shrink();
    final active = voice.started && !voice.displayPhase.finished;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            HarnessTextButton(
              key: const Key('demo-talk'),
              label: 'Talk',
              icon: Icons.mic_none_rounded,
              dense: true,
              onPressed: _talk,
            ),
            HarnessTextButton(
              key: const Key('demo-interrupt'),
              label: 'Interrupt',
              icon: Icons.stop_circle_outlined,
              dense: true,
              onPressed: active ? _interrupt : null,
            ),
            HarnessTextButton(
              key: const Key('demo-mute'),
              label: voice.muted ? 'Unmute' : 'Mute',
              icon: voice.muted
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
              dense: true,
              onPressed: active ? _mute : null,
            ),
            if (!voice.configured)
              HarnessTextButton(
                key: const Key('demo-setup'),
                label: 'Set up',
                icon: Icons.tune_rounded,
                dense: true,
                onPressed: _setUp,
              ),
          ],
        ),
        const SizedBox(height: 2),
        TextField(
          key: const Key('demo-ask'),
          controller: _ask,
          textInputAction: TextInputAction.send,
          style: HarnessText.body(context).copyWith(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Ask the presenter…',
            isDense: true,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 9,
            ),
          ),
          onSubmitted: _askPresenter,
        ),
      ],
    );
  }
}

/// A small label over the picture: on a surface of its own, so that it reads
/// on what the computer draws.
class _Caption extends StatelessWidget {
  const _Caption({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(label, style: HarnessText.meta(context)),
      ),
    );
  }
}
