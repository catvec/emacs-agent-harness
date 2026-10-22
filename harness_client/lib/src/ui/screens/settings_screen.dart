import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_controller.dart';
import '../../state/settings_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
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
          maxContentWidth: HarnessSpace.pageWidth,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.sm,
              HarnessSpace.gutter,
              30,
            ),
            children: [
              const HarnessSectionHeader(
                label: 'Connection',
                padding: EdgeInsets.fromLTRB(
                  HarnessSpace.xs,
                  HarnessSpace.xs,
                  HarnessSpace.xs,
                  HarnessSpace.sm,
                ),
              ),
              HarnessCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Who, where, and whether the line is up.
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: HarnessColors.moss.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.link_rounded,
                            size: 20,
                            color: HarnessColors.moss,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                app.capability?.agentName ?? 'Harness',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HarnessText.rowTitle(context),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                shortAddress(app.address),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HarnessText.caption(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        HarnessStatusLabel(
                          key: const Key('connection-status'),
                          label: app.isReconnecting
                              ? 'Reconnecting'
                              : 'Connected',
                          color: app.isReconnecting
                              ? HarnessColors.amber
                              : HarnessColors.moss,
                        ),
                      ],
                    ),
                    const SizedBox(height: HarnessSpace.md),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                    const SizedBox(height: HarnessSpace.sm),
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
                    const SizedBox(height: HarnessSpace.md),
                    Row(
                      children: [
                        Expanded(
                          // In place: the screens stay, and so does what was
                          // typed on them.  (It used to disconnect first,
                          // which threw them all away.)
                          child: HarnessSecondaryButton(
                            key: const Key('settings-reconnect'),
                            label: app.isReconnecting
                                ? 'Retry now'
                                : 'Reconnect',
                            icon: Icons.refresh_rounded,
                            expand: true,
                            onPressed: app.reconnect,
                          ),
                        ),
                        const SizedBox(width: HarnessSpace.sm),
                        Expanded(
                          child: HarnessSecondaryButton(
                            label: 'Disconnect',
                            icon: Icons.logout_rounded,
                            destructive: true,
                            expand: true,
                            onPressed: () async {
                              final confirmed = await showHarnessDialog<bool>(
                                context: context,
                                title: 'Disconnect?',
                                message:
                                    'The conversations stay on the harness. '
                                    'The app will not go back in by itself '
                                    'until you connect again.',
                                confirmLabel: 'Disconnect',
                                cancelLabel: 'Stay',
                              );
                              if (confirmed == true) await app.disconnect();
                            },
                          ),
                        ),
                      ],
                    ),
                    if (app.canSignOut) ...[
                      const SizedBox(height: HarnessSpace.sm),
                      HarnessSecondaryButton(
                        label: 'Sign out of this harness',
                        icon: Icons.key_off_rounded,
                        destructive: true,
                        expand: true,
                        onPressed: () async {
                          final confirmed = await showHarnessDialog<bool>(
                            context: context,
                            title: 'Sign out?',
                            message:
                                'This ends the session of this device on the '
                                'harness and forgets its secret here. Sign '
                                'in again to reconnect.',
                            confirmLabel: 'Sign out',
                            cancelLabel: 'Stay',
                          );
                          if (confirmed == true) await app.signOut();
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const HarnessSectionHeader(label: 'Appearance'),
              HarnessCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingRow(
                      icon: Icons.brightness_6_outlined,
                      title: 'Theme',
                      subtitle: 'Follow the system, or pin light or dark.',
                      below: HarnessSegmented<ThemeMode>(
                        options: const [
                          (ThemeMode.system, 'System'),
                          (ThemeMode.light, 'Light'),
                          (ThemeMode.dark, 'Dark'),
                        ],
                        value: settings.themeMode,
                        onChanged: settings.setThemeMode,
                      ),
                    ),
                    const SizedBox(height: HarnessSpace.lg),
                    _SettingRow(
                      icon: Icons.phone_iphone_rounded,
                      title: 'Platform feel',
                      subtitle:
                          'Cupertino controls on Apple platforms, Material 3 '
                          'elsewhere.',
                      below: HarnessSegmented<PreviewPlatform>(
                        options: const [
                          (PreviewPlatform.system, 'System'),
                          (PreviewPlatform.material, 'Android'),
                          (PreviewPlatform.cupertino, 'Apple'),
                        ],
                        value: settings.previewPlatform,
                        onChanged: settings.setPreviewPlatform,
                      ),
                    ),
                    const SizedBox(height: HarnessSpace.md),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            settings.useCupertino
                                ? 'Cupertino navigation, sheets and typography are active.'
                                : 'Material 3 navigation, sheets and typography are active.',
                            style: HarnessText.caption(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const HarnessSectionHeader(label: 'Chat'),
              HarnessCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: HarnessSpace.lg,
                  vertical: HarnessSpace.sm,
                ),
                child: Column(
                  children: [
                    _SettingRow(
                      icon: Icons.psychology_outlined,
                      title: 'Show thinking',
                      subtitle:
                          'Show the agent’s streamed thoughts, collapsed.',
                      trailing: HarnessSwitch(
                        value: settings.showThinking,
                        onChanged: settings.setShowThinking,
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                    _SettingRow(
                      icon: Icons.key_outlined,
                      title: 'Remember',
                      subtitle:
                          'Stay signed in: keep the address and session here.',
                      trailing: HarnessSwitch(
                        value: settings.rememberConnection,
                        onChanged: settings.setRememberConnection,
                      ),
                    ),
                  ],
                ),
              ),
              if (app.canSetNonInteractiveEverywhere) ...[
                const HarnessSectionHeader(label: 'Conversations'),
                HarnessCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HarnessSpace.lg,
                    vertical: HarnessSpace.sm,
                  ),
                  child: _SettingRow(
                    icon: Icons.hourglass_disabled_rounded,
                    title: 'Non-interactive',
                    subtitle:
                        'Every conversation and task runs without waiting '
                        'for you, and new ones start that way. Each '
                        'conversation can still be switched on its own.',
                    trailing: HarnessSwitch(
                      key: const Key('settings-non-interactive'),
                      value: app.defaultNonInteractive ?? false,
                      onChanged: app.updatingNonInteractive
                          ? null
                          : app.setNonInteractiveEverywhere,
                    ),
                  ),
                ),
              ],
              const HarnessSectionHeader(label: 'About'),
              HarnessCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        HarnessMark(size: 30, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Harness',
                                style: HarnessText.rowTitle(context),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                'Version 1.0.0 · ACP 1',
                                style: HarnessText.caption(context),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: HarnessSpace.md),
                    Text(
                      'A native client for the emacs-agent-harness. It detects '
                      'the harness’s extensions one by one; when only standard '
                      'ACP is offered, the chat and permissions still work and '
                      'the enhanced views stay out of the way.',
                      style: HarnessText.subtitle(context)
                          .copyWith(height: 1.5),
                    ),
                    const SizedBox(height: HarnessSpace.sm),
                    Wrap(
                      spacing: HarnessSpace.xs,
                      runSpacing: HarnessSpace.xs,
                      children: [
                        HarnessTextButton(
                          label: 'Agent Client Protocol',
                          icon: Icons.open_in_new_rounded,
                          dense: true,
                          onPressed: () => launchUrl(
                            Uri.parse('https://agentclientprotocol.com'),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                        HarnessTextButton(
                          label: 'Copy diagnostics',
                          icon: Icons.copy_rounded,
                          dense: true,
                          onPressed: () => _copyDiagnostics(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: HarnessSpace.xl),
              Center(
                child: Text(
                  'Made for people who run agents on their own machines.',
                  textAlign: TextAlign.center,
                  style: HarnessText.caption(context).copyWith(fontSize: 11.5),
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

/// One setting: its icon, its name and what it does, and what changes it,
/// which is either at the far edge ([trailing], a switch) or under the text,
/// across the width of the card ([below], a segmented control).
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.below,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: HarnessText.rowTitle(context)),
              const SizedBox(height: 1),
              Text(subtitle, style: HarnessText.caption(context)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
    if (below == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: heading,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [heading, const SizedBox(height: 12), below!],
    );
  }
}
