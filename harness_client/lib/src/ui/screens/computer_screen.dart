import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/computer.dart';
import '../../state/app_controller.dart';
import '../../state/computers_controller.dart';
import '../../vnc/rfb.dart';
import '../../vnc/vnc_view.dart';
import '../../vnc/websocket_transport.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../theme/harness_theme.dart';

/// One computer: its screen, what it can do, and the resources it offers.
///
/// The screen is RFB over the computer's WebSocket, the same protocol the
/// workspace desk speaks.  A person watching may take the pointer and the
/// keyboard; until they give them back, the agent's input on this computer is
/// refused.
class ComputerScreen extends StatefulWidget {
  const ComputerScreen({
    super.key,
    required this.app,
    required this.computer,
    this.controller,
    this.vncTransportFactory,
  });

  final AppController app;
  final Computer computer;

  /// The page that opened this one, when it has one: its control toggle and
  /// its grants are the same session's.
  final ComputersController? controller;

  /// A transport for the widget tests and the pictures; the screen builds a
  /// WebSocket one from the computer's socket when it is null.
  final RfbTransport Function(String url)? vncTransportFactory;

  @override
  State<ComputerScreen> createState() => _ComputerScreenState();
}

class _ComputerScreenState extends State<ComputerScreen> {
  late Computer _computer = widget.computer;
  RfbTransport? _transport;
  String? _transportUrl;
  int _generation = 0;
  bool _lost = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    unawaited(_transport?.close());
    super.dispose();
  }

  void _changed() {
    final controller = widget.controller;
    if (controller == null || !mounted) return;
    for (final computer in controller.computers) {
      if (computer.id != _computer.id) continue;
      if (computer.vncSocket != _computer.vncSocket) {
        unawaited(_transport?.close());
        _transport = null;
        _transportUrl = null;
        _generation++;
        _lost = false;
      }
      setState(() => _computer = computer);
      return;
    }
  }

  bool get _controlling => _computer.control == 'user';

  Future<void> _toggleControl() async {
    final controller = widget.controller;
    if (controller == null) return;
    if (_controlling) {
      await controller.releaseControl(_computer);
    } else {
      await controller.takeControl(_computer);
    }
  }

  RfbTransport? _transportFor(String socket) {
    if (_transportUrl == socket && _transport != null) return _transport;
    final uri = Uri.tryParse(socket.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'ws' && uri.scheme != 'wss') return null;
    _transportUrl = socket;
    final factory = widget.vncTransportFactory;
    _transport = factory != null
        ? factory(socket)
        : WebSocketTransport.connect(socket, token: widget.app.sessionSecret);
    return _transport;
  }

  @override
  Widget build(BuildContext context) {
    final socket = _computer.vncSocket;
    final transport = (socket ?? '').isEmpty ? null : _transportFor(socket!);
    return HarnessPage(
      title: _computer.name,
      subtitle: Text('${_computer.kindLabel} · ${_computer.stateLabel}'),
      maxContentWidth: HarnessSpace.pageWidth,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          28,
        ),
        children: [
          if (_computer.connected && widget.controller != null)
            Padding(
              padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: HarnessSecondaryButton(
                  label: _controlling ? 'Return' : 'Control',
                  onPressed: widget.controller!.canControl
                      ? _toggleControl
                      : null,
                ),
              ),
            ),
          _ScreenCard(
            computer: _computer,
            transport: transport,
            generation: _generation,
            lost: _lost,
            controlling: _controlling,
            onLost: () {
              if (mounted && !_lost) setState(() => _lost = true);
            },
          ),
          const HarnessSectionHeader(label: 'Facts'),
          _Facts(computer: _computer),
          const HarnessSectionHeader(label: 'Resources'),
          if (_computer.resources.isEmpty)
            const HarnessEmptyState(
              icon: Icons.folder_outlined,
              title: 'No resources',
              message: 'No folder or repository offered',
            )
          else
            HarnessCardList(
              children: [
                for (final resource in _computer.resources)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          resource.project
                              ? Icons.account_tree_outlined
                              : Icons.folder_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                resource.name,
                                style: HarnessText.rowTitle(context),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  resource.kindLabel,
                                  if ((resource.path ?? '').isNotEmpty)
                                    resource.path!,
                                ].join(' · '),
                                style: HarnessText.meta(context),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ScreenCard extends StatelessWidget {
  const _ScreenCard({
    required this.computer,
    required this.transport,
    required this.generation,
    required this.lost,
    required this.controlling,
    required this.onLost,
  });

  final Computer computer;
  final RfbTransport? transport;
  final int generation;
  final bool lost;
  final bool controlling;
  final VoidCallback onLost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = computer.vnc;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: HarnessColors.paper,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: transport == null
                ? const Center(
                    child: HarnessEmptyState(
                      icon: Icons.monitor_outlined,
                      title: 'No screen socket',
                      message: 'Screen page only',
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      VncView(
                        key: ValueKey('computer-vnc-$generation'),
                        transport: transport!,
                        enabled: controlling && !lost,
                        onLost: (_) => onLost(),
                      ),
                      if (lost)
                        const Positioned(
                          left: 12,
                          right: 12,
                          bottom: 12,
                          child: _ScreenNote(label: 'Screen lost'),
                        ),
                      if (!controlling)
                        const Positioned(
                          left: 12,
                          bottom: 12,
                          child: _ScreenNote(label: 'View only'),
                        ),
                    ],
                  ),
          ),
          if ((page ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.open_in_browser_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      page!,
                      style: HarnessText.mono(context).copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ScreenNote extends StatelessWidget {
  const _ScreenNote({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          style: HarnessText.meta(context).copyWith(color: HarnessColors.ink),
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.computer});

  final Computer computer;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Kind', computer.kindLabel),
      ('Id', computer.id),
      if ((computer.host ?? '').isNotEmpty) ('Host', computer.host!),
      if ((computer.os ?? '').isNotEmpty) ('System', computer.os!),
      if ((computer.arch ?? '').isNotEmpty) ('Architecture', computer.arch!),
      if ((computer.display ?? '').isNotEmpty) ('Display', computer.display!),
      ('State', computer.stateLabel),
      ('Control', computer.controlLabel),
      ('Capabilities', computer.capabilityLine),
      ('Servers', computer.servers.isEmpty ? 'None' : computer.servers.join(' · ')),
      if (computer.windowScoped) ('Scope', 'One window'),
    ];
    return HarnessCardList(
      children: [
        for (final (label, value) in rows)
          HarnessInfoRow(label: label, value: value, monospace: label == 'Id'),
      ],
    );
  }
}
