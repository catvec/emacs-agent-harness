import 'dart:async';

import 'package:flutter/material.dart';

import '../../computer/computer_capabilities.dart';
import '../../computer/computer_capture_port.dart';
import '../../computer/mobile_computer_controller.dart';
import '../../models/computer.dart';
import '../../state/app_controller.dart';
import '../../state/computers_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';
import '../widgets/dither.dart';
import 'computer_screen.dart';

/// The machines the harness may use: their state, their computer-use
/// capabilities, their resources, and what the open session may do there.
///
/// A computer is not this client and not a session's host: it offers tools
/// (MCP servers the client running there keeps) and resources.  Viewing a
/// screen is not a session's permission; the controls only change what the
/// session's agent may do.
class ComputersScreen extends StatefulWidget {
  const ComputersScreen({
    super.key,
    required this.app,
    this.sessionId,
    this.controller,
  });

  final AppController app;

  /// The session whose grants the page shows; the app's open session by
  /// default.  A page with no session still lists the computers.
  final String? sessionId;

  /// A controller for the widget tests and the pictures; the app builds one
  /// from its harness.
  final ComputersController? controller;

  @override
  State<ComputersScreen> createState() => _ComputersScreenState();
}

class _ComputersScreenState extends State<ComputersScreen> {
  late final ComputersController _controller =
      widget.controller ??
      ComputersController(
        widget.app.harness,
        sessionId: widget.sessionId ?? widget.app.activeSessionId,
      );
  late final MobileComputerController _phone = widget.app.mobileComputer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _phone.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.load(showSpinner: false);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _phone.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Computer computer) async {
    await Navigator.of(context).push(
      harnessRoute(
        context,
        (context) => ComputerScreen(
          app: widget.app,
          computer: computer,
          controller: _controller,
        ),
      ),
    );
  }

  String get _subtitle {
    final access = _controller.access;
    if (access == null) return 'Local and remote machines · resources · access';
    return '${access.policyLabel} · ${access.session}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final computers = controller.computers;
    final connected = computers.where((computer) => computer.connected).length;
    final resources = controller.resources;
    return HarnessPage(
      title: 'Computers',
      subtitle: Text(_subtitle),
      maxContentWidth: HarnessSpace.pageWidth,
      actions: [
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Computer list refresh',
          onPressed: controller.loading ? null : controller.reload,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.gutter,
          HarnessSpace.sm,
          HarnessSpace.gutter,
          28,
        ),
        children: [
          _Hero(
            computers: computers.length,
            connected: connected,
            resources: resources.length,
          ),
          if (controller.error != null) ...[
            const SizedBox(height: HarnessSpace.md),
            HarnessErrorBanner(message: controller.error!),
          ],
          if (controller.notice != null) ...[
            const SizedBox(height: HarnessSpace.sm),
            Text(
              controller.notice!,
              style: HarnessText.meta(context)
                  .copyWith(color: HarnessColors.moss),
            ),
          ],
          const HarnessSectionHeader(label: 'Session'),
          _AccessCard(controller: controller),
          const HarnessSectionHeader(label: 'Machines'),
          if (controller.loading && computers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: HarnessActivity(radius: 9)),
            )
          else if (computers.isEmpty)
            const HarnessEmptyState(
              icon: Icons.devices_other_rounded,
              title: 'No computers',
              message: 'No computer registered',
            )
          else
            for (final computer in computers) ...[
              _ComputerCard(
                computer: computer,
                controller: controller,
                onView: computer.viewable
                    ? () => unawaited(_open(computer))
                    : null,
              ),
              const SizedBox(height: HarnessSpace.md),
            ],
          const HarnessSectionHeader(label: 'Resources'),
          if (resources.isEmpty)
            const HarnessEmptyState(
              icon: Icons.folder_outlined,
              title: 'No resources',
              message: 'No folder or repository offered',
            )
          else
            _ResourceList(resources: resources),
          const HarnessSectionHeader(label: 'This client'),
          _ThisPhoneCard(controller: _phone),
        ],
      ),
    );
  }
}

/// This phone as a computer: its registration, its capture opt-ins and the
/// one step that stops everything.  A phone offers capture, not control:
/// the pointer and keyboard vocabulary is absent, and the card says so.
class _ThisPhoneCard extends StatelessWidget {
  const _ThisPhoneCard({required this.controller});

  final MobileComputerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capture = controller.captureSource;
    return HarnessCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  controller.formLabel,
                  style: HarnessText.rowTitle(context),
                ),
              ),
              HarnessStatusPill(
                label: controller.registered
                    ? (controller.connected ? 'Registered' : 'Disconnected')
                    : 'Not registered',
                color: controller.registered && controller.connected
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 4),
          HarnessMetaLine(
            parts: [
              controller.machineName,
              if (controller.machineId.isNotEmpty) controller.machineId,
              controller.machineOs,
            ],
          ),
          if (capture != null) ...[
            const SizedBox(height: HarnessSpace.sm),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: HarnessColors.oxide.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.radio_button_checked_rounded,
                    size: 16,
                    color: HarnessColors.oxide,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Capture active · ${_sourceLabel(capture)}',
                      style: HarnessText.meta(context),
                    ),
                  ),
                  HarnessTextButton(
                    label: 'Capture off',
                    onPressed: controller.busy
                        ? null
                        : () => controller.stopCapture(),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: HarnessSpace.sm),
          for (final capability in MobileComputerController.capabilityNames)
            _PhoneCapabilityRow(
              name: capability,
              enabled: controller.isEnabled(capability),
              status: controller.capabilities[capability],
              onChanged: controller.busy
                  ? null
                  : (value) => controller.setEnabled(capability, value),
            ),
          if (controller.fileWritesEnabled ||
              controller.capabilities['files']?.offered == true)
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('File writing'),
                subtitle: const Text('Outbox only'),
                value: controller.fileWritesEnabled,
                onChanged: controller.busy
                    ? null
                    : (value) => controller.setFileWriting(value),
              ),
            ),
          const SizedBox(height: HarnessSpace.sm),
          Text(
            'Capture only · no pointer or keyboard control',
            style: HarnessText.meta(context),
          ),
          if (controller.machineOs == 'ios')
            Text(
              'Screen capture · broadcast extension required',
              style: HarnessText.meta(context),
            ),
          if (controller.error != null) ...[
            const SizedBox(height: HarnessSpace.sm),
            Text(
              controller.error!,
              style: HarnessText.meta(context)
                  .copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (controller.notice != null) ...[
            const SizedBox(height: HarnessSpace.xs),
            Text(
              controller.notice!,
              style: HarnessText.meta(context)
                  .copyWith(color: HarnessColors.moss),
            ),
          ],
          const SizedBox(height: HarnessSpace.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!controller.registered)
                HarnessPrimaryButton(
                  label: 'Registration',
                  onPressed: controller.busy ? null : controller.register,
                )
              else ...[
                if (!controller.connected)
                  HarnessSecondaryButton(
                    label: 'Reconnection',
                    onPressed: controller.busy ? null : controller.attach,
                  ),
                HarnessSecondaryButton(
                  label: 'Disconnection',
                  onPressed: controller.busy ? null : controller.disconnect,
                ),
                HarnessSecondaryButton(
                  label: 'Revocation',
                  onPressed: controller.busy ? null : controller.revoke,
                ),
              ],
              HarnessSecondaryButton(
                label: 'File import',
                onPressed: controller.busy ? null : controller.importFile,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _sourceLabel(ComputerCaptureSource source) => switch (source) {
    ComputerCaptureSource.screen => 'screen',
    ComputerCaptureSource.camera => 'camera',
    ComputerCaptureSource.microphone => 'microphone',
  };
}

class _PhoneCapabilityRow extends StatelessWidget {
  const _PhoneCapabilityRow({
    required this.name,
    required this.enabled,
    required this.status,
    required this.onChanged,
  });

  final String name;
  final bool enabled;
  final ComputerCapabilityStatus? status;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final label = computerCapabilityLabels[name] ?? name;
    final state = status?.label ?? 'Not checked';
    final unavailable =
        status?.state == ComputerCapabilityState.unavailable &&
        status?.detail != 'Off on this phone';
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label),
        subtitle: Text(state),
        value: enabled,
        onChanged: unavailable ? null : onChanged,
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.computers,
    required this.connected,
    required this.resources,
  });

  final int computers;
  final int connected;
  final int resources;

  @override
  Widget build(BuildContext context) {
    return HarnessCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 42,
                height: 42,
                child: DitherPanel(
                  color: HarnessColors.oxide,
                  radius: 10,
                  child: SizedBox.expand(),
                ),
              ),
              const SizedBox(width: HarnessSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Computer use',
                      style: HarnessText.sheetTitle(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Screens, pointer, keyboard, sandbox',
                      style: HarnessText.meta(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HarnessSpace.lg),
          HarnessStatRow(
            stats: [
              ('$computers', 'Machines'),
              ('$connected', 'Connected'),
              ('$resources', 'Resources'),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.controller});

  final ComputersController controller;

  @override
  Widget build(BuildContext context) {
    final access = controller.access;
    if (access == null) {
      return const HarnessCardList(
        children: [
          _Row(
            title: 'No session',
            detail: 'Session grants',
            icon: Icons.person_outline_rounded,
          ),
        ],
      );
    }
    return HarnessCardList(
      children: [
        _Row(
          title: access.policyLabel,
          detail: 'Policy',
          icon: Icons.shield_outlined,
        ),
        _Row(
          title: controller.preferred?.name ?? 'None',
          detail: 'Preferred computer',
          icon: Icons.star_outline_rounded,
        ),
        _Row(
          title:
              '${access.entries.where((entry) => entry.allowed).length} '
              'of ${access.entries.length}',
          detail: 'Allowed for this session',
          icon: Icons.check_circle_outline_rounded,
        ),
      ],
    );
  }
}

class _ComputerCard extends StatelessWidget {
  const _ComputerCard({
    required this.computer,
    required this.controller,
    this.onView,
  });

  final Computer computer;
  final ComputersController controller;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final access = controller.access?.entry(computer.id);
    final controlling = computer.control == 'user';
    return HarnessCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        computer.name,
                        style: HarnessText.rowTitle(context),
                      ),
                    ),
                    HarnessStatusPill(
                      label: computer.stateLabel,
                      color: computer.connected
                          ? HarnessColors.moss
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                HarnessMetaLine(
                  parts: [
                    computer.kindLabel,
                    if (computer.id.isNotEmpty && computer.id != computer.kind)
                      computer.id,
                    if ((computer.display ?? '').isNotEmpty) computer.display!,
                  ],
                ),
                const SizedBox(height: HarnessSpace.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final capability in computer.capabilityNames)
                      _CapabilityChip(
                        label: _capabilityLabel(capability),
                        on:
                            access?.allowed == true &&
                            computer.allows(capability),
                        onTap: controller.canManage && access != null
                            ? () => unawaited(
                                controller.toggleCapability(
                                  computer,
                                  capability,
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: HarnessSpace.sm),
                Text(
                  _facts(computer, access),
                  style: HarnessText.meta(context),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (onView != null)
                  HarnessSecondaryButton(label: 'View', onPressed: onView),
                if (computer.connected)
                  HarnessSecondaryButton(
                    label: controlling ? 'Return' : 'Control',
                    onPressed: controller.canControl
                        ? () => unawaited(
                            controlling
                                ? controller.releaseControl(computer)
                                : controller.takeControl(computer),
                          )
                        : null,
                  ),
                if (access != null)
                  if (access.allowed)
                    HarnessSecondaryButton(
                      label: 'Revocation',
                      onPressed: controller.canManage
                          ? () => unawaited(controller.revoke(computer))
                          : null,
                    )
                  else
                    HarnessSecondaryButton(
                      label: 'Grant',
                      onPressed: controller.canManage
                          ? () => unawaited(controller.grant(computer))
                          : null,
                    ),
                if (access != null)
                  HarnessTextButton(
                    label: 'Preference',
                    onPressed:
                        controller.canManage &&
                            controller.access?.preferred != computer.id
                        ? () => unawaited(controller.prefer(computer))
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _facts(Computer computer, ComputerAccessEntry? access) {
    final parts = <String>[
      if ((computer.host ?? '').isNotEmpty) computer.host!,
      if (computer.resources.isNotEmpty)
        computer.resources.length == 1
            ? '1 resource'
            : '${computer.resources.length} resources',
      if (access != null)
        access.allowed
            ? 'Allowed${access.why == null ? '' : ' · ${access.why}'}'
            : 'Not allowed${access.why == null ? '' : ' · ${access.why}'}',
      if (computer.control != null) '${computer.controlLabel} control',
    ];
    return parts.isEmpty ? 'No facts' : parts.join(' · ');
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.on, this.onTap});

  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = on
        ? HarnessColors.oxide
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: HarnessText.meta(context)
            .copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
    if (onTap == null) return chip;
    return HarnessTap(onTap: onTap, child: chip);
  }
}

class _ResourceList extends StatelessWidget {
  const _ResourceList({required this.resources});

  final List<ComputerResource> resources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessCardList(
      children: [
        for (final resource in resources)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _resourceIcon(resource.kind),
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(resource.name, style: HarnessText.rowTitle(context)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          resource.kindLabel,
                          if ((resource.computerName ?? '').isNotEmpty)
                            resource.computerName!,
                          if ((resource.branch ?? '').isNotEmpty)
                            resource.branch!,
                        ].join(' · '),
                        style: HarnessText.meta(context),
                      ),
                      if ((resource.path ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            resource.path!,
                            style: HarnessText.mono(context).copyWith(
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
          ),
      ],
    );
  }

  IconData _resourceIcon(String kind) => switch (kind) {
    'git-repo' => Icons.account_tree_outlined,
    'display' => Icons.monitor_outlined,
    'gpu' => Icons.memory_rounded,
    'audio' => Icons.graphic_eq_rounded,
    _ => Icons.folder_outlined,
  };
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.detail, required this.icon});

  final String title;
  final String detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: HarnessText.rowTitle(context))),
          Text(detail, style: HarnessText.meta(context)),
        ],
      ),
    );
  }
}

String _capabilityLabel(String name) => switch (name) {
  'view' => 'View',
  'windows' => 'Windows',
  'pointer' => 'Pointer',
  'keyboard' => 'Keyboard',
  'clipboard' => 'Clipboard',
  'audio' => 'Audio',
  'camera' => 'Camera',
  'files' => 'Files',
  'sandbox' => 'Sandbox',
  'exec' => 'Exec',
  _ => name,
};
