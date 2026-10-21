import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/project_roots.dart';
import '../models/usage.dart';
import '../services/harness_api.dart';

class UsageController extends ChangeNotifier {
  /// [roots] says how directories fold into projects, as the app knows it
  /// now; it is asked at every load.
  UsageController(this.api, {ProjectRoots Function()? roots})
    : _roots = roots ?? (() => const ProjectRoots.empty());

  final HarnessApi api;
  final ProjectRoots Function() _roots;
  UsageOverview overview = const UsageOverview();
  String? project;
  String? error;
  bool loading = false;
  DateTime? lastLoaded;
  bool liveLoading = false;

  Future<void> load({String? project, bool showSpinner = true}) async {
    if (!api.capabilities.usage) return;
    this.project = project;
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      final roots = _roots();
      final summaries = api.can('usage/summary');
      // Spend is recorded under the directory a session worked in, and a
      // task works in a worktree of its project.  So the rows by project
      // come first: they say which directories, the project's own and its
      // worktrees, the figures of the project asked for are made of.
      final everyProject = summaries
          ? await api
                .usageSummary(groupBy: 'project')
                .catchError((_) => const <UsageAggregate>[])
          : const <UsageAggregate>[];
      final scope = project == null ? null : projectDirectory(project);
      final members = scope == null
          ? everyProject
          : [
              for (final row in everyProject)
                if (row.projectIn(roots) == scope) row,
            ];
      final directories = [
        for (final row in members)
          if (row.key.isNotEmpty) row.key,
      ];
      // Without rows by project there is nothing to widen the project with:
      // it is asked for as it is named.
      final only = scope != null && directories.isEmpty ? project : null;
      final within = scope != null && directories.isNotEmpty
          ? directories
          : null;
      final totals = await api
          .usageTotals(project: only, projects: within)
          .catchError((_) => const UsageAggregate(key: ''));
      final modelRows = summaries
          ? await api
                .usageSummary(groupBy: 'model', project: only, projects: within)
                .catchError((_) => const <UsageAggregate>[])
          : const <UsageAggregate>[];
      final projectRows = foldProjectUsage(members, roots);
      final dayRows = summaries
          ? await api
                .usageSummary(groupBy: 'day', project: only, projects: within)
                .catchError((_) => const <UsageAggregate>[])
          : const <UsageAggregate>[];
      final live = api.capabilities.liveUsage
          ? await api.usageLive().catchError((_) => const <LiveUsage>[])
          : const <LiveUsage>[];
      final budgets = api.can('usage/budgets')
          ? await api.budgets().catchError((_) => const <JsonMap>[])
          : const <JsonMap>[];
      overview = UsageOverview(
        totals: totals,
        byModel: modelRows,
        byProject: projectRows,
        byDay: dayRows,
        live: live,
        budgets: budgets,
      );
      lastLoaded = DateTime.now();
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshLive() async {
    if (!api.capabilities.liveUsage || liveLoading) return;
    liveLoading = true;
    try {
      final live = await api.usageLive();
      overview = UsageOverview(
        totals: overview.totals,
        byModel: overview.byModel,
        byProject: overview.byProject,
        byDay: overview.byDay,
        live: live,
        budgets: overview.budgets,
      );
      notifyListeners();
    } catch (_) {
      // Live figures are an enhancement.
    } finally {
      liveLoading = false;
    }
  }

  void applyEvent(String event, List<Object?> args) {
    if (event == 'usage/live-updated') {
      refreshLive();
    } else if (event == 'usage/budgets-changed' ||
        event == 'usage/budget-warning' ||
        event == 'usage/rates-updated') {
      load(project: project, showSpinner: false);
    }
  }
}
