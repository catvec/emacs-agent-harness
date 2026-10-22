import 'package:flutter/material.dart';

import '../../models/quota.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';

// How the app shows a plan's quota: in the status of a session and of the
// task board, where Emacs's header line reads "Max · 5h 23% · 7d 41%", and
// as the plan section of the usage view, where Emacs's dashboard draws a
// meter for each window.

const _urgent = Color(0xFFE8590C);

/// The colour of a quota window that is [level] full: quiet below 70%, then
/// amber, orange from 85% and red from 95%, as Emacs colours it.
Color quotaColor(ThemeData theme, QuotaLevel level) => switch (level) {
  QuotaLevel.calm => theme.colorScheme.onSurfaceVariant,
  QuotaLevel.warning => HarnessColors.amber,
  QuotaLevel.urgent => _urgent,
  QuotaLevel.critical => theme.colorScheme.error,
};

/// The accent that marks a plan wherever one pays: its name in a chip, in a
/// list row, on a card.
Color planAccent(ThemeData theme) => theme.brightness == Brightness.dark
    ? HarnessColors.oxideDark
    : HarnessColors.oxide;

/// "12m ago": when [time] was, for a line that says how fresh a figure is.
String agoText(DateTime time, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(time);
  if (age.inSeconds < 45) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ago';
  return relativeTime(time);
}

/// What a session or the tasks of a board cost and who pays: "$1.20" when
/// billed per token, "Max · 5h 23% · 7d 41%" when a plan does, its windows
/// coloured by how full they are.  A tap says more ([showPlanSheet]).
class SpendChip extends StatelessWidget {
  const SpendChip({
    super.key,
    required this.status,
    this.dense = true,
    this.onTap,
  });

  final SpendStatus status;

  /// The size of the chips of a session's header; else that of the pills of
  /// the task board's.
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = status.planned
        ? planAccent(theme)
        : theme.colorScheme.onSurfaceVariant;
    final quiet = theme.colorScheme.onSurfaceVariant;
    final size = dense ? 10.5 : 13.0;
    final chip = Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 9, vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: status.planned ? 0.09 : 0.07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: (status.planned ? tint : theme.colorScheme.outlineVariant)
              .withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status.planned ? Icons.data_usage_rounded : Icons.payments_outlined,
            size: dense ? 12 : 15,
            color: tint,
          ),
          SizedBox(width: dense ? 5 : 6),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: status.text,
                    style: TextStyle(fontWeight: FontWeight.w700, color: tint),
                  ),
                  for (final window in status.windows) ...[
                    TextSpan(
                      text: ' · ',
                      style: TextStyle(color: quiet),
                    ),
                    TextSpan(
                      text: window.short,
                      style: TextStyle(
                        color: quotaColor(theme, window.level),
                        fontWeight: window.level.index >= 2
                            ? FontWeight.w800
                            : FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: size, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      label: '${status.planned ? 'Plan' : 'Cost'}: ${status.line}',
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: status.help,
        waitDuration: const Duration(milliseconds: 400),
        child: onTap == null
            ? chip
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: chip,
              ),
      ),
    );
  }
}

/// A meter for one window of a plan's quota: what it is, how much is used,
/// and when it starts over.
class QuotaMeter extends StatelessWidget {
  const QuotaMeter({super.key, required this.window, this.now});

  final QuotaWindow window;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = window.used;
    // The bar warns later than the figure does: amber from 80%, red from 95%.
    final color = used >= 0.95
        ? theme.colorScheme.error
        : used >= 0.8
        ? HarnessColors.amber
        : theme.colorScheme.primary;
    final reset = formatReset(window.resets, now: now);
    return Semantics(
      label: window.describe(now: now),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${window.percent}%',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: used >= 0.8
                        ? quotaColor(theme, window.level)
                        : theme.colorScheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: used.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHigh,
                color: color,
              ),
            ),
            if (reset != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Resets $reset',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A plan's quota in full: the warnings its provider gives, a meter for each
/// window, the extra usage and how fresh it all is.
class PlanDetails extends StatelessWidget {
  const PlanDetails({super.key, required this.quota, this.now});

  final ProviderQuota quota;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 11,
    );
    final updated = quota.updated;
    final extra = quota.extra;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (quota.limitStatus == 'rejected')
          _Notice(
            "The plan's limit is reached: calls fail until it resets.",
            theme.colorScheme.error,
            Icons.block_rounded,
          )
        else if (quota.limitStatus == 'allowed_warning')
          const _Notice(
            "Close to the plan's limit.",
            HarnessColors.amber,
            Icons.warning_amber_rounded,
          ),
        if (quota.usingExtra)
          const _Notice(
            'Calls are drawing on extra usage, billed at API prices.',
            HarnessColors.amber,
            Icons.add_card_rounded,
          ),
        if (quota.windows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('No quota reported yet.', style: quiet),
          )
        else
          for (final window in quota.windows)
            QuotaMeter(window: window, now: now),
        if (extra != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(extra.describe(), style: quiet),
          ),
        if (updated != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Updated ${agoText(updated, now: now)}', style: quiet),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, this.color, this.icon);

  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How one provider bills and, when a subscription pays, its plan's quota:
/// the plan section of the usage view.
class PlanCard extends StatelessWidget {
  const PlanCard({
    super.key,
    required this.label,
    required this.quota,
    this.now,
  });

  /// The provider's name, "Claude".
  final String label;
  final ProviderQuota quota;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 12,
    );
    final accent = planAccent(theme);
    final Widget body;
    if (quota.isPlan) {
      final account = [
        if (quota.email != null) quota.email!,
        if (quota.organization != null) quota.organization!,
      ].join(' · ');
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HarnessStatusPill(
                label: quota.planLabel ?? quota.planName ?? 'Subscription',
                color: accent,
                icon: Icons.data_usage_rounded,
              ),
            ],
          ),
          if (account.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(account, style: quiet),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              'Calls the plan covers are not billed; their value at API '
              'prices shows as covered by the plan.',
              style: quiet,
            ),
          ),
          PlanDetails(quota: quota, now: now),
        ],
      );
    } else if (quota.billsPerToken) {
      body = Row(
        children: [
          Icon(
            Icons.payments_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        ' bills per token'
                        '${quota.auth == null ? '' : ' (${quota.auth})'}: '
                        'what it cost is what you pay.',
                  ),
                ],
              ),
              style: quiet,
            ),
          ),
        ],
      );
    } else {
      body = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: ' has not said how it bills yet.'),
          ],
        ),
        style: quiet,
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: body,
    );
  }
}

/// The details behind a [SpendChip]: who pays for what was spent and, for a
/// plan, how much of it is left.  What a tooltip says in Emacs.
Future<void> showPlanSheet(
  BuildContext context, {
  required SpendStatus status,
  String? providerLabel,
  DateTime? now,
}) => showHarnessSheet<void>(
  context: context,
  builder: (sheetContext) =>
      _PlanSheet(status: status, providerLabel: providerLabel, now: now),
);

class _PlanSheet extends StatelessWidget {
  const _PlanSheet({required this.status, this.providerLabel, this.now});

  final SpendStatus status;
  final String? providerLabel;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quota = status.quota;
    final title = status.planned
        ? planTitleOf(quota)
        : (status.billing == 'api' ? 'Billed per token' : 'Cost');
    return SingleChildScrollView(
      key: const Key('plan-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                status.planned
                    ? Icons.data_usage_rounded
                    : Icons.payments_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title[0].toUpperCase() + title.substring(1),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (providerLabel != null)
                Text(
                  providerLabel!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            status.details.first,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
          ),
          if (status.planned && quota != null) ...[
            const SizedBox(height: 12),
            PlanDetails(quota: quota, now: now),
          ],
        ],
      ),
    );
  }
}
