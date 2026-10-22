import 'package:flutter/foundation.dart';

import '../acp/acp_message.dart';
import '../models/quota.dart';
import '../models/server_info.dart';
import '../services/harness_api.dart';

/// Each provider's billing and plan quota, kept as Emacs keeps it
/// (`harness-ui--quotas`): fetched from the providers that report one when
/// the app connects, and then followed through the harness's
/// `provider/quota-updated` events, so a plan's windows fill up on screen as
/// the work uses them.
class QuotaController extends ChangeNotifier {
  QuotaController(this.api);

  final HarnessApi api;
  final Map<String, ProviderQuota> _quotas = <String, ProviderQuota>{};
  final Map<String, String> _labels = <String, String>{};

  /// A fetch is under way.
  bool loading = false;
  int _fetches = 0;
  bool _disposed = false;

  /// When the quotas were last fetched (not when they last changed).
  DateTime? lastLoaded;

  /// The quota of every provider that told one, by provider id.
  List<ProviderQuota> get quotas => [
    for (final id in _quotas.keys.toList()..sort()) _quotas[id]!,
  ];

  /// What [provider] said about its billing and plan, or null.
  ProviderQuota? of(String? provider) =>
      provider == null ? null : _quotas[provider];

  /// The quota of the provider [model] ("claude:claude-fable-5-1") is from.
  ProviderQuota? forModel(String? model) => of(providerOfModel(model));

  /// The provider's name as people read it ("GitHub Copilot"), else its id
  /// made readable.
  String labelOf(String provider) =>
      _labels[provider] ??
      (provider.isEmpty
          ? provider
          : provider[0].toUpperCase() + provider.substring(1));

  /// Ask every provider that reports its quota for it.  [refresh] has each
  /// ask its source again first (a few seconds, no model call); otherwise
  /// they answer from what they last learned.  A provider that fails to
  /// answer keeps the quota it had: this is an enhancement, never an error.
  /// [showSpinner] announces that the fetch began, for a view that shows it.
  Future<void> load({bool refresh = false, bool showSpinner = false}) async {
    if (!api.capabilities.quota) return;
    _fetches++;
    loading = true;
    if (showSpinner) _notify();
    try {
      final List<ProviderInfo> providers;
      try {
        providers = await api.providers();
      } catch (_) {
        return;
      }
      for (final provider in providers) {
        _labels[provider.id] = provider.label;
      }
      final reporting = [
        for (final provider in providers)
          if (provider.reportsQuota) provider.id,
      ];
      final answers = await Future.wait([
        for (final id in reporting) _ask(id, refresh),
      ]);
      for (var index = 0; index < reporting.length; index++) {
        final answer = answers[index];
        if (answer != null) _store(reporting[index], answer.quota);
      }
      lastLoaded = DateTime.now();
    } finally {
      loading = --_fetches > 0;
      _notify();
    }
  }

  Future<_Answer?> _ask(String provider, bool refresh) async {
    try {
      return _Answer(await api.providerQuota(provider, refresh: refresh));
    } catch (_) {
      return null;
    }
  }

  /// Follow what the harness announces.
  void applyEvent(String event, List<Object?> args) {
    if (event != 'provider/quota-updated' || args.isEmpty) return;
    final provider = asString(args.first);
    if (provider == null || provider.isEmpty) return;
    final wire = args.length > 1 ? args[1] : null;
    final quota = wire is Map && wire.isNotEmpty
        ? ProviderQuota.fromWire(provider, asMap(wire))
        : null;
    if (_store(provider, quota)) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Keep [quota] as [provider]'s; whether that changed anything.
  bool _store(String provider, ProviderQuota? quota) {
    final old = _quotas[provider];
    if (quota == null) return _quotas.remove(provider) != null;
    if (quota.sameAs(old)) return false;
    _quotas[provider] = quota;
    return true;
  }
}

class _Answer {
  const _Answer(this.quota);
  final ProviderQuota? quota;
}
