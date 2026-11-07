import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/resources.dart';
import '../../models/workspace.dart';
import '../../state/app_controller.dart';
import '../../state/resources_controller.dart';
import '../adaptive/adaptive_widgets.dart';
import '../format.dart';
import '../theme/harness_theme.dart';
import '../widgets/dither.dart';

/// The workspace's first-class resources: its browser, its wallet and the
/// access the agent has to either.
///
/// A resource is shown with its owner, scope, state, availability and the
/// access it grants.  Nothing on this page is a secret: no cookie value, no
/// password, no card number and no token has a field to arrive in.  A box
/// that is not running and a wallet provider that does not exist are said,
/// not simulated.
class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({
    super.key,
    required this.app,
    required this.workspace,
    this.controller,
  });

  final AppController app;
  final WorkspaceSummary workspace;

  /// A controller for the widget tests and the screenshot cases; the desk
  /// passes none and the screen builds one from the harness.
  final ResourcesController? controller;

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  late ResourcesController _controller;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        ResourcesController(
          widget.app.harness,
          workspaceId: widget.workspace.id,
        );
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.load(showSpinner: false);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _subtitle(WorkspaceResources? resources) {
    final parts = [
      widget.workspace.name,
      _controller.preview
          ? 'Preview'
          : resources?.statusLabel ?? 'Loading',
      if (resources?.reasonLabel != null) resources!.reasonLabel,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final resources = _controller.resources;
    return HarnessPage(
      title: 'Resources',
      subtitle: Text(_subtitle(resources)),
      actions: [
        HarnessIconButton(
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: () => unawaited(_controller.reload()),
        ),
      ],
      body: resources == null && _controller.loading
          ? const Center(child: HarnessActivity(radius: 10))
          : Align(
              alignment: AlignmentDirectional.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    HarnessSpace.gutter,
                    HarnessSpace.lg,
                    HarnessSpace.gutter,
                    HarnessSpace.xl,
                  ),
                  children: [
                    _statusCard(resources),
                    if (_controller.error != null) ...[
                      const SizedBox(height: HarnessSpace.md),
                      _banner(
                        text: _controller.error!,
                        action: 'Retry',
                        onAction: () => unawaited(_controller.reload()),
                        error: true,
                      ),
                    ],
                    if (_controller.notice != null) ...[
                      const SizedBox(height: HarnessSpace.md),
                      _banner(
                        text: _controller.notice!,
                        action: 'Dismiss',
                        onAction: _controller.clearNotice,
                      ),
                    ],
                    const SizedBox(height: HarnessSpace.lg),
                    _tabs(),
                    const SizedBox(height: HarnessSpace.lg),
                    if (resources == null)
                      _empty(
                        'Resources unavailable',
                        'No answer from the harness',
                      )
                    else ...[
                      if (_tab == 0) ..._browser(resources),
                      if (_tab == 1) ..._wallet(resources),
                      if (_tab == 2) ..._credentials(resources),
                      if (_tab == 3) ..._access(resources),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _statusCard(WorkspaceResources? resources) {
    final status = _controller.preview
        ? 'Preview · no changes'
        : resources?.statusLabel ?? 'Loading';
    final color = switch (_controller.preview ? 'preview' : resources?.status) {
      'preview' => HarnessColors.amber,
      'ready' => HarnessColors.moss,
      'needs-approval' => HarnessColors.amber,
      'failed' => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.outline,
    };
    return DitherPanel(
      padding: const EdgeInsets.all(HarnessSpace.lg),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.workspace.name,
            style: HarnessText.rowTitle(context).copyWith(fontSize: 17),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _chip(status, color),
              if (resources?.reasonLabel != null) _chip(resources!.reasonLabel!, null),
              if (resources?.ready ?? false) _chip('Metadata only', null),
              if (resources?.credentialsReady ?? false) _chip('Credentials', HarnessColors.moss),
              if (resources == null && _controller.loading) _chip('Loading', null),
            ],
          ),
          if (resources?.browser case final browser?) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _metric('Sites', '${browser.profile.sites}')),
                const SizedBox(width: 8),
                Expanded(child: _metric('Cookies', '${browser.cookies}')),
                const SizedBox(width: 8),
                Expanded(child: _metric('Storage', formatBytes(browser.bytes))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: HarnessText.rowTitle(context)),
          const SizedBox(height: 1),
          Text(label, style: HarnessText.meta(context)),
        ],
      ),
    );
  }

  Widget _tabs() {
    const labels = ['Browser', 'Wallet', 'Credentials', 'Access'];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++)
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(2),
                  onTap: () => setState(() => _tab = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: _tab == index
                          ? Theme.of(context).colorScheme.surface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: _tab == index
                          ? [
                              BoxShadow(
                                color: HarnessColors.ink.withValues(alpha: 0.06),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      labels[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _tab == index
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _browser(WorkspaceResources resources) {
    final browser = resources.browser;
    if (browser == null) {
      return [
        _empty('No browser data', 'Box staged'),
      ];
    }
    return [
      _section('Browsers'),
      _browserChoices(browser),
      const SizedBox(height: HarnessSpace.md),
      _section('Profile'),
      _profileCard(browser),
      const SizedBox(height: HarnessSpace.lg),
      _section('Sites'),
      if (browser.sites.isEmpty)
        _empty('No sites', 'Browser profile')
      else
        _siteGrid(browser.sites),
      const SizedBox(height: HarnessSpace.lg),
      _section('Saved logins'),
      if (browser.logins.isEmpty)
        _empty('No logins', 'Browser profile')
      else
        for (final login in browser.logins) _loginCard(login),
      const SizedBox(height: HarnessSpace.lg),
      _section('Transfer'),
      _disabledRow('Export…', 'Needs box · approval', Icons.upload_file_outlined),
      _disabledRow('Import…', 'Needs box · approval', Icons.download_outlined),
    ];
  }

  Widget _browserChoices(BrowserData browser) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final type in browser.browsers)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: type.primary
                  ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.45)
                  : Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(
                color: type.primary
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  type.id == 'firefox'
                      ? Icons.local_fire_department_outlined
                      : Icons.public_rounded,
                  size: 15,
                  color: type.available
                      ? (type.primary
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant)
                      : Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    type.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.meta(context).copyWith(
                      fontWeight: type.primary ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    type.supportLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HarnessText.meta(context).copyWith(
                      color: type.primary
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _profileCard(BrowserData browser) {
    final profile = browser.profile;
    final details = Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Icon(
            Icons.web_rounded,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Profile · ${profile.label}',
                style: HarnessText.rowTitle(context),
              ),
              const SizedBox(height: 3),
              Text(
                '${profile.kind} · last used ${_ago(profile.lastUsed)}',
                style: HarnessText.caption(context),
              ),
            ],
          ),
        ),
      ],
    );
    final action = _action(
      'Clear all…',
      enabled: _controller.canManageBrowser,
      reason: _controller.preview ? 'Preview' : 'Box staged',
      onPressed: _confirmClearProfile,
    );
    return Container(
      padding: const EdgeInsets.all(HarnessSpace.lg),
      decoration: _cardDecoration(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.6;
          if (!stacked) {
            return Row(children: [Expanded(child: details), action]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              details,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: action,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _siteGrid(List<BrowserSite> sites) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= 640;
        final width = two ? (constraints.maxWidth - 10) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final site in sites)
              SizedBox(width: width, child: _siteCard(site)),
          ],
        );
      },
    );
  }

  Widget _siteCard(BrowserSite site) {
    final color = switch (site.auth) {
      'signed-in' => HarnessColors.moss,
      'signed-out' => Theme.of(context).colorScheme.outline,
      _ => HarnessColors.amber,
    };
    final initial = site.host.isEmpty ? '?' : site.host.substring(0, 1).toUpperCase();
    return Semantics(
      button: true,
      label: 'Site ${site.host}, ${site.dataLabel}, ${site.authLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(2),
          onTap: () => _showSite(site),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: _cardDecoration(),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    initial,
                    style: HarnessText.rowTitle(context).copyWith(color: color),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.rowTitle(context),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${site.cookies} cookies · ${formatBytes(site.storageBytes + site.cacheBytes)}',
                        style: HarnessText.caption(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _chip(site.authLabel, color),
                    const SizedBox(height: 6),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _loginCard(BrowserLogin login) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Icon(
              Icons.key_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(login.host, style: HarnessText.rowTitle(context)),
                const SizedBox(height: 2),
                Text(
                  '${login.username} · ${login.stateLabel} · ${_ago(login.lastUsed)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.caption(context),
                ),
              ],
            ),
          ),
          _action(
            'Forget',
            enabled: _controller.canManageBrowser,
            reason: _controller.preview ? 'Preview' : 'Box staged',
            onPressed: () => _confirmForget(login),
          ),
        ],
      ),
    );
  }

  Widget _disabledRow(String label, String reason, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: HarnessText.body(context))),
          _chip(reason, null),
        ],
      ),
    );
  }

  List<Widget> _wallet(WorkspaceResources resources) {
    final wallet = resources.wallet;
    if (wallet == null) {
      return [_empty('No wallet', 'Wallet provider')];
    }
    return [
      _section('Cards'),
      if (wallet.cards.isEmpty)
        _empty('No cards', 'Wallet provider')
      else
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final card in wallet.cards) _cardTile(card)],
        ),
      _disabledRow('Add card…', 'Needs wallet provider', Icons.add_card_rounded),
      const SizedBox(height: HarnessSpace.lg),
      if (wallet.purchases.any((purchase) => purchase.proposed)) ...[
        _section('Purchase'),
        for (final purchase in wallet.purchases.where((purchase) => purchase.proposed))
          _purchaseCard(wallet, purchase),
        const SizedBox(height: HarnessSpace.lg),
      ],
      Row(
        children: [
          Expanded(child: _section('Authorizations')),
          _chip('Advisory · no broker', HarnessColors.amber),
        ],
      ),
      if (wallet.authorizations.isEmpty)
        _empty('No authorizations', 'Bound purchases')
      else
        for (final authorization in wallet.authorizations)
          _authorizationTile(wallet, authorization),
      const SizedBox(height: HarnessSpace.md),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.tonal(
          onPressed: _controller.canManageWallet ? _newAuthorization : null,
          child: const Text('New authorization'),
        ),
      ),
      if (!_controller.canManageWallet) ...[
        const SizedBox(height: 4),
        Text(
          _controller.preview ? 'Preview · read-only' : 'Needs wallet provider',
          style: HarnessText.caption(context),
        ),
      ],
    ];
  }

  Widget _cardTile(WalletCard card) {
    return Container(
      width: 300,
      height: 170,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF141743),
        border: Border.all(color: const Color(0xFFE8D9B5).withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(2),
        // Flat, like the desktop panels: a rule, not a shadow.
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.credit_card_rounded, size: 18, color: Colors.white70),
              const SizedBox(width: 8),
              Text(
                card.network.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              Text(
                card.stateLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          Text(
            '••••  ••••  ••••  ${card.last4}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'EXPIRES',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                card.expiryLabel,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  card.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _purchaseCard(WalletData wallet, WalletPurchase purchase) {
    WalletAuthorization? authorization;
    for (final item in wallet.authorizations) {
      if (item.id == purchase.authorization) authorization = item;
    }
    final card = authorization == null ? null : wallet.cardOf(authorization);
    return Container(
      padding: const EdgeInsets.all(HarnessSpace.lg),
      decoration: BoxDecoration(
        color: HarnessColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: HarnessColors.amber.withValues(alpha: 0.38)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Purchase · ${_money(purchase.amount, purchase.currency)}',
            style: HarnessText.rowTitle(context),
          ),
          const SizedBox(height: 4),
          Text(
            [
              purchase.merchant,
              if (card != null) card.label,
              if (authorization != null)
                '${authorization.capLabel} · ${_money(authorization.remaining, authorization.currency)} left',
              if (authorization != null && !authorization.allIn) 'Cap excludes fees',
            ].join(' · '),
            style: HarnessText.caption(context),
          ),
          const SizedBox(height: HarnessSpace.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _controller.canManageWallet
                    ? () => _confirmPurchase(purchase)
                    : null,
                child: const Text('Allow'),
              ),
              OutlinedButton(
                onPressed: _controller.canManageWallet
                    ? () => unawaited(_controller.decidePurchase(purchase.id, allow: false))
                    : null,
                child: const Text('Deny'),
              ),
              if (!_controller.canManageWallet)
                _chip(_controller.preview ? 'Preview' : 'Broker unavailable', null),
            ],
          ),
        ],
      ),
    );
  }

  Widget _authorizationTile(WalletData wallet, WalletAuthorization authorization) {
    final card = wallet.cardOf(authorization);
    final used = authorization.amount == 0
        ? 0.0
        : (authorization.spent + authorization.reserved) /
              authorization.amount;
    return Semantics(
      button: true,
      label:
          'Authorization ${_money(authorization.amount, authorization.currency)}, '
          '${authorization.capLabel}, ${authorization.statusLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(2),
          onTap: () => _showAuthorization(wallet, authorization),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_money(authorization.amount, authorization.currency)} · ${authorization.capLabel}',
                            style: HarnessText.rowTitle(context),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (card != null) card.label,
                              authorization.scopeLabel,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.caption(context),
                          ),
                        ],
                      ),
                    ),
                    _statusChip(authorization.statusLabel, authorization.status),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: used.clamp(0, 1),
                    minHeight: 5,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    color: authorization.status == 'active'
                        ? HarnessColors.moss
                        : Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        authorization.perTransaction
                            ? 'Cap per transaction'
                            : 'Remaining ${_money(authorization.remaining, authorization.currency)}',
                        style: HarnessText.meta(context),
                      ),
                    ),
                    if (authorization.expires != null)
                      Text(
                        'Expires ${_until(authorization.expires)}',
                        style: HarnessText.meta(context),
                      ),
                    const SizedBox(width: 8),
                    if (authorization.advisory)
                      _chip('Advisory', HarnessColors.amber),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _credentials(WorkspaceResources resources) {
    final status = resources.credentialsStatus;
    return [
      _section('Credentials'),
      Container(
        padding: const EdgeInsets.all(HarnessSpace.lg),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: HarnessColors.moss.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(
                    Icons.key_rounded,
                    size: 20,
                    color: HarnessColors.moss,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Secrets module',
                        style: HarnessText.rowTitle(context),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        status?.why ?? 'Values never leave the sandbox',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.caption(context),
                      ),
                    ],
                  ),
                ),
                _chip(status?.label ?? 'Unavailable', status?.ready == true ? HarnessColors.moss : null),
              ],
            ),
            if (resources.credentials.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '${resources.credentials.length} declared · locked runs · no values',
                style: HarnessText.meta(context),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: HarnessSpace.md),
      if (resources.credentials.isEmpty)
        _empty('No credentials', 'Secrets module')
      else
        for (final credential in resources.credentials)
          _credentialTile(credential),
    ];
  }

  Widget _credentialTile(CredentialResource credential) {
    return Semantics(
      button: true,
      label: 'Credential ${credential.label}, ${credential.stateLabel}',
      child: InkWell(
        borderRadius: BorderRadius.circular(2),
        onTap: () => _showCredential(credential),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: _cardDecoration(),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.vpn_key_outlined,
                  size: 19,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(credential.label, style: HarnessText.rowTitle(context)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (credential.fingerprint.isNotEmpty)
                          'SHA-256 ${credential.fingerprint}',
                        if (credential.lastUsed != null)
                          'last used ${_ago(credential.lastUsed)}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HarnessText.caption(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _chip(
                credential.usable ? 'Ready' : 'Unavailable',
                credential.usable ? HarnessColors.moss : null,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCredential(CredentialResource credential) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HarnessSpace.sheetGutter,
            0,
            HarnessSpace.sheetGutter,
            HarnessSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      credential.label,
                      style: HarnessText.sheetTitle(context),
                    ),
                  ),
                  _chip(
                    credential.usable ? 'Ready' : 'Unavailable',
                    credential.usable ? HarnessColors.moss : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Secret · locked run · metadata only',
                style: HarnessText.caption(context),
              ),
              const SizedBox(height: HarnessSpace.md),
              _readRow('Fingerprint', credential.fingerprint.isEmpty ? 'None' : credential.fingerprint),
              _readRow('Last used', credential.lastUsed == null ? 'Never' : _ago(credential.lastUsed)),
              _readRow('Value', 'Sandbox only'),
              if (credential.error != null) ...[
                const SizedBox(height: HarnessSpace.sm),
                Text(
                  credential.error!,
                  style: HarnessText.caption(context).copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: HarnessSpace.md),
              Text(
                'A locked command reads the value from a file; its output and the value never reach the agent.',
                style: HarnessText.caption(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _access(WorkspaceResources resources) {
    return [
      _section('Agent access'),
      if (resources.access.isEmpty)
        _empty('No grants', 'Resources')
      else
        for (final grant in resources.access) _accessTile(grant),
      const SizedBox(height: HarnessSpace.lg),
      _section('Audit'),
      if (resources.audit.isEmpty)
        _empty('No audit', 'Resources')
      else
        for (final entry in resources.audit) _auditTile(entry),
    ];
  }

  Widget _accessTile(AccessGrant grant) {
    final revocable = _controller.canManageWallet && grant.kind == 'authorization';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        children: [
          Icon(
            grant.kind == 'authorization'
                ? Icons.lock_clock_outlined
                : grant.kind == 'site'
                ? Icons.public_rounded
                : Icons.rule_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(grant.label, style: HarnessText.rowTitle(context)),
                const SizedBox(height: 2),
                Text(
                  [
                    grant.kind,
                    grant.scope,
                    grant.owner,
                    grant.state,
                    if (grant.availability != 'ready') grant.availability,
                  ].join(' · '),
                  style: HarnessText.caption(context),
                ),
              ],
            ),
          ),
          _chip(grant.accessLabel, grant.access == 'allowed' ? HarnessColors.moss : null),
          const SizedBox(width: 4),
          _action(
            'Revoke',
            enabled: revocable,
            reason: _controller.preview ? 'Preview' : 'Needs box',
            onPressed: () => _confirmRevoke(grant),
          ),
        ],
      ),
    );
  }

  Widget _auditTile(AuditEntry entry) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${entry.action} · ${entry.resource}',
              style: HarnessText.body(context),
            ),
          ),
          Text(
            '${entry.actor} · ${_ago(entry.at)}',
            style: HarnessText.caption(context),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _confirmClearProfile() async {
    final browser = _controller.resources?.browser;
    final sites = browser?.sites.length ?? 0;
    final ok = await _confirm(
      'Clear all browser data',
      'Profile · ${browser?.profile.label ?? 'default'} · $sites sites · cannot be undone',
      'Clear all',
    );
    if (!ok || !mounted) return;
    await _controller.clearProfile();
    _afterAction();
  }

  Future<void> _confirmForget(BrowserLogin login) async {
    final ok = await _confirm(
      'Forget login',
      'Site · ${login.host} · session ends · cookies cleared',
      'Forget',
    );
    if (!ok || !mounted) return;
    await _controller.forgetLogin(login.id);
    _afterAction();
  }

  Future<void> _confirmRevoke(AccessGrant grant) async {
    final ok = await _confirm(
      'Revoke authorization',
      '${grant.label} · agent access ends',
      'Revoke',
    );
    if (!ok || !mounted) return;
    final id = _authorizationId(grant);
    if (id != null) await _controller.revokeAuthorization(id);
    _afterAction();
  }

  Future<void> _confirmPurchase(WalletPurchase purchase) async {
    final wallet = _controller.resources?.wallet;
    WalletAuthorization? authorization;
    for (final item in wallet?.authorizations ?? const <WalletAuthorization>[]) {
      if (item.id == purchase.authorization) authorization = item;
    }
    final ok = await _confirm(
      'Allow purchase',
      [
        purchase.merchant,
        _money(purchase.amount, purchase.currency),
        if (authorization != null) authorization.capLabel,
        if (authorization != null) '${_money(authorization.remaining, authorization.currency)} left',
        'Advisory · no broker',
      ].join(' · '),
      'Allow',
    );
    if (!ok || !mounted) return;
    await _controller.decidePurchase(purchase.id, allow: true);
    _afterAction();
  }

  void _afterAction() {
    if (!mounted) return;
    // A change closes the sheet it was made from; the list behind it is the
    // new state.  This keeps every sheet reading one snapshot.
    Navigator.of(context).maybePop();
  }

  String? _authorizationId(AccessGrant grant) {
    final wallet = _controller.resources?.wallet;
    for (final authorization in wallet?.authorizations ?? const <WalletAuthorization>[]) {
      if (grant.label.startsWith(_money(authorization.amount, authorization.currency))) {
        return authorization.id;
      }
    }
    return null;
  }

  Future<void> _showSite(BrowserSite site) async {
    final login = _loginFor(site.origin);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => _siteSheet(context, site, login, setSheet),
      ),
    );
  }

  BrowserLogin? _loginFor(String origin) {
    for (final login in _controller.resources?.browser?.logins ?? const <BrowserLogin>[]) {
      if (login.origin == origin) return login;
    }
    return null;
  }

  Widget _siteSheet(
    BuildContext context,
    BrowserSite site,
    BrowserLogin? login,
    StateSetter setSheet,
  ) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          0,
          HarnessSpace.sheetGutter,
          HarnessSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(site.host, style: HarnessText.sheetTitle(context)),
                ),
                _chip(site.authLabel, site.auth == 'signed-in' ? HarnessColors.moss : null),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Last used ${_ago(site.lastUsed)} · metadata only',
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.md),
            _factRow('Cookies', '${site.cookies}', () => _clearKind(site, 'cookies', setSheet)),
            _factRow('Site data', formatBytes(site.storageBytes), () => _clearKind(site, 'storage', setSheet)),
            _factRow('Cache', formatBytes(site.cacheBytes), () => _clearKind(site, 'cache', setSheet)),
            _factRow('Permissions', '${site.permissions}', () => _clearKind(site, 'permissions', setSheet)),
            const SizedBox(height: HarnessSpace.lg),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _controller.canManageBrowser
                      ? () => _clearSiteAll(site, setSheet)
                      : null,
                  child: const Text('Clear site data'),
                ),
                if (login != null)
                  OutlinedButton(
                    onPressed: _controller.canManageBrowser
                        ? () => _forgetLogin(login, setSheet)
                        : null,
                    child: const Text('Forget login'),
                  ),
              ],
            ),
            if (!_controller.canManageBrowser) ...[
              const SizedBox(height: 6),
              Text(
                _controller.preview ? 'Preview · no changes' : 'Needs box',
                style: HarnessText.caption(context),
              ),
            ],
            if (_controller.error != null) ...[
              const SizedBox(height: 8),
              Text(
                _controller.error!,
                style: HarnessText.caption(context).copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _factRow(String label, String value, VoidCallback clear) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: HarnessText.body(context))),
          Text(value, style: HarnessText.meta(context)),
          const SizedBox(width: 8),
          _action(
            'Clear',
            enabled: _controller.canManageBrowser,
            reason: _controller.preview ? 'Preview' : 'Needs box',
            onPressed: clear,
          ),
        ],
      ),
    );
  }

  Future<void> _clearKind(BrowserSite site, String kind, StateSetter setSheet) async {
    final ok = await _confirm(
      'Clear ${kind == 'cookies' ? 'cookies' : kind == 'storage' ? 'site data' : kind}',
      'Site · ${site.host} · ${kind == 'cookies' ? '${site.cookies} cookies' : 'cannot be undone'}',
      'Clear',
    );
    if (!ok || !mounted) return;
    await _controller.clearSite(site.origin, [kind]);
    setSheet(() {});
    if (_controller.notice != null && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _clearSiteAll(BrowserSite site, StateSetter setSheet) async {
    final ok = await _confirm(
      'Clear site data',
      'Site · ${site.host} · cookies · storage · cache · permissions',
      'Clear site',
    );
    if (!ok || !mounted) return;
    await _controller.clearSite(site.origin, const ['cookies', 'storage', 'cache', 'permissions']);
    setSheet(() {});
    if (_controller.notice != null && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _forgetLogin(BrowserLogin login, StateSetter setSheet) async {
    final ok = await _confirm(
      'Forget login',
      'Site · ${login.host} · session ends · cookies cleared',
      'Forget',
    );
    if (!ok || !mounted) return;
    await _controller.forgetLogin(login.id);
    setSheet(() {});
    if (_controller.notice != null && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _showAuthorization(WalletData wallet, WalletAuthorization authorization) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => _authorizationSheet(context, wallet, authorization, setSheet),
      ),
    );
  }

  Widget _authorizationSheet(
    BuildContext context,
    WalletData wallet,
    WalletAuthorization authorization,
    StateSetter setSheet,
  ) {
    final card = wallet.cardOf(authorization);
    final purchases = [
      for (final purchase in wallet.purchases)
        if (purchase.authorization == authorization.id) purchase,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          0,
          HarnessSpace.sheetGutter,
          HarnessSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_money(authorization.amount, authorization.currency)} · ${authorization.capLabel}',
                    style: HarnessText.sheetTitle(context),
                  ),
                ),
                _statusChip(authorization.statusLabel, authorization.status),
              ],
            ),
            Text(
              '${authorization.scopeLabel} · ${authorization.allIn ? 'Fees included' : 'Cap excludes fees'}',
              style: HarnessText.caption(context),
            ),
            const SizedBox(height: HarnessSpace.md),
            _readRow('Card', card?.label ?? 'Card'),
            _readRow('Remaining', _money(authorization.remaining, authorization.currency)),
            _readRow('Spent', _money(authorization.spent, authorization.currency)),
            if (authorization.reserved > 0)
              _readRow('Reserved', _money(authorization.reserved, authorization.currency)),
            _readRow('Expires', _until(authorization.expires)),
            _readRow('Broker', authorization.advisory ? 'Advisory' : 'Enforced'),
            const SizedBox(height: HarnessSpace.lg),
            _section('History'),
            if (purchases.isEmpty)
              _empty('No purchases', 'Authorization')
            else
              for (final purchase in purchases)
                _readRow(
                  '${purchase.statusLabel} · ${_money(purchase.amount, purchase.currency)}',
                  _ago(purchase.at),
                ),
            const SizedBox(height: HarnessSpace.lg),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _action(
                'Revoke…',
                enabled: _controller.canManageWallet && authorization.status == 'active',
                reason: _controller.preview ? 'Preview' : 'Needs wallet provider',
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  final ok = await _confirm(
                    'Revoke authorization',
                    '${_money(authorization.amount, authorization.currency)} · ${authorization.scopeLabel} · agent access ends',
                    'Revoke',
                  );
                  if (!ok || !mounted) return;
                  await _controller.revokeAuthorization(authorization.id);
                  setSheet(() {});
                  if (_controller.notice != null && mounted) navigator.maybePop();
                },
              ),
            ),
            if (_controller.error != null) ...[
              const SizedBox(height: 8),
              Text(
                _controller.error!,
                style: HarnessText.caption(context).copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _readRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label, style: HarnessText.body(context))),
          Text(value, style: HarnessText.meta(context)),
        ],
      ),
    );
  }

  Future<void> _newAuthorization() async {
    final wallet = _controller.resources?.wallet;
    final card = wallet?.cards.isNotEmpty == true ? wallet!.cards.first : null;
    if (card == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (context) => _AuthorizationForm(
        controller: _controller,
        card: card,
      ),
    );
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------------- small bits

  BoxDecoration _cardDecoration() => BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(2),
    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
  );

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.only(bottom: HarnessSpace.sm),
    child: Text(label, style: HarnessText.label(context)),
  );

  Widget _chip(String label, Color? color) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: HarnessText.meta(context).copyWith(
          color: color ?? theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _statusChip(String label, String status) => _chip(
    label,
    switch (status) {
      'active' => HarnessColors.moss,
      'expired' || 'exhausted' => HarnessColors.amber,
      'revoked' => Theme.of(context).colorScheme.error,
      _ => null,
    },
  );

  Widget _action(
    String label, {
    required bool enabled,
    required String reason,
    required VoidCallback onPressed,
  }) {
    final button = HarnessTextButton(
      label: label,
      dense: true,
      onPressed: enabled ? onPressed : null,
    );
    return enabled ? button : Tooltip(message: reason, child: button);
  }

  Widget _empty(String title, String detail) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: HarnessSpace.sm),
      padding: const EdgeInsets.all(HarnessSpace.lg),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: HarnessText.rowTitle(context)),
          const SizedBox(height: 2),
          Text(detail, style: HarnessText.caption(context)),
        ],
      ),
    );
  }

  Widget _banner({
    required String text,
    String? action,
    VoidCallback? onAction,
    bool error = false,
  }) {
    final color = error
        ? Theme.of(context).colorScheme.error
        : HarnessColors.moss;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, style: HarnessText.caption(context))),
          if (action != null)
            HarnessTextButton(label: action, dense: true, onPressed: onAction),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String confirm) async {
    final answer = await showHarnessDialog<bool>(
      context: context,
      title: title,
      message: body,
      confirmLabel: confirm,
      cancelLabel: 'Cancel',
      destructive: true,
    );
    return answer == true;
  }
}

/// A small, bounded form for a purchase authorization.  All fields are
/// metadata; no card number or token is asked for, and the chosen card is
/// a reference from the wallet.
class _AuthorizationForm extends StatefulWidget {
  const _AuthorizationForm({required this.controller, required this.card});

  final ResourcesController controller;
  final WalletCard card;

  @override
  State<_AuthorizationForm> createState() => _AuthorizationFormState();
}

class _AuthorizationFormState extends State<_AuthorizationForm> {
  final _amount = TextEditingController(text: '10.00');
  final _merchant = TextEditingController();
  String _capKind = 'cumulative';
  String _expiry = '24h';
  bool _fees = true;
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  int? get _minor {
    final text = _amount.text.trim().replaceAll(',', '');
    final value = double.tryParse(text);
    if (value == null) return null;
    return (value * 100).round();
  }

  Future<void> _submit() async {
    final amount = _minor;
    if (amount == null || amount <= 0) {
      setState(() => _problem = 'Amount');
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final problem = await widget.controller.createAuthorization(
      card: widget.card.id,
      amount: amount,
      merchant: _merchant.text,
      capKind: _capKind,
      expiry: _expiry,
      fees: _fees ? 'included' : 'excluded',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _problem = problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount = _minor;
    final scope = _merchant.text.trim().isEmpty ? 'Any merchant' : _merchant.text.trim();
    final summary = [
      amount == null ? 'Amount' : 'Max ${_money(amount, 'USD')}',
      _capKind == 'cumulative' ? 'Cumulative' : 'Per transaction',
      scope,
      _fees ? 'Fees included' : 'Cap excludes fees',
    ].join(' · ');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          HarnessSpace.sheetGutter,
          0,
          HarnessSpace.sheetGutter,
          HarnessSpace.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New authorization', style: HarnessText.sheetTitle(context)),
              const SizedBox(height: 4),
              Text(
                '${widget.card.label} · ${widget.card.expiryLabel} · metadata only',
                style: HarnessText.caption(context),
              ),
              const SizedBox(height: HarnessSpace.lg),
              TextField(
                key: const ValueKey('authorization-amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: r'$ ',
                  helperText: 'Cap · USD',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: HarnessSpace.md),
              TextField(
                key: const ValueKey('authorization-merchant'),
                controller: _merchant,
                decoration: const InputDecoration(
                  labelText: 'Merchant',
                  hintText: 'stoneco.example',
                  helperText: 'Empty · any merchant',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: HarnessSpace.md),
              Text('Limit', style: HarnessText.label(context)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cumulative', label: Text('Cumulative')),
                  ButtonSegment(value: 'per-transaction', label: Text('Per transaction')),
                ],
                selected: {_capKind},
                showSelectedIcon: false,
                onSelectionChanged: (value) => setState(() => _capKind = value.first),
              ),
              const SizedBox(height: HarnessSpace.md),
              DropdownButtonFormField<String>(
                initialValue: _expiry,
                decoration: const InputDecoration(labelText: 'Expires'),
                items: const [
                  DropdownMenuItem(value: '1h', child: Text('1 hour')),
                  DropdownMenuItem(value: '24h', child: Text('24 hours')),
                  DropdownMenuItem(value: '7d', child: Text('7 days')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _expiry = value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fees included'),
                subtitle: const Text('Tax · shipping · fees'),
                value: _fees,
                onChanged: (value) => setState(() => _fees = value),
              ),
              const SizedBox(height: HarnessSpace.sm),
              Container(
                padding: const EdgeInsets.all(HarnessSpace.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(summary, style: HarnessText.body(context)),
                    const SizedBox(height: 4),
                    _chip('Advisory · no broker', HarnessColors.amber),
                  ],
                ),
              ),
              if (_problem != null) ...[
                const SizedBox(height: HarnessSpace.sm),
                Text(
                  _problem!,
                  style: HarnessText.caption(context).copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: HarnessSpace.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HarnessTextButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: HarnessText.meta(context).copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

String _money(int minor, String currency) {
  final sign = currency == 'USD' ? r'$' : '';
  final whole = minor ~/ 100;
  final cents = (minor % 100).toString().padLeft(2, '0');
  return '$sign$whole.$cents';
}

String _until(DateTime? time) {
  if (time == null) return 'Never';
  final left = time.difference(DateTime.now());
  if (left.isNegative) return 'Expired';
  if (left.inMinutes < 60) return 'in ${left.inMinutes}m';
  if (left.inHours < 24) return 'in ${left.inHours}h';
  return 'in ${left.inDays}d';
}

String _ago(DateTime? time) {
  if (time == null) return '';
  final text = relativeTime(time);
  if (RegExp(r'^\d+[mhd]$').hasMatch(text)) return '$text ago';
  return text;
}
