import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../models/resources.dart';
import '../services/harness_api.dart';

/// The Resources page's state: one metadata-only answer, and the few
/// operations that change a resource.
///
/// A failed operation never changes [resources] to a success: the answer the
/// harness gave is shown, and when it is `unavailable` the screen says so.
class ResourcesController extends ChangeNotifier {
  ResourcesController(
    this._api, {
    required this.workspaceId,
    this.preview = false,
  });

  /// A controller with sample metadata and no harness behind it, for the
  /// pictures and the widget tests.  Its destructive actions are disabled:
  /// a preview never reports a change.
  ResourcesController.preview({this.workspaceId = 'w1'})
    : _api = null,
      preview = true {
    resources = WorkspaceResources.preview();
  }

  final HarnessApi? _api;
  final String workspaceId;
  final bool preview;

  WorkspaceResources? resources;
  String? error;
  String? notice;
  bool loading = false;
  bool busy = false;

  /// A resource's actions depend on its own section being there, not on the
  /// page's status: credentials may be ready while the box is staged.
  bool get canManageBrowser => !preview && (resources?.browser != null);
  bool get canManageWallet => !preview && (resources?.wallet != null);
  bool get canManage => canManageBrowser || canManageWallet;

  bool get canReveal => false; // No reveal in this slice, by design.

  Future<void> load({bool showSpinner = true}) async {
    if (preview) {
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null || !api.can('workspace/resources/status')) {
      resources = WorkspaceResources.unavailable(workspaceId, 'box-staged');
      error = null;
      notifyListeners();
      return;
    }
    if (showSpinner) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      resources = await api.workspaceResources(workspaceId);
    } on AcpException catch (failure) {
      if (failure.isMethodNotFound) {
        resources = WorkspaceResources.unavailable(workspaceId, 'box-staged');
      } else {
        error = failure.message;
      }
    } catch (failure) {
      error = '$failure';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() => load(showSpinner: false);

  Future<void> clearSite(String origin, List<String> kinds) =>
      _clear(scope: 'site', origin: origin, kinds: kinds);

  Future<void> clearProfile() => _clear(
    scope: 'profile',
    kinds: const ['cookies', 'storage', 'cache', 'permissions'],
  );

  Future<void> _clear({
    required String scope,
    String? origin,
    required List<String> kinds,
  }) async {
    final api = _api;
    if (!canManageBrowser || api == null) return;
    if (!api.can('workspace/browser/clear')) {
      error = 'Browser tools';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      resources = await api.clearWorkspaceBrowser(
        workspaceId,
        scope: scope,
        origin: origin,
        kinds: kinds,
      );
      notice = resources!.ready ? 'Cleared' : null;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> forgetLogin(String login) async {
    final api = _api;
    if (!canManageBrowser || api == null) return;
    if (!api.can('workspace/browser/login/forget')) {
      error = 'Browser tools';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      resources = await api.forgetWorkspaceLogin(workspaceId, login);
      notice = resources!.ready ? 'Login forgotten' : null;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Create a bounded authorization.  Invalid input is refused here, before
  /// a request: a zero amount, a missing merchant or an unknown currency is a
  /// form error, not a harness error.
  Future<String?> createAuthorization({
    required String card,
    required int amount,
    required String merchant,
    required String capKind,
    required String expiry,
    required String fees,
  }) async {
    final api = _api;
    if (!canManageWallet || api == null) return 'Unavailable';
    if (amount <= 0) return 'Amount';
    if (card.isEmpty) return 'Card';
    if (merchant.trim().isEmpty) return 'Merchant';
    if (!api.can('workspace/wallet/authorization/create')) return 'Wallet provider';
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      resources = await api.createWorkspaceAuthorization(
        workspaceId,
        card: card,
        amount: amount,
        currency: 'USD',
        capKind: capKind,
        merchants: [merchant.trim()],
        expires: expiry,
        fees: fees,
      );
      if (resources!.ready) {
        notice = 'Authorization created';
        return null;
      }
      return resources!.reasonLabel;
    } on AcpException catch (failure) {
      error = failure.message;
      return failure.message;
    } catch (failure) {
      error = '$failure';
      return '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> revokeAuthorization(String id) async {
    final api = _api;
    if (!canManageWallet || api == null) return;
    if (!api.can('workspace/wallet/authorization/revoke')) {
      error = 'Wallet provider';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      resources = await api.revokeWorkspaceAuthorization(workspaceId, id);
      notice = resources!.ready ? 'Authorization revoked' : null;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> decidePurchase(String id, {required bool allow}) async {
    final api = _api;
    if (!canManageWallet || api == null) return;
    if (!api.can('workspace/wallet/purchase/decide')) {
      error = 'Payment broker';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      resources = await api.decideWorkspacePurchase(workspaceId, id, allow: allow);
      notice = resources!.ready ? (allow ? 'Allowed' : 'Denied') : null;
    } on AcpException catch (failure) {
      error = failure.message;
    } catch (failure) {
      error = '$failure';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void clearNotice() {
    if (notice == null && error == null) return;
    notice = null;
    error = null;
    notifyListeners();
  }

}
