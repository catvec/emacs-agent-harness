import '../acp/acp_message.dart';
import 'project_roots.dart';

class UsageAggregate {
  const UsageAggregate({
    required this.key,
    this.main,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost = 0,
    this.listCost = 0,
    this.calls = 0,
  });

  factory UsageAggregate.fromWire(JsonMap wire) => UsageAggregate(
    key: asStringOr(wire['key'], ''),
    main: asString(wire['main']),
    input: asInt(wire['input']) ?? 0,
    output: asInt(wire['output']) ?? 0,
    cacheRead: asInt(wire['cacheRead'] ?? wire['cache-read']) ?? 0,
    cacheWrite: asInt(wire['cacheWrite'] ?? wire['cache-write']) ?? 0,
    cost: asDouble(wire['cost']) ?? 0,
    listCost: asDouble(wire['listCost'] ?? wire['list-cost']) ?? 0,
    calls: asInt(wire['calls']) ?? 0,
  );

  final String key;
  final String? main;
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final double cost;
  final double listCost;
  final int calls;

  int get tokens => input + output + cacheRead + cacheWrite;

  String get label {
    if (key.isEmpty) return 'Everything';
    final source = main ?? key;
    final parts = source.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? key : parts.last;
  }

  /// The project this row of usage by project is for: the main checkout the
  /// harness says (`main`), else the one [roots] makes of the row's key.
  /// Null for the row of usage that has no project.
  String? projectIn(ProjectRoots roots) {
    final said = main;
    return roots.of(said != null && said.isNotEmpty ? said : key);
  }
}

/// Usage rows by project with each project's worktrees added to it, richest
/// first, as the usage dashboard in Emacs shows them: a worktree is where
/// the work of a task ran, not a project of its own.  Each row is keyed by
/// the project (and says it is its `main`); the row of usage with no project
/// stays alone.
List<UsageAggregate> foldProjectUsage(
  Iterable<UsageAggregate> rows,
  ProjectRoots roots,
) {
  final groups = <String, List<UsageAggregate>>{};
  for (final row in rows) {
    groups.putIfAbsent(row.projectIn(roots) ?? '', () => []).add(row);
  }
  final folded = [
    for (final group in groups.entries)
      UsageAggregate(
        key: group.key,
        main: group.key.isEmpty ? null : group.key,
        input: group.value.fold(0, (sum, row) => sum + row.input),
        output: group.value.fold(0, (sum, row) => sum + row.output),
        cacheRead: group.value.fold(0, (sum, row) => sum + row.cacheRead),
        cacheWrite: group.value.fold(0, (sum, row) => sum + row.cacheWrite),
        cost: group.value.fold(0.0, (sum, row) => sum + row.cost),
        listCost: group.value.fold(0.0, (sum, row) => sum + row.listCost),
        calls: group.value.fold(0, (sum, row) => sum + row.calls),
      ),
  ];
  folded.sort((a, b) {
    final byList = b.listCost.compareTo(a.listCost);
    return byList != 0 ? byList : b.cost.compareTo(a.cost);
  });
  return folded;
}

class UsageOverview {
  const UsageOverview({
    this.totals = const UsageAggregate(key: ''),
    this.byModel = const [],
    this.byProject = const [],
    this.byDay = const [],
    this.live = const [],
    this.budgets = const [],
  });

  final UsageAggregate totals;
  final List<UsageAggregate> byModel;
  final List<UsageAggregate> byProject;
  final List<UsageAggregate> byDay;
  final List<LiveUsage> live;
  final List<JsonMap> budgets;
}

class LiveUsage {
  const LiveUsage({
    required this.sessionId,
    this.context = 0,
    this.output = 0,
    this.estimated = false,
  });

  factory LiveUsage.fromWire(JsonMap wire) => LiveUsage(
    sessionId: asStringOr(wire['session'], ''),
    context: asInt(wire['context']) ?? 0,
    output: asInt(wire['output']) ?? 0,
    estimated: asBool(wire['estimated']),
  );

  final String sessionId;
  final int context;
  final int output;
  final bool estimated;
}

class OutputRate {
  const OutputRate({
    required this.sessionId,
    this.rate = 0,
    this.output = 0,
    this.seconds = 0,
    this.calls = 0,
    this.model,
  });

  factory OutputRate.fromWire(JsonMap wire) => OutputRate(
    sessionId: asStringOr(wire['session'], ''),
    rate: asDouble(wire['rate']) ?? 0,
    output: asInt(wire['output']) ?? 0,
    seconds: asDouble(wire['seconds']) ?? 0,
    calls: asInt(wire['calls']) ?? 0,
    model: asString(wire['model']),
  );

  final String sessionId;
  final double rate;
  final int output;
  final double seconds;
  final int calls;
  final String? model;
}

String formatMoney(double value) {
  if (value == 0) return r'$0.00';
  if (value < 0.01) return '\$${value.toStringAsFixed(4)}';
  return '\$${_groupThousands(value.toStringAsFixed(2))}';
}

/// `1234.5` as `1,234.5`: the whole part in groups of three.
String _groupThousands(String fixed) {
  final dot = fixed.indexOf('.');
  final whole = dot < 0 ? fixed : fixed.substring(0, dot);
  final rest = dot < 0 ? '' : fixed.substring(dot);
  final grouped = whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (match) => ',',
  );
  return '$grouped$rest';
}

String formatTokens(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) {
    final thousands = value / 1000;
    return '${thousands.toStringAsFixed(thousands >= 100 ? 0 : 1)}k';
  }
  final millions = value / 1000000;
  return '${millions.toStringAsFixed(millions >= 100 ? 0 : 1)}M';
}

String formatDurationSeconds(num seconds) {
  if (seconds < 1) return '${(seconds * 1000).round()} ms';
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} s';
  }
  final minutes = seconds / 60;
  if (minutes < 60) {
    return '${minutes.toStringAsFixed(minutes >= 10 ? 0 : 1)} min';
  }
  final hours = minutes / 60;
  return '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)} h';
}
