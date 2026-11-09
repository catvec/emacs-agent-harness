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
                                title: 'Disconnection',
                                message:
                                    'Conversations stay on the harness · no automatic reconnection',
                                confirmLabel: 'Disconnection',
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
                        label: 'Device sign-out',
                        icon: Icons.key_off_rounded,
                        destructive: true,
                        expand: true,
                        onPressed: () async {
                          final confirmed = await showHarnessDialog<bool>(
                            context: context,
                            title: 'Sign-out',
                            message:
                                'Device session ends · secret forgotten · sign-in needed',
                            confirmLabel: 'Sign-out',
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
                      subtitle: 'System, light or dark',
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
                      key: const Key('setting-look'),
                      icon: Icons.devices_rounded,
                      title: 'Look',
                      subtitle: 'System, or a platform\'s controls',
                      below: HarnessSelect<PreviewPlatform>(
                        key: const Key('look-select'),
                        title: 'Look',
                        hint: 'System',
                        icon: Icons.devices_rounded,
                        value: settings.previewPlatform,
                        options: const [
                          HarnessMenuItem(
                            value: PreviewPlatform.system,
                            label: 'System',
                          ),
                          HarnessMenuItem(
                            value: PreviewPlatform.material,
                            label: 'Android',
                          ),
                          HarnessMenuItem(
                            value: PreviewPlatform.cupertino,
                            label: 'Apple',
                          ),
                          HarnessMenuItem(
                            value: PreviewPlatform.windows,
                            label: 'Windows',
                          ),
                          HarnessMenuItem(
                            value: PreviewPlatform.linux,
                            label: 'Linux',
                          ),
                        ],
                        onChanged: settings.setPreviewPlatform,
                      ),
                    ),
                    const SizedBox(height: HarnessSpace.sm),
                    Text(
                      _look(settings.previewPlatform).label,
                      key: const Key('look-active'),
                      style: HarnessText.caption(context),
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
                      title: 'Thinking display',
                      subtitle:
                          'Agent thoughts · streamed, collapsed',
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
                      key: const Key('settings-remember'),
                      icon: Icons.key_outlined,
                      title: 'Remember',
                      // When the device cannot keep anything, say so here
                      // instead of promising what the switch cannot do.
                      subtitle:
                          settings.persistenceProblem ??
                          'Remembered connection · address and session kept',
                      trailing: HarnessSwitch(
                        value: settings.rememberConnection,
                        onChanged: settings.setRememberConnection,
                      ),
                    ),
                  ],
                ),
              ),
              const HarnessSectionHeader(label: 'Keys'),
              HarnessCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingRow(
                      icon: Icons.send_rounded,
                      title: 'Send with',
                      subtitle: 'Enter, or C-c C-c as in Emacs.',
                      below: HarnessSegmented<SendKey>(
                        key: const Key('settings-send-with'),
                        options: const [
                          (SendKey.enter, 'Enter'),
                          (SendKey.ctrlCctrlC, 'C-c C-c'),
                        ],
                        value: settings.sendKey,
                        onChanged: settings.setSendKey,
                      ),
                    ),
                    const SizedBox(height: HarnessSpace.lg),
                    _SettingRow(
                      icon: Icons.keyboard_alt_outlined,
                      title: 'Emacs editing',
                      subtitle:
                          'C-a, C-e, C-k, C-y, M-f and M-b in text fields.',
                      trailing: HarnessSwitch(
                        key: const Key('settings-emacs-editing'),
                        value: settings.emacsEditing,
                        onChanged: settings.setEmacsEditing,
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                    _SettingRow(
                      icon: Icons.keyboard_command_key_rounded,
                      title: 'Harness keys',
                      subtitle:
                          'C-c commands: send, stop, attach, search, copy '
                          'reply, bottom.',
                      trailing: HarnessSwitch(
                        key: const Key('settings-harness-keys'),
                        value: settings.harnessKeys,
                        onChanged: settings.setHarnessKeys,
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
                        'No waiting · every conversation and task · each switchable',
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
                      'Native client · emacs-agent-harness · ACP extensions · chat and permissions without them',
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
                  'Agent harness · own machines',
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
      'platformStyle': HarnessStyle.lookOf(context).name,
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

/// The look a choice in Settings shows, for the caption under it.
HarnessPlatformStyle _look(PreviewPlatform platform) => switch (platform) {
  PreviewPlatform.system => HarnessPlatformStyle.current,
  PreviewPlatform.material => HarnessPlatformStyle.material,
  PreviewPlatform.cupertino => HarnessPlatformStyle.cupertino,
  PreviewPlatform.windows => HarnessPlatformStyle.windows,
  PreviewPlatform.linux => HarnessPlatformStyle.linux,
};

/// One setting: its icon, its name and what it does, and what changes it,
/// which is either at the far edge ([trailing], a switch) or under the text,
/// across the width of the card ([below], a segmented control).
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
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
