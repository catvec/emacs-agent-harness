import 'package:collection/collection.dart';
import 'package:intl/intl.dart';

import '../acp/acp_message.dart';
import 'session.dart';
import 'usage.dart';

// What a provider says about how its calls are billed and, for a plan, how
// much of the plan is left: `_harness/provider/quota`, as Emacs reads it
// (`harness-ui-format-spend` and the plan section of the usage dashboard).
// Everything here is the same arithmetic and wording, so the app and Emacs
// say the same thing about the same plan.

/// Below this a plan covered nothing worth a word: a cost and the same cost
/// at list prices, added up in another order, differ by this much.
const _noise = 1e-9;

/// How full a quota window is, which is how it is coloured: the same steps
/// at 70%, 85% and 95% as Emacs's `harness-ui-quota-face`.
enum QuotaLevel { calm, warning, urgent, critical }

QuotaLevel quotaLevelOf(double used) {
  if (used >= 0.95) return QuotaLevel.critical;
  if (used >= 0.85) return QuotaLevel.urgent;
  if (used >= 0.70) return QuotaLevel.warning;
  return QuotaLevel.calm;
}

/// Round to the nearest whole number, halves to the even one, as Emacs's
/// `round` does, so a window reads the same percentage in both.
int roundHalfEven(double value) {
  final floor = value.floorToDouble();
  final fraction = value - floor;
  final base = floor.toInt();
  if (fraction < 0.5) return base;
  if (fraction > 0.5) return base + 1;
  return base.isEven ? base : base + 1;
}

/// One window of a plan's quota: the 5-hour session, the week, a model's
/// share of it, a month's premium requests.
class QuotaWindow {
  const QuotaWindow({
    required this.name,
    this.label,
    this.used = 0,
    this.resets,
    this.model,
    this.kind,
  });

  factory QuotaWindow.fromWire(JsonMap wire) {
    final label = _nonBlank(asString(wire['label']));
    return QuotaWindow(
      name: _nonBlank(asString(wire['name'])) ?? label ?? '',
      label: label,
      used: _atLeastZero(asDouble(wire['used']) ?? 0),
      resets: parseTime(wire['resets']),
      model: _nonBlank(asString(wire['model'])),
      kind: _nonBlank(asString(wire['kind'])),
    );
  }

  /// "5h", "7d", "7d Fable", "premium": short enough for a header.
  final String name;

  /// "Current session (5 hours)": what the window is, in words.
  final String? label;

  /// How much of the window is used, 0 to 1 (a provider may report more).
  final double used;

  /// When the window starts over.
  final DateTime? resets;
  final String? model;
  final String? kind;

  String get title => label ?? name;
  int get percent => roundHalfEven(used * 100);
  QuotaLevel get level => quotaLevelOf(used);

  /// The window in a header: "5h 9%".
  String get short => '$name $percent%';

  /// Whether the window is worth a glance in a header: the 5-hour and the
  /// weekly ones, and any other that is at least 70% used.
  bool get headline => name == '5h' || name == '7d' || used >= 0.7;

  /// A line about the window: what it is, how much is used, when it resets.
  String describe({DateTime? now}) {
    final reset = formatReset(resets, now: now);
    return '$title: $percent% used${reset == null ? '' : ', resets $reset'}';
  }
}

/// What a plan lets calls draw on beyond its windows, billed at API prices.
class QuotaExtra {
  const QuotaExtra({
    this.enabled = false,
    this.used,
    this.limit,
    this.currency,
    this.disabledReason,
  });

  factory QuotaExtra.fromWire(JsonMap wire) => QuotaExtra(
    enabled: asBool(wire['enabled']),
    used: asDouble(wire['used']),
    limit: asDouble(wire['limit']),
    currency: _nonBlank(asString(wire['currency'])),
    disabledReason: _nonBlank(
      asString(wire['disabled-reason'] ?? wire['disabledReason']),
    ),
  );

  final bool enabled;
  final double? used;
  final double? limit;
  final String? currency;
  final String? disabledReason;

  /// "Extra usage: off (out of credits), $0.00 used of $50.0".
  String describe() {
    final reason = disabledReason;
    final spent = used;
    final cap = limit;
    return 'Extra usage: ${enabled ? 'on' : 'off'}'
        '${reason != null && !enabled ? ' (${reason.replaceAll('_', ' ')})' : ''}'
        '${spent != null ? ', ${formatMoney(spent)} used' : ''}'
        '${cap != null ? ' of ${formatMoney(cap)}' : ''}';
  }
}

/// A provider's billing and plan quota, as `provider/quota` returns it.
class ProviderQuota {
  const ProviderQuota({
    required this.provider,
    this.billing,
    this.plan,
    this.planLabel,
    this.quotaNote,
    this.informational = false,
    this.auth,
    this.email,
    this.organization,
    this.windows = const [],
    this.extra,
    this.updated,
    this.limitStatus,
    this.usingExtra = false,
    this.raw = const {},
  });

  factory ProviderQuota.fromWire(String provider, JsonMap wire) {
    final account = asMap(wire['account']);
    final extra = asMap(wire['extra']);
    return ProviderQuota(
      provider: provider,
      billing: _nonBlank(asString(wire['billing'])),
      plan: _nonBlank(asString(wire['plan'])),
      planLabel: _nonBlank(asString(wire['plan-label'] ?? wire['planLabel'])),
      quotaNote: _nonBlank(asString(wire['quota-note'] ?? wire['quotaNote'])),
      informational: asBool(wire['informational']),
      auth: _nonBlank(asString(wire['auth'])),
      email: _nonBlank(asString(account['email'])),
      organization: _nonBlank(asString(account['organization'])),
      windows: [
        for (final window in asMapList(wire['windows']))
          QuotaWindow.fromWire(window),
      ],
      extra: extra.isEmpty ? null : QuotaExtra.fromWire(extra),
      updated: parseTime(wire['updated']),
      limitStatus: _nonBlank(
        asString(wire['limit-status'] ?? wire['limitStatus']),
      ),
      usingExtra: asBool(wire['using-extra'] ?? wire['usingExtra']),
      raw: wire,
    );
  }

  /// The provider's id, "claude".
  final String provider;

  /// "api", "subscription" or "extra-usage"; null when the provider has not
  /// said, which reads as billing per token.
  final String? billing;

  /// "max": the plan's id, and "Claude Max" its name.
  final String? plan;
  final String? planLabel;

  /// Why numerical windows are unavailable, or why they are informational
  /// rather than the app's own limits (as for a separate Codex CLI login).
  final String? quotaNote;
  final bool informational;

  /// Where the credentials come from: "claude.ai", "ANTHROPIC_API_KEY".
  final String? auth;
  final String? email;
  final String? organization;
  final List<QuotaWindow> windows;
  final QuotaExtra? extra;
  final DateTime? updated;

  /// "rejected" once the plan's limit is reached, "allowed_warning" close
  /// to it.
  final String? limitStatus;

  /// Calls draw on extra usage, billed at API prices.
  final bool usingExtra;
  final JsonMap raw;

  /// A subscription pays (possibly with extra usage on top).
  bool get isPlan => billing == 'subscription' || billing == 'extra-usage';
  bool get billsPerToken => billing == 'api';

  /// "Max": the plan's short name, null when it has none.
  String? get planName => planNameOf(plan);

  /// The windows worth a glance in a header (see [QuotaWindow.headline]).
  List<QuotaWindow> get headlineWindows => [
    for (final window in windows)
      if (window.headline) window,
  ];

  /// The same quota, as nothing has changed it.
  bool sameAs(ProviderQuota? other) =>
      other != null &&
      provider == other.provider &&
      const DeepCollectionEquality().equals(raw, other.raw);
}

String? _nonBlank(String? value) =>
    value == null || value.trim().isEmpty ? null : value.trim();

double _atLeastZero(double value) => value < 0 ? 0 : value;

/// "max" gives "Max", "claude_max" "Claude Max": the plan's name, or null
/// for none.
String? planNameOf(String? plan) {
  final id = _nonBlank(plan);
  if (id == null) return null;
  return id
      .replaceAll('_', ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
      .join(' ');
}

/// The plan's full name: its label ("Claude Max") when it is the plan of
/// [quota], else "the Max plan", else "the subscription".
String planTitleOf(ProviderQuota? quota, [String? plan]) {
  final given = _nonBlank(plan);
  if (quota?.planLabel != null && (given == null || given == quota?.plan)) {
    return quota!.planLabel!;
  }
  final name = planNameOf(given ?? quota?.plan);
  return name == null ? 'the subscription' : 'the $name plan';
}

/// The id of the provider a model belongs to: "claude" for
/// "claude:claude-fable-5-1"; null for a model without one.
String? providerOfModel(String? model) {
  if (model == null) return null;
  final colon = model.indexOf(':');
  return colon <= 0 ? null : model.substring(0, colon);
}

/// A span of time as compactly as Emacs's `harness-format-duration`:
/// "42.0s", "59m59s", "3h12m".
String formatCountdown(Duration span) {
  final seconds = span.inMicroseconds / Duration.microsecondsPerSecond;
  if (seconds < 1) return '${(seconds * 1000).truncate()}ms';
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  if (seconds < 3600) {
    final minutes = (seconds / 60).truncate();
    final rest = (seconds % 60).truncate();
    return '${minutes}m${rest.toString().padLeft(2, '0')}s';
  }
  final hours = (seconds / 3600).truncate();
  final minutes = ((seconds % 3600) / 60).truncate();
  return '${hours}h${minutes.toString().padLeft(2, '0')}m';
}

/// When a quota window resets: "in 3h12m (14:30)" within a day, "now" once
/// it has, else a date ("Tue Oct 28, 14:30").  Null when it says nothing.
String? formatReset(DateTime? time, {DateTime? now}) {
  if (time == null) return null;
  final left = time.difference(now ?? DateTime.now());
  if (left <= Duration.zero) return 'now';
  if (left < const Duration(days: 1)) {
    return 'in ${formatCountdown(left)} (${DateFormat('HH:mm').format(time)})';
  }
  return DateFormat('EEE MMM d, HH:mm').format(time);
}

/// How a usage record was paid: "api", "subscription" or "extra-usage".
/// Null when the provider did not say, which reads as per-token billing.
String? billingOf(Usage? usage) {
  final billing = usage?.billing;
  return billing == null || billing.isEmpty ? null : billing;
}

/// Several sessions taken together as one record of usage, for
/// [SpendStatus.of]: the usage adds up, and the billing and plan are those
/// of the session updated last that recorded a billing, as a session's are
/// those of its last call.
Usage combineUsage(Iterable<SessionSummary> sessions) {
  var input = 0, output = 0, cacheRead = 0, cacheWrite = 0;
  var cost = 0.0, listCost = 0.0;
  SessionSummary? latest;
  for (final session in sessions) {
    final usage = session.usage;
    if (usage == null) continue;
    input += usage.input;
    output += usage.output;
    cacheRead += usage.cacheRead;
    cacheWrite += usage.cacheWrite;
    cost += usage.cost;
    listCost += usage.listCost > usage.cost ? usage.listCost : usage.cost;
    if (billingOf(usage) != null) {
      final newer =
          latest == null ||
          (session.updatedAt?.millisecondsSinceEpoch ?? 0) >
              (latest.updatedAt?.millisecondsSinceEpoch ?? 0);
      if (newer) latest = session;
    }
  }
  return Usage(
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite,
    cost: cost,
    listCost: listCost,
    billing: latest?.usage?.billing,
    plan: latest?.usage?.plan,
  );
}

/// What a session (or several, [combineUsage]) cost and who pays for it:
/// the price when calls are billed per token, the plan's name when a
/// subscription pays, with the plan's headline quota windows beside it.
/// Emacs's `harness-ui-format-spend` and `harness-ui-spend-help`.
class SpendStatus {
  const SpendStatus({
    required this.text,
    required this.planned,
    required this.cost,
    required this.covered,
    this.billing,
    this.windows = const [],
    this.details = const [],
    this.quota,
  });

  /// [usage] is what was spent; [quota] the account of the provider that
  /// spent it, whose billing and plan quota apply.  [subject] names what
  /// cost it in the explanation ("This session", "These tasks").
  factory SpendStatus.of({
    Usage? usage,
    ProviderQuota? quota,
    String subject = 'This session',
    DateTime? now,
  }) {
    final cost = usage?.cost ?? 0;
    final list = usage == null
        ? 0.0
        : (usage.listCost > usage.cost ? usage.listCost : usage.cost);
    final covered = list - cost > _noise ? list - cost : 0.0;
    // Its last recorded call decides how a session is paid.  Before it made
    // any call, its provider's account does; calls recorded without a
    // billing stay as recorded.
    final fresh =
        usage == null ||
        (usage.input == 0 && usage.output == 0 && usage.cost == 0);
    final billing = billingOf(usage) ?? (fresh ? quota?.billing : null);
    final onPlan = billing == 'subscription' || billing == 'extra-usage';
    final planned = covered > 0 || onPlan;
    final name = planNameOf(_nonBlank(usage?.plan) ?? quota?.plan) ?? 'Plan';
    final text = !planned
        ? formatMoney(cost)
        : (cost > 0 ? '${formatMoney(cost)}+$name' : name);
    final payer = planTitleOf(quota, usage?.plan);
    final lines = <String>[
      if (covered > 0 && cost > 0)
        '${formatMoney(cost)} billed'
            '${billing == 'extra-usage' ? ' as extra usage' : ''}; '
            '${formatMoney(covered)} more at API prices covered by $payer.'
      else if (covered > 0 || onPlan)
        'Covered by $payer, not billed per token. '
            '$subject at API prices: ${formatMoney(covered)}.'
      else if (billing == 'api')
        '$subject cost ${formatMoney(cost)}, billed per token'
            '${quota?.auth != null ? ' (${quota!.auth})' : ''}.'
      else
        '$subject cost ${formatMoney(cost)}.',
      if (onPlan && quota != null) ...[
        for (final window in quota.windows) window.describe(now: now),
        if (quota.quotaNote != null) quota.quotaNote!,
        if (quota.extra != null) quota.extra!.describe(),
      ],
    ];
    return SpendStatus(
      text: text,
      planned: planned,
      cost: cost,
      covered: covered,
      billing: billing,
      windows: planned ? (quota?.headlineWindows ?? const []) : const [],
      details: lines,
      quota: quota,
    );
  }

  /// "$1.20" billed per token, "Max" when a plan pays, "$0.40+Max" when
  /// some of it was billed as extra usage.
  final String text;

  /// A subscription paid for some or all of it.
  final bool planned;
  final double cost;

  /// What the plan covered, at API prices.
  final double covered;
  final String? billing;

  /// The plan's windows worth a glance, when a plan pays.
  final List<QuotaWindow> windows;

  /// The explanation: who pays, what it came to, every window and the
  /// plan's extra usage.
  final List<String> details;
  final ProviderQuota? quota;

  /// Something to show: a cost, or a plan that pays.  A session that cost
  /// nothing on a provider that bills per token has nothing to say.
  bool get worthShowing => planned || cost > 0;

  /// The explanation on one line, as a tooltip reads.
  String get help => details.join(' ');

  /// The status as a header reads it: "Max · 5h 23% · 7d 41%".
  String get line =>
      [text, for (final window in windows) window.short].join(' · ');
}
