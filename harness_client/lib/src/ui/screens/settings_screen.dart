import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_controller.dart';
import '../../state/settings_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/mark.dart';
import '../adaptive/platform_style.dart';
import '../format.dart';
import '../theme/harness_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final settings = app.settings;
    return AnimatedBuilder(
      animation: Listenable.merge([app, settings]),
      builder: (context, _) {
        final theme = Theme.of(context);
        return HarnessPage(
          title: 'Settings',
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
            children: [
              const HarnessSectionHeader(
                label: 'Connection',
                padding: EdgeInsets.fromLTRB(2, 4, 2, 8),
              ),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: HarnessColors.moss.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.link_rounded,
                            size: 19,
                            color: HarnessColors.moss,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                app.capability?.agentName ?? 'Harness',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                shortAddress(app.address),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        HarnessStatusPill(
                          label: 'Connected',
                          color: HarnessColors.moss,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    HarnessInfoRow(
                      label: 'Protocol',
                      value:
                          'ACP ${app.capability?.protocolVersion ?? 1} · ${app.web ? 'WebSocket' : 'TCP or WebSocket'}',
                    ),
                    HarnessInfoRow(
                      label: 'Extensions',
                      value:
                          '${app.capability?.extensionCount ?? 0} harness methods',
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: HarnessSecondaryButton(
                            label: 'Reconnect',
                            icon: Icons.refresh_rounded,
                            onPressed: () async {
                              final address = app.address;
                              final token = app.settings.token;
                              await app.disconnect();
                              if (address != null) {
                                await app.connect(address, token: token);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: HarnessSecondaryButton(
                            label: 'Disconnect',
                            icon: Icons.logout_rounded,
                            destructive: true,
                            onPressed: () async {
                              final confirmed = await showHarnessDialog<bool>(
                                context: context,
                                title: 'Disconnect?',
                                message:
                                    'The conversations stay on the harness. '
                                    'You can reconnect at any time.',
                                confirmLabel: 'Disconnect',
                                cancelLabel: 'Stay',
                              );
                              if (confirmed == true) await app.disconnect();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const HarnessSectionHeader(
                label: 'Appearance',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingRow(
                      icon: Icons.brightness_6_outlined,
                      title: 'Theme',
                      subtitle: 'Follow the system, or pin light or dark.',
                      stacked: true,
                      child: HarnessSegmented<ThemeMode>(
                        options: const [
                          (ThemeMode.system, 'System'),
                          (ThemeMode.light, 'Light'),
                          (ThemeMode.dark, 'Dark'),
                        ],
                        value: settings.themeMode,
                        onChanged: settings.setThemeMode,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SettingRow(
                      icon: Icons.phone_iphone_rounded,
                      title: 'Platform feel',
                      subtitle: 'Cupertino controls on Apple platforms, Material 3 elsewhere.',
                      stacked: true,
                      child: HarnessSegmented<PreviewPlatform>(
                        options: const [
                          (PreviewPlatform.system, 'System'),
                          (PreviewPlatform.material, 'Android'),
                          (PreviewPlatform.cupertino, 'Apple'),
                        ],
                        value: settings.previewPlatform,
                        onChanged: settings.setPreviewPlatform,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            settings.useCupertino
                                ? 'Cupertino navigation, sheets and typography are active.'
                                : 'Material 3 navigation, sheets and typography are active.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const HarnessSectionHeader(
                label: 'Chat',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _Card(
                child: Column(
                  children: [
                    _SettingRow(
                      icon: Icons.psychology_outlined,
                      title: 'Show thinking',
                      subtitle:
                          'Show the agent’s streamed thoughts, collapsed.',
                      child: HarnessSwitch(
                        value: settings.showThinking,
                        onChanged: settings.setShowThinking,
                      ),
                    ),
                    Divider(
                      height: 20,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    _SettingRow(
                      icon: Icons.key_outlined,
                      title: 'Remember',
                      subtitle: 'Keep the address and token on this device.',
                      child: HarnessSwitch(
                        value: settings.rememberConnection,
                        onChanged: settings.setRememberConnection,
                      ),
                    ),
                  ],
                ),
              ),
              const HarnessSectionHeader(
                label: 'About',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        HarnessMark(size: 28, color: theme.colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Harness',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'Version 1.0.0 · ACP 1',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'A native client for the emacs-agent-harness. It detects '
                      'the harness’s extensions one by one; when only standard '
                      'ACP is offered, the chat and permissions still work and '
                      'the enhanced views stay out of the way.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        HarnessTextButton(
                          label: 'Agent Client Protocol',
                          icon: Icons.open_in_new_rounded,
                          onPressed: () => launchUrl(
                            Uri.parse('https://agentclientprotocol.com'),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                        HarnessTextButton(
                          label: 'Copy diagnostics',
                          icon: Icons.copy_rounded,
                          onPressed: () => _copyDiagnostics(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Made for people who run agents on their own machines.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyDiagnostics(BuildContext context) async {
    final caps = app.capability;
    final diagnostics = const JsonEncoder.withIndent('  ').convert({
      'app': 'Harness 1.0.0',
      'platformStyle':
          HarnessStyle.of(context).style == HarnessPlatformStyle.cupertino
          ? 'cupertino'
          : 'material',
      'address': app.address,
      'phase': app.phase.name,
      'agent': caps?.agentName,
      'agentVersion': caps?.agentVersion,
      'protocolVersion': caps?.protocolVersion,
      'isHarness': caps?.isHarness,
      'extensionCount': caps?.extensionCount,
      'methods': (caps?.methods.toList() ?? <String>[])..sort(),
      'events': (caps?.events.toList() ?? <String>[])..sort(),
      'features': {
        for (final feature in caps?.features ?? const [])
          feature.name: feature.enabled,
      },
    });
    await Clipboard.setData(ClipboardData(text: diagnostics));
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.stacked = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [heading, const SizedBox(height: 10), child],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: heading),
        const SizedBox(width: 10),
        Flexible(child: child),
      ],
    );
  }
}
