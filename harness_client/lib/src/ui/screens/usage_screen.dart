import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../acp/acp_message.dart';
import '../../models/session.dart';
import '../../models/usage.dart';
import '../../state/app_controller.dart';
import '../../state/usage_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/quota_widgets.dart';

class UsageScreen extends StatelessWidget {
  const UsageScreen({
    super.key,
    required this.app,
    required this.onOpenSession,
  });

  final AppController app;
  final ValueChanged<String> onOpenSession;

  @override
  Widget build(BuildContext context) {
    final controller = app.usage;
    if (controller == null) {
      return const Center(child: HarnessActivity(radius: 10));
    }
    return AnimatedBuilder(
      animation: Listenable.merge([controller, app]),
      builder: (context, _) {
        final overview = controller.overview;
        final quota = app.quota;
        final plans = quota?.quotas ?? const [];
        // Asking again also has the providers ask their plans again.
        Future<void> reload() => Future.wait([
          controller.load(project: app.selectedProject),
          if (quota != null) quota.load(refresh: true),
        ]);
        return HarnessPage(
          title: 'Usage',
          actions: [
            HarnessIconButton(
              icon: adaptiveIcon(
                context,
                Icons.folder_outlined,
                CupertinoIcons.folder,
              ),
              label: 'Usage project',
              onPressed: () async {
                final chosen = await showHarnessMenu<String>(
                  context: context,
                  title: 'Usage project',
                  items: [
                    const HarnessMenuItem(value: '', label: 'All projects'),
                    for (final project in app.projects)
                      HarnessMenuItem(
                        value: project,
                        label: projectName(project),
                        icon: Icons.folder_outlined,
                      ),
                  ],
                );
                if (chosen != null) {
                  app.selectProject(chosen.isEmpty ? null : chosen);
                }
              },
            ),
            HarnessIconButton(
              icon: adaptiveIcon(
                context,
                Icons.refresh_rounded,
                CupertinoIcons.arrow_clockwise,
              ),
              label: 'Refresh usage',
              onPressed: reload,
            ),
          ],
          body: RefreshIndicator(
            onRefresh: reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
              children: [
                if (controller.error != null)
                  HarnessErrorBanner(message: controller.error!),
                _ScopeLine(app: app, controller: controller),
                const SizedBox(height: 12),
                _SpendHero(overview: overview, project: app.selectedProject),
                // How each provider bills and what is left of its plan,
                // beside what the plan has covered.
                if (plans.isNotEmpty) ...[
                  HarnessSectionHeader(
                    label: 'Plan',
                    padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
                    trailing: _PlanRefresh(
                      busy: quota!.loading,
                      onPressed: () =>
                          quota.load(refresh: true, showSpinner: true),
                    ),
                  ),
                  for (final plan in plans)
                    PlanCard(label: quota.labelOf(plan.provider), quota: plan),
                ],
                if (overview.live.isNotEmpty) ...[
                  const HarnessSectionHeader(
                    label: 'Live now',
                    padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
                  ),
                  for (final live in overview.live)
                    _LiveRow(
                      live: live,
                      session: app.summaryFor(live.sessionId),
                      onTap: () => onOpenSession(live.sessionId),
                    ),
                ],
                const HarnessSectionHeader(
                  label: 'Spend by day',
                  padding: EdgeInsets.fromLTRB(2, 22, 2, 8),
                ),
                _SpendChart(points: overview.byDay),
                if (overview.byModel.isNotEmpty) ...[
                  const HarnessSectionHeader(
                    label: 'Models',
                    padding: EdgeInsets.fromLTRB(2, 24, 2, 8),
                  ),
                  _UsageBars(rows: overview.byModel),
                ],
                if (overview.byProject.isNotEmpty) ...[
                  const HarnessSectionHeader(
                    label: 'Projects',
                    padding: EdgeInsets.fromLTRB(2, 24, 2, 8),
                  ),
                  _UsageBars(rows: overview.byProject, showMain: true),
                ],
                if (overview.budgets.isNotEmpty) ...[
                  const HarnessSectionHeader(
                    label: 'Budgets',
                    padding: EdgeInsets.fromLTRB(2, 24, 2, 8),
                  ),
                  if (plans.any((plan) => plan.isPlan))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
                      child: Text(
                        'Budgets count billed cost; calls a plan covers do '
                        'not spend them.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final budget in overview.budgets)
                    _BudgetRow(budget: budget),
                ],
                if (overview.totals.calls == 0 && !controller.loading) ...[
                  const SizedBox(height: 30),
                  HarnessEmptyState(
                    icon: Icons.insights_rounded,
                    title: 'No usage recorded yet',
                    message:
                        'Once this harness makes model calls, its spend, tokens and '
                        'cache use appear here.',
                  ),
                ],
                if (controller.loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 30),
                    child: Center(child: HarnessActivity(radius: 10)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Asks the providers for their plans' quota again.
class _PlanRefresh extends StatelessWidget {
  const _PlanRefresh({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: 'Refresh plan quota',
      excludeSemantics: true,
      child: SizedBox(
        height: 24,
        child: busy
            ? const Center(child: HarnessActivity(radius: 7))
            : HarnessTap(
                key: const Key('plan-refresh'),
                onTap: onPressed,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh_rounded, size: 14, color: color),
                      const SizedBox(width: 4),
                      Text(
                        'Refresh',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _ScopeLine extends StatelessWidget {
  const _ScopeLine({required this.app, required this.controller});
  final AppController app;
  final UsageController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = app.selectedProject == null
        ? 'All projects'
        : projectName(app.selectedProject);
    return Row(
      children: [
        Icon(
          Icons.folder_outlined,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            scope,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (controller.lastLoaded != null)
          Text(
            'Updated ${relativeTime(controller.lastLoaded)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
      ],
    );
  }
}

class _SpendHero extends StatelessWidget {
  const _SpendHero({required this.overview, this.project});
  final UsageOverview overview;
  final String? project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final totals = overview.totals;
    final covered = totals.listCost - totals.cost;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  const Color(0xFF2A1A14),
                  const Color(0xFF1A1512),
                  const Color(0xFF141416),
                ]
              : [
                  const Color(0xFFF4DDD2),
                  const Color(0xFFF8EFE7),
                  const Color(0xFFFFFFFF),
                ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: HarnessColors.oxide.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'SPEND',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: HarnessColors.oxide,
                ),
              ),
              const Spacer(),
              HarnessStatusPill(
                label: '${totals.calls} calls',
                color: HarnessColors.oxide,
                icon: Icons.bolt_rounded,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            formatMoney(totals.cost),
            style: theme.textTheme.displaySmall?.copyWith(
              fontSize: 46,
              fontWeight: FontWeight.w700,
              letterSpacing: -2,
              height: 1.05,
            ),
          ),
          if (covered > 0.005)
            Text(
              '${formatMoney(totals.listCost)} at list prices · ${formatMoney(covered)} covered',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              _Stat(label: 'Tokens', value: formatTokens(totals.tokens)),
              _Stat(label: 'Input', value: formatTokens(totals.input)),
              _Stat(label: 'Output', value: formatTokens(totals.output)),
              _Stat(label: 'Cache read', value: formatTokens(totals.cacheRead)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              fontFeatures: const [FontFeature.tabularFigures()],
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
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow({
    required this.live,
    required this.session,
    required this.onTap,
  });
  final LiveUsage live;
  final SessionSummary? session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = session?.displayTitle ?? 'Running session';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: HarnessColors.moss.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  size: 16,
                  color: HarnessColors.moss,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${formatTokens(live.context)} context · ${formatTokens(live.output)} output'
                      '${live.estimated ? ' · estimated' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              _LivePulse(),
            ],
          ),
        ),
      ),
    );
  }
}

class _LivePulse extends StatefulWidget {
  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: HarnessColors.moss.withValues(
            alpha: 0.3 + _controller.value * 0.6,
          ),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _SpendChart extends StatelessWidget {
  const _SpendChart({required this.points});
  final List<UsageAggregate> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = points.length > 14
        ? points.sublist(points.length - 14)
        : points;
    if (recent.isEmpty) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          'No daily spend yet.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final maxCost = recent.map((point) => point.cost).fold<double>(0, math.max);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 110,
            child: CustomPaint(
              painter: _BarPainter(
                values: [for (final point in recent) point.cost],
                maxValue: maxCost == 0 ? 1 : maxCost,
                color: theme.colorScheme.primary,
                track: theme.colorScheme.surfaceContainerHigh,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final point in recent)
                Expanded(
                  child: Text(
                    _shortDay(point.key),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 8,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _shortDay(String? key) {
    final parsed = DateTime.tryParse(key ?? '');
    if (parsed == null) return '';
    return DateFormat('E').format(parsed).substring(0, 1);
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.values,
    required this.maxValue,
    required this.color,
    required this.track,
  });

  final List<double> values;
  final double maxValue;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final gap = 4.0;
    final width = (size.width - gap * (values.length - 1)) / values.length;
    final radius = Radius.circular(math.min(4, width / 2));
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      final height = value <= 0
          ? 3.0
          : math.max(5.0, (value / maxValue) * (size.height - 4));
      final left = index * (width + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - height, width, height),
        radius,
      );
      canvas.drawRRect(
        rect,
        Paint()..color = value <= 0 ? track : color.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.color != color;
}

class _UsageBars extends StatelessWidget {
  const _UsageBars({required this.rows, this.showMain = false});
  final List<UsageAggregate> rows;
  final bool showMain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxCost = rows.map((row) => row.listCost).fold<double>(0, math.max);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            _UsageBarRow(
              row: rows[index],
              maxCost: maxCost,
              showMain: showMain,
            ),
          ],
        ],
      ),
    );
  }
}

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({
    required this.row,
    required this.maxCost,
    required this.showMain,
  });
  final UsageAggregate row;
  final double maxCost;
  final bool showMain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = maxCost <= 0
        ? 0.0
        : (row.listCost / maxCost).clamp(0.0, 1.0);
    final label = showMain
        ? projectName(row.main ?? row.key)
        : (row.label.contains(':') ? modelName(row.label) : row.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label.isEmpty ? 'Unknown' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            Text(
              formatMoney(row.listCost == 0 ? row.cost : row.listCost),
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${formatTokens(row.tokens)} tok',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 9.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 5,
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            color: theme.colorScheme.primary.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

class _BudgetRow extends StatelessWidget {
  const _BudgetRow({required this.budget});
  final JsonMap budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = asDouble(budget['amount']) ?? 0;
    final scope = asStringOr(budget['scope'], 'budget');
    final target = asString(budget['target']);
    final hard = asBool(budget['hard']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.savings_outlined,
            size: 17,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              [scope, if (target != null) projectName(target)].join(' · '),
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            formatMoney(amount),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          HarnessStatusPill(
            label: hard ? 'hard' : 'soft',
            color: hard ? theme.colorScheme.error : HarnessColors.amber,
          ),
        ],
      ),
    );
  }
}
