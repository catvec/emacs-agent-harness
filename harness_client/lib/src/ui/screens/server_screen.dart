import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../acp/capabilities.dart';
import '../../models/server_info.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';

class ServerScreen extends StatelessWidget {
  const ServerScreen({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final caps = app.capability;
        if (caps == null) {
          return const Center(child: HarnessActivity(radius: 10));
        }
        return HarnessPage(
          title: 'Server',
          actions: [
            HarnessIconButton(
              icon: adaptiveIcon(
                context,
                Icons.refresh_rounded,
                CupertinoIcons.arrow_clockwise,
              ),
              label: 'Refresh server',
              onPressed: app.refreshServer,
            ),
          ],
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              _ServerHero(app: app, caps: caps),
              const HarnessSectionHeader(
                label: 'What this client sees',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _FeatureTable(caps: caps),
              if (app.server?.version != null || caps.harnessInfo) ...[
                const HarnessSectionHeader(
                  label: 'Harness',
                  padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
                ),
                _HarnessInfoCard(app: app),
              ],
              if (app.server?.providers.isNotEmpty ?? false) ...[
                const HarnessSectionHeader(
                  label: 'Models',
                  padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
                ),
                _ProvidersCard(providers: app.server!.providers),
              ],
              if (app.projects.isNotEmpty) ...[
                const HarnessSectionHeader(
                  label: 'Projects',
                  padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
                ),
                _ProjectsCard(projects: app.projects),
              ],
              const HarnessSectionHeader(
                label: 'Extension methods',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _MethodsCard(methods: caps.methods),
              const HarnessSectionHeader(
                label: 'Events forwarded',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _ChipsCard(
                values: caps.events.toList()..sort(),
                empty: 'No enhanced events.',
              ),
              const HarnessSectionHeader(
                label: 'Raw initialize',
                padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
              ),
              _RawCard(caps: caps),
              if (app.serverLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: HarnessActivity(radius: 9)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ServerHero extends StatelessWidget {
  const _ServerHero({required this.app, required this.caps});
  final AppController app;
  final HarnessCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF1B1A1D), const Color(0xFF141416)]
              : [const Color(0xFFFFFCF8), const Color(0xFFF3EEE6)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      caps.agentName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (caps.agentVersion.isNotEmpty)
                          'v${caps.agentVersion}',
                        'ACP ${caps.protocolVersion}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              HarnessStatusPill(
                label: caps.isHarness ? 'Harness' : 'Standard ACP',
                color: caps.isHarness
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant,
                icon: caps.isHarness ? Icons.bolt_rounded : Icons.cable_rounded,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _HeroStat(
                label: 'Features',
                value:
                    '${caps.features.where((feature) => feature.enabled).length}',
                color: caps.isHarness
                    ? HarnessColors.moss
                    : theme.colorScheme.onSurfaceVariant,
              ),
              _HeroStat(
                label: 'Methods',
                value: '${caps.methods.length}',
                color: theme.colorScheme.primary,
              ),
              _HeroStat(
                label: 'Events',
                value: '${caps.events.length}',
                color: HarnessColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 14),
          HarnessInfoRow(
            label: 'Address',
            value: app.address ?? '—',
            monospace: true,
          ),
          HarnessInfoRow(
            label: 'Transport',
            value: app.address?.startsWith('ws') == true || app.web
                ? 'WebSocket'
                : 'TCP line framing',
          ),
          if (caps.authMethods.isNotEmpty)
            HarnessInfoRow(
              label: 'Auth methods',
              value: caps.authMethods.map((method) => method.name).join(', '),
            ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
                fontSize: 18,
              ),
            ),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 9.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureTable extends StatelessWidget {
  const _FeatureTable({required this.caps});
  final HarnessCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var index = 0; index < caps.features.length; index++)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                border: index == caps.features.length - 1
                    ? null
                    : Border(
                        bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
              ),
              child: Row(
                children: [
                  Icon(
                    caps.features[index].enabled
                        ? Icons.check_circle_rounded
                        : Icons.remove_circle_outline_rounded,
                    size: 17,
                    color: caps.features[index].enabled
                        ? HarnessColors.moss
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.45,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              caps.features[index].name,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (caps.features[index].standard) ...[
                              const SizedBox(width: 6),
                              Text(
                                'ACP',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 8,
                                  letterSpacing: 0.7,
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          caps.features[index].description,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    caps.features[index].enabled ? 'on' : 'off',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: caps.features[index].enabled
                          ? HarnessColors.moss
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
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

class _HarnessInfoCard extends StatelessWidget {
  const _HarnessInfoCard({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = app.server?.version;
    final modules = app.server?.modules ?? const <HarnessModule>[];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HarnessInfoRow(
            label: 'Harness',
            value: version?.version ?? 'not reported',
          ),
          HarnessInfoRow(
            label: 'Emacs',
            value: version?.emacs ?? 'not reported',
          ),
          if (modules.isNotEmpty)
            HarnessInfoRow(label: 'Modules', value: '${modules.length} loaded'),
          if (modules.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final module in modules)
                  HarnessStatusPill(
                    label: module.name,
                    color: module.optional
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProvidersCard extends StatelessWidget {
  const _ProvidersCard({required this.providers});
  final List<ProviderInfo> providers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var index = 0; index < providers.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.memory_rounded, size: 15),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    providers[index].label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${providers[index].models.length} models',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (providers[index].models.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final model in providers[index].models.take(12))
                      HarnessStatusPill(
                        label: model.id.contains(':')
                            ? modelName(model.id)
                            : model.id,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    if (providers[index].models.length > 12)
                      HarnessStatusPill(
                        label: '+${providers[index].models.length - 12}',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProjectsCard extends StatelessWidget {
  const _ProjectsCard({required this.projects});
  final List<String> projects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (final project in projects)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 15),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      project,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                      ),
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

class _MethodsCard extends StatelessWidget {
  const _MethodsCard({required this.methods});
  final Set<String> methods;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = <String, List<String>>{};
    for (final method in methods.toList()..sort()) {
      final slash = method.indexOf('/');
      final group = slash < 0 ? 'other' : method.substring(0, slash);
      grouped.putIfAbsent(group, () => []).add(method);
    }
    final groups = grouped.keys.toList()..sort();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (methods.isEmpty)
            Text(
              'No extension methods. Standard ACP only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          for (final group in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final method in grouped[group]!)
                        HarnessStatusPill(
                          label: method.substring(group.length + 1),
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChipsCard extends StatelessWidget {
  const _ChipsCard({required this.values, required this.empty});
  final List<String> values;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: values.isEmpty
          ? Text(
              empty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final value in values)
                  HarnessStatusPill(
                    label: value,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
    );
  }
}

class _RawCard extends StatelessWidget {
  const _RawCard({required this.caps});
  final HarnessCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(caps.raw),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}
