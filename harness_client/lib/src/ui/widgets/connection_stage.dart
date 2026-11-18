import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../format.dart';

/// What a person is waiting for while the app goes back into its harness,
/// and how long it has been going on: "Connecting · 3s".  It ticks once a
/// second while it shows, so a wait that goes on says so rather than
/// looking stuck; it shows nothing once the app is connected.
///
/// The words are the stage's, as the app names it ([ConnectionStage]); a
/// stage that is entered again (the next attempt to connect) starts its
/// age over, which is the truth of it: that is a new wait.
class ConnectionStageLine extends StatefulWidget {
  const ConnectionStageLine({
    super.key,
    required this.app,
    this.style,
    this.color,
  });

  final AppController app;
  final TextStyle? style;
  final Color? color;

  @override
  State<ConnectionStageLine> createState() => _ConnectionStageLineState();
}

class _ConnectionStageLineState extends State<ConnectionStageLine> {
  Timer? _tick;

  /// How long the stage has been going, counted by the ticks: a phone's
  /// clock is not to be trusted for a wait of seconds, and this is what
  /// the line says.
  Duration _age = Duration.zero;
  ConnectionStage? _shown;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_stageChanged);
    _stageChanged();
  }

  @override
  void didUpdateWidget(ConnectionStageLine old) {
    super.didUpdateWidget(old);
    if (old.app != widget.app) {
      old.app.removeListener(_stageChanged);
      widget.app.addListener(_stageChanged);
      _stageChanged();
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_stageChanged);
    _tick?.cancel();
    super.dispose();
  }

  /// A tick a second while a stage shows, and none while none does.
  void _stageChanged() {
    final stage = widget.app.stage;
    if (stage != _shown) {
      // A new step, or a new attempt at the same one: its age starts over.
      _shown = stage;
      _age = Duration.zero;
    }
    final running = stage != null;
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _age += const Duration(seconds: 1));
      });
    } else if (!running && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final stage = widget.app.stage;
    if (stage == null) return const SizedBox.shrink();
    // It shrinks rather than pushes what is beside it off the line: it is
    // the stage that is cut short, never the reason.
    return Text(
      '${stageLabel(stage)} · ${waitAge(_age)}',
      key: const Key('connection-stage'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: (widget.style ?? const TextStyle()).copyWith(
        color: widget.color,
      ),
    );
  }
}

/// The words a stage is shown by: a noun, or a noun phrase, and no
/// sentence (see CLAUDE.md).
String stageLabel(ConnectionStage stage) => switch (stage) {
  ConnectionStage.checking => 'Checking connection',
  ConnectionStage.connecting => 'Connecting',
  ConnectionStage.handshaking => 'Handshake',
  ConnectionStage.signingIn => 'Signing in',
  ConnectionStage.readingSessions => 'Reading sessions',
  ConnectionStage.readingProjects => 'Reading projects',
  ConnectionStage.waiting => 'Waiting to retry',
};
