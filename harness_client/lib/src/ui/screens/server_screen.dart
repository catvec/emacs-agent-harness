import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../acp/capabilities.dart';
import '../../models/server_info.dart';
import '../../state/app_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../adaptive/layout_widgets.dart';
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
          maxContentWidth: HarnessSpace.pageWidth,
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
            padding: const EdgeInsets.fromLTRB(
              HarnessSpace.gutter,
              HarnessSpace.sm,
              HarnessSpace.gutter,
              28,
            ),
            children: [
              _ServerHero(app: app, caps: caps),
              const HarnessSectionHeader(label: 'What this client sees'),
              _FeatureTable(caps: caps),
              if (app.server?.version != null || caps.harnessInfo) ...[
                const HarnessSectionHeader(label: 'Harness'),
                _HarnessInfoCard(app: app),
              ],
              if (app.server?.providers.isNotEmpty ?? false) ...[
                const HarnessSectionHeader(label: 'Models'),
                _ProvidersCard(providers: app.server!.providers),
              ],
              if (app.projects.isNotEmpty) ...[
                const HarnessSectionHeader(label: 'Projects'),
                _ProjectsCard(projects: app.projects),
              ],
              const HarnessSectionHeader(label: 'Extension methods'),
              _MethodsCard(methods: caps.methods),
              const HarnessSectionHeader(label: 'Events forwarded'),
              _EventsCard(
                values: caps.events.toList()..sort(),
                empty: 'No enhanced events.',
              ),
              const HarnessSectionHeader(label: 'Raw initialize'),
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
      padding: const EdgeInsets.all(HarnessSpace.lg + 2),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Who this is, and whether its extensions were found.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      caps.agentName,
                      style: HarnessText.sheetTitle(context),
                    ),
                    const SizedBox(height: 3),
                    HarnessMetaLine(
                      parts: [
                        if (caps.agentVersion.isNotEmpty)
                          'v${caps.agentVersion}',
                        'ACP ${caps.protocolVersion}',
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HarnessSpace.md),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: HarnessStatusLabel(
                  label: caps.isHarness ? 'Harness' : 'Standard ACP',
                  color: caps.isHarness
                      ? HarnessColors.moss
                      : theme.colorScheme.onSurfaceVariant,
                  icon: caps.isHarness
                      ? Icons.bolt_rounded
                      : Icons.cable_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: HarnessSpace.lg),
          HarnessStatRow(
            stats: [
              (
                '${caps.features.where((feature) => feature.enabled).length}',
                'Features',
              ),
              ('${caps.methods.length}', 'Methods'),
              ('${caps.events.length}', 'Events'),
            ],
          ),
          const SizedBox(height: HarnessSpace.md),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
          ),
          const SizedBox(height: HarnessSpace.sm),
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

/// What the client found out, one capability to a row: a mark for whether it
/// is on, its name (and where it comes from), what it is for.  An off one is
/// dimmed, and says so to a screen reader.
class _FeatureTable extends StatelessWidget {
  const _FeatureTable({required this.caps});
  final HarnessCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessCardList(
      dividerIndent: 44,
      children: [
        for (final feature in caps.features)
          Semantics(
            label:
                '${feature.name}, ${feature.enabled ? 'on' : 'off'}. '
                '${feature.description}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      feature.enabled
                          ? Icons.check_circle_rounded
                          : Icons.remove_circle_outline_rounded,
                      size: 18,
                      color: feature.enabled
                          ? HarnessColors.moss
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.45,
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Flexible(
                              child: Text(
                                feature.name,
                                style: HarnessText.rowTitle(context).copyWith(
                                  fontSize: 14,
                                  color: feature.enabled
                                      ? null
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (feature.standard) ...[
                              const SizedBox(width: 8),
                              Text(
                                'ACP',
                                style: HarnessText.label(context)
                                    .copyWith(letterSpacing: 0.6),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 1),
                        Text(
                          feature.description,
                          style: HarnessText.caption(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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
    return HarnessCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
            // The loaded modules, as a list in the value column: the core
            // ones in full strength and the optional ones dimmed.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  SizedBox(
                    width: HarnessInfoRow.labelWidth,
                    child: Text(
                      'Modules',
                      style: HarnessText.subtitle(context),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      children: [
                        for (final module in modules)
                          Text(
                            module.name,
                            style: HarnessText.body(context).copyWith(
                              height: 1.35,
                              color: module.optional
                                  ? theme.colorScheme.onSurfaceVariant
                                  : null,
                              fontWeight: module.optional
                                  ? FontWeight.w400
                                  : FontWeight.w600,
                            ),
                          ),
                      ],
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

/// The providers and their models: a provider is a row, its models are
/// listed under it.
class _ProvidersCard extends StatelessWidget {
  const _ProvidersCard({required this.providers});
  final List<ProviderInfo> providers;

  static const _shown = 12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessCardList(
      dividerIndent: 14,
      children: [
        for (final provider in providers)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        provider.label,
                        style: HarnessText.rowTitle(context)
                            .copyWith(fontSize: 14),
                      ),
                    ),
                    Text(
                      provider.models.length == 1
                          ? '1 model'
                          : '${provider.models.length} models',
                      style: HarnessText.meta(context),
                    ),
                  ],
                ),
                for (final model in provider.models.take(_shown))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      model.id.contains(':') ? modelName(model.id) : model.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.mono(context)
                          .copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                if (provider.models.length > _shown)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '+${provider.models.length - _shown} more',
                      style: HarnessText.caption(context),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProjectsCard extends StatelessWidget {
  const _ProjectsCard({required this.projects});
  final List<String> projects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HarnessCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        children: [
          for (final project in projects)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      project,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.mono(context),
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

/// The extension methods, a group to a row: the group's name in a column of
/// its own, and its methods beside it as plain monospace words.
class _MethodsCard extends StatelessWidget {
  const _MethodsCard({required this.methods});
  final Set<String> methods;

  static const _groupWidth = 92.0;

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
    final mono = HarnessText.mono(context);
    return HarnessCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (methods.isEmpty)
            Text(
              'No extension methods. Standard ACP only.',
              style: HarnessText.subtitle(context),
            ),
          for (var index = 0; index < groups.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _groupWidth,
                    child: Text(
                      groups[index],
                      style: mono.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      children: [
                        for (final method in grouped[groups[index]]!)
                          Text(
                            // `agent/prompt` under `agent` is `prompt`.
                            method.contains('/')
                                ? method.substring(method.indexOf('/') + 1)
                                : method,
                            style: mono,
                          ),
                      ],
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

/// A flat list of names (the events), in monospace words, left to right.
class _EventsCard extends StatelessWidget {
  const _EventsCard({required this.values, required this.empty});
  final List<String> values;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return HarnessCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: values.isEmpty
          ? Text(empty, style: HarnessText.subtitle(context))
          : Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (final value in values)
                  Text(value, style: HarnessText.mono(context)),
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
            style: HarnessText.mono(context).copyWith(fontSize: 11),
          ),
        ),
      ),
    );
  }
}
