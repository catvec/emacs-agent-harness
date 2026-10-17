import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_message.dart';
import '../models/usage.dart';
import '../services/harness_api.dart';

class UsageController extends ChangeNotifier {
  UsageController(this.api);

  final HarnessApi api;
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
      final totals = await api
          .usageTotals(project: project)
          .catchError((_) => const UsageAggregate(key: ''));
      final modelRows = api.can('usage/summary')
          ? await api
                .usageSummary(groupBy: 'model', project: project)
                .catchError((_) => const <UsageAggregate>[])
          : const <UsageAggregate>[];
      final projectRows = api.can('usage/summary')
          ? await api
                .usageSummary(groupBy: 'project', project: project)
                .catchError((_) => const <UsageAggregate>[])
          : const <UsageAggregate>[];
      final dayRows = api.can('usage/summary')
          ? await api
                .usageSummary(groupBy: 'day', project: project)
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
