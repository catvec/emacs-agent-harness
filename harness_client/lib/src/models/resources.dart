import '../acp/acp_message.dart';
import 'session.dart';

/// The workspace's first-class resources — its browser, its wallet and the
/// access the agent has to either — as one metadata-only answer.
///
/// Nothing here has a field for a value: no cookie, password, card number or
/// token.  The wire is read with the same rule; a field the harness should
/// never send is ignored rather than kept (see [BrowserData.fromWire]).
class WorkspaceResources {
  const WorkspaceResources({
    required this.workspace,
    required this.status,
    this.reason,
    this.metadataOnly = true,
    this.browser,
    this.wallet,
    this.access = const [],
    this.audit = const [],
    this.credentials = const [],
    this.credentialsStatus,
    this.browserStatus,
    this.walletStatus,
  });

  factory WorkspaceResources.fromWire(JsonMap wire) {
    final browser = asMap(wire['browser']);
    final wallet = asMap(wire['wallet']);
    return WorkspaceResources(
      workspace: asStringOr(wire['workspace'], ''),
      status: asStringOr(wire['status'], 'unavailable'),
      reason: asString(wire['reason']),
      metadataOnly: asBool(
        wire['metadata-only'] ?? wire['metadataOnly'],
        fallback: true,
      ),
      browser: browser.isEmpty ? null : BrowserData.fromWire(browser),
      wallet: wallet.isEmpty ? null : WalletData.fromWire(wallet),
      access: [
        for (final item in asMapList(wire['access']))
          AccessGrant.fromWire(item),
      ],
      audit: [
        for (final item in asMapList(wire['audit'])) AuditEntry.fromWire(item),
      ],
      credentials: [
        for (final item in asMapList(wire['credentials']))
          CredentialResource.fromWire(item),
      ],
      credentialsStatus: asMap(wire['credentials-status']).isEmpty
          ? null
          : CredentialsStatus.fromWire(asMap(wire['credentials-status'])),
      browserStatus: asString(wire['browser-status']),
      walletStatus: asString(wire['wallet-status']),
    );
  }

  /// A workspace with no box and no wallet provider: a real answer, not an
  /// error, so the page can say what is missing instead of pretending.
  factory WorkspaceResources.unavailable(String workspace, String reason) =>
      WorkspaceResources(
        workspace: workspace,
        status: 'unavailable',
        reason: reason,
      );

  final String workspace;
  final String status;
  final String? reason;
  final bool metadataOnly;
  final BrowserData? browser;
  final WalletData? wallet;
  final List<AccessGrant> access;
  final List<AuditEntry> audit;

  /// The harness's declared secrets, as ordinary credentials: label,
  /// fingerprint, usability and last use, never a value.
  final List<CredentialResource> credentials;
  final CredentialsStatus? credentialsStatus;
  final String? browserStatus;
  final String? walletStatus;

  bool get ready => status == 'ready';
  bool get browserReady => browser != null;
  bool get walletReady => wallet != null;
  bool get credentialsReady => credentialsStatus?.status == 'ready';
  bool get blocked => status == 'unavailable';
  bool get needsApproval => status == 'needs-approval';
  bool get failed => status == 'failed';

  /// The words the status carries: never only a colour.
  String get statusLabel => switch (status) {
    'ready' => browser == null && wallet == null ? 'Partial' : 'Live',
    'preview' => 'Preview',
    'needs-approval' => 'Needs approval',
    'failed' => 'Failed',
    _ => 'Unavailable',
  };

  /// What the panel says under the status.
  String? get reasonLabel => switch (reason) {
    'box-staged' => 'Box staged',
    'box-tools-missing' => 'Computer tools',
    'box-not-running' => 'Computer off',
    'backend-unavailable' => 'Computer unavailable',
    'wallet-unavailable' => 'Wallet provider',
    'wallet-provider' => 'Wallet provider',
    'payment-broker' => 'Payment broker',
    'browser-tools' => 'Browser tools',
    'browser-unavailable' => 'Browser profile',
    'permission' => 'Permission',
    'browser-stopped' => 'Browser stopped',
    _ => reason,
  };

  /// The reason a fixture shows in preview, never a real value.
  static WorkspaceResources preview({String workspace = 'Home'}) {
    return WorkspaceResources(
      workspace: workspace,
      status: 'ready',
      metadataOnly: true,
      browser: BrowserData.preview(),
      wallet: WalletData.preview(),
      access: [
        const AccessGrant(
          kind: 'site',
          label: 'stoneco.example',
          scope: 'site',
          owner: 'user',
          state: 'active',
          availability: 'ready',
          access: 'allowed',
          detail: 'Signed in',
        ),
        const AccessGrant(
          kind: 'authorization',
          label: r'$10.00 · Visa •••• 4242',
          scope: 'authorization',
          owner: 'user',
          state: 'active',
          availability: 'ready',
          access: 'ask',
          detail: 'Per purchase',
        ),
        const AccessGrant(
          kind: 'permission',
          label: 'Browser · stoneco.example',
          scope: 'global',
          owner: 'user',
          state: 'active',
          availability: 'ready',
          access: 'ask',
          detail: 'Every tool',
        ),
      ],
      audit: [
        AuditEntry(
          at: DateTime.now().subtract(const Duration(minutes: 12)),
          action: 'Created',
          resource: r'Authorization · $10',
          actor: 'user',
          scope: 'authorization',
        ),
        AuditEntry(
          at: DateTime.now().subtract(const Duration(hours: 3)),
          action: 'Used',
          resource: 'Site · stoneco.example',
          actor: 'agent',
          scope: 'site',
        ),
        AuditEntry(
          at: DateTime.now().subtract(const Duration(days: 1)),
          action: 'Forgotten',
          resource: 'Login · bank.example',
          actor: 'user',
          scope: 'login',
        ),
      ],
      credentials: const [
        CredentialResource(
          label: 'deploy-key',
          fingerprint: '4f9c2a1b',
          usable: true,
          lastUsed: null,
        ),
        CredentialResource(
          label: 'npm-token',
          fingerprint: 'b81e7d20',
          usable: false,
          error: 'Masking off',
        ),
      ],
      credentialsStatus: const CredentialsStatus(
        status: 'ready',
        mask: true,
        locked: true,
        count: 2,
      ),
      browserStatus: 'ready',
      walletStatus: 'ready',
    );
  }
}

/// The box's browser profile: its sites and the logins that keep them
/// signed in.  Values are stripped in the box; this type has nowhere to put
/// one.
/// One browser the box can offer for a profile.  Firefox is the primary,
/// most supported one; Chromium is the second choice; the rest are named as
/// unavailable rather than promised.
class BrowserType {
  const BrowserType({
    required this.id,
    required this.label,
    this.primary = false,
    this.available = true,
    this.support = 'secondary',
  });

  factory BrowserType.fromWire(JsonMap wire) => BrowserType(
    id: asStringOr(wire['id'], ''),
    label: asStringOr(wire['label'], 'Browser'),
    primary: asBool(wire['primary']),
    available: asBool(wire['available'], fallback: true),
    support: asStringOr(wire['support'], 'secondary'),
  );

  final String id;
  final String label;
  final bool primary;
  final bool available;
  final String support;

  String get supportLabel => !available
      ? 'Unavailable'
      : primary
      ? 'Primary'
      : support == 'secondary'
      ? 'Secondary'
      : 'Experimental';

  static const defaults = [
    BrowserType(
      id: 'firefox',
      label: 'Firefox',
      primary: true,
      support: 'primary',
    ),
    BrowserType(id: 'chromium', label: 'Chromium', support: 'secondary'),
    BrowserType(
      id: 'webkit',
      label: 'WebKit',
      available: false,
      support: 'experimental',
    ),
  ];
}

class BrowserData {
  const BrowserData({
    required this.profile,
    this.sites = const [],
    this.logins = const [],
    this.cookies = 0,
    this.bytes = 0,
    this.browsers = BrowserType.defaults,
  });

  factory BrowserData.fromWire(JsonMap wire) {
    final profile = asMap(wire['profile']);
    final totals = asMap(wire['totals']);
    return BrowserData(
      profile: BrowserProfile.fromWire(profile),
      sites: [
        for (final item in asMapList(wire['sites'])) BrowserSite.fromWire(item),
      ],
      logins: [
        for (final item in asMapList(wire['logins']))
          BrowserLogin.fromWire(item),
      ],
      cookies: asInt(totals['cookies']) ?? 0,
      bytes: asInt(totals['bytes']) ?? 0,
      browsers: asMapList(wire['browsers']).isEmpty
          ? BrowserType.defaults
          : [
              for (final item in asMapList(wire['browsers']))
                BrowserType.fromWire(item),
            ],
    );
  }

  factory BrowserData.preview() {
    final now = DateTime.now();
    return BrowserData(
      profile: BrowserProfile(
        label: 'Home',
        kind: 'Firefox',
        bytes: 412 * 1024 * 1024,
        sites: 18,
        lastUsed: now.subtract(const Duration(minutes: 4)),
      ),
      sites: [
        BrowserSite(
          origin: 'https://stoneco.example',
          cookies: 12,
          storageBytes: 320000,
          cacheBytes: 640000,
          permissions: 2,
          auth: 'signed-in',
          lastUsed: now.subtract(const Duration(minutes: 12)),
        ),
        BrowserSite(
          origin: 'https://github.com',
          cookies: 4,
          storageBytes: 110000,
          cacheBytes: 210000,
          permissions: 0,
          auth: 'signed-out',
          lastUsed: now.subtract(const Duration(hours: 5)),
        ),
        BrowserSite(
          origin: 'https://bank.example',
          cookies: 8,
          storageBytes: 64000,
          cacheBytes: 90000,
          permissions: 1,
          auth: 'signed-in',
          lastUsed: now.subtract(const Duration(days: 1)),
        ),
      ],
      logins: [
        BrowserLogin(
          id: 'lg-1',
          origin: 'https://stoneco.example',
          username: 'j•••@example.com',
          state: 'active',
          created: now.subtract(const Duration(days: 20)),
          lastUsed: now.subtract(const Duration(minutes: 12)),
        ),
        BrowserLogin(
          id: 'lg-2',
          origin: 'https://bank.example',
          username: 'j•••@example.com',
          state: 'expired',
          created: now.subtract(const Duration(days: 40)),
          lastUsed: now.subtract(const Duration(days: 9)),
        ),
      ],
      cookies: 24,
      bytes: 412 * 1024 * 1024,
    );
  }

  final BrowserProfile profile;
  final List<BrowserSite> sites;
  final List<BrowserLogin> logins;
  final int cookies;
  final int bytes;
  final List<BrowserType> browsers;

  List<String> get origins => [for (final site in sites) site.origin];
}

class BrowserProfile {
  const BrowserProfile({
    this.label = 'default',
    this.kind = 'Chromium',
    this.bytes = 0,
    this.sites = 0,
    this.lastUsed,
  });

  factory BrowserProfile.fromWire(JsonMap wire) => BrowserProfile(
    label: asStringOr(wire['label'], 'default'),
    kind: asStringOr(wire['kind'], 'Chromium'),
    bytes: asInt(wire['bytes']) ?? 0,
    sites: asInt(wire['sites']) ?? 0,
    lastUsed: parseTime(wire['last-used'] ?? wire['lastUsed']),
  );

  final String label;
  final String kind;
  final int bytes;
  final int sites;
  final DateTime? lastUsed;
}

class BrowserSite {
  const BrowserSite({
    required this.origin,
    this.cookies = 0,
    this.storageBytes = 0,
    this.cacheBytes = 0,
    this.permissions = 0,
    this.auth = 'unknown',
    this.lastUsed,
  });

  factory BrowserSite.fromWire(JsonMap wire) => BrowserSite(
    origin: asStringOr(wire['origin'], ''),
    cookies: asInt(wire['cookies']) ?? 0,
    storageBytes: asInt(wire['storage-bytes'] ?? wire['storageBytes']) ?? 0,
    cacheBytes: asInt(wire['cache-bytes'] ?? wire['cacheBytes']) ?? 0,
    permissions: asInt(wire['permissions']) ?? 0,
    auth: asStringOr(wire['auth'], 'unknown'),
    lastUsed: parseTime(wire['last-used'] ?? wire['lastUsed']),
  );

  final String origin;
  final int cookies;
  final int storageBytes;
  final int cacheBytes;
  final int permissions;
  final String auth;
  final DateTime? lastUsed;

  /// The host without its scheme, for a row's title.
  String get host => origin
      .replaceFirst(RegExp(r'^[a-z]+://'), '')
      .replaceAll(RegExp(r'/$'), '');

  String get authLabel => switch (auth) {
    'signed-in' => 'Signed in',
    'signed-out' => 'Signed out',
    _ => 'Unknown',
  };

  String get dataLabel {
    final parts = <String>[
      if (cookies > 0) 'Cookies $cookies',
      if (storageBytes > 0) 'Site data ${formatBytes(storageBytes)}',
      if (cacheBytes > 0) 'Cache ${formatBytes(cacheBytes)}',
    ];
    return parts.isEmpty ? 'No data' : parts.join(' · ');
  }
}

class BrowserLogin {
  const BrowserLogin({
    required this.id,
    required this.origin,
    this.username = '',
    this.state = 'active',
    this.created,
    this.lastUsed,
  });

  factory BrowserLogin.fromWire(JsonMap wire) => BrowserLogin(
    id: asStringOr(wire['id'], ''),
    origin: asStringOr(wire['origin'], ''),
    username: asStringOr(wire['username'], ''),
    state: asStringOr(wire['state'], 'active'),
    created: parseTime(wire['created']),
    lastUsed: parseTime(wire['last-used'] ?? wire['lastUsed']),
  );

  final String id;
  final String origin;
  final String username;
  final String state;
  final DateTime? created;
  final DateTime? lastUsed;

  String get host => origin
      .replaceFirst(RegExp(r'^[a-z]+://'), '')
      .replaceAll(RegExp(r'/$'), '');
  String get stateLabel => switch (state) {
    'active' => 'Active',
    'expired' => 'Expired',
    _ => 'Unknown',
  };
}

/// Cards, bounded purchase authorizations and the purchases they bound.
/// There is no PAN, CVV, token or cardholder field, by construction.
class WalletData {
  const WalletData({
    this.cards = const [],
    this.authorizations = const [],
    this.purchases = const [],
  });

  factory WalletData.fromWire(JsonMap wire) => WalletData(
    cards: [
      for (final item in asMapList(wire['cards'])) WalletCard.fromWire(item),
    ],
    authorizations: [
      for (final item in asMapList(wire['authorizations']))
        WalletAuthorization.fromWire(item),
    ],
    purchases: [
      for (final item in asMapList(wire['purchases']))
        WalletPurchase.fromWire(item),
    ],
  );

  factory WalletData.preview() {
    final now = DateTime.now();
    return WalletData(
      cards: [
        WalletCard(
          id: 'card-1',
          label: 'Visa •••• 4242',
          network: 'Visa',
          last4: '4242',
          expMonth: 9,
          expYear: 2028,
          state: 'active',
          added: now.subtract(const Duration(days: 30)),
          lastUsed: now.subtract(const Duration(minutes: 12)),
        ),
      ],
      authorizations: [
        WalletAuthorization(
          id: 'auth-1',
          card: 'card-1',
          amount: 1000,
          currency: 'USD',
          capKind: 'cumulative',
          merchantScope: const ['stoneco.example'],
          fees: 'included',
          expires: now.add(const Duration(hours: 20)),
          status: 'active',
          spent: 0,
          reserved: 940,
          advisory: true,
          created: now.subtract(const Duration(hours: 4)),
        ),
      ],
      purchases: [
        WalletPurchase(
          id: 'buy-1',
          authorization: 'auth-1',
          merchant: 'stoneco.example',
          amount: 940,
          currency: 'USD',
          status: 'proposed',
          at: now.subtract(const Duration(minutes: 12)),
        ),
      ],
    );
  }

  final List<WalletCard> cards;
  final List<WalletAuthorization> authorizations;
  final List<WalletPurchase> purchases;

  WalletCard? cardOf(WalletAuthorization authorization) {
    for (final card in cards) {
      if (card.id == authorization.card) return card;
    }
    return null;
  }
}

class WalletCard {
  const WalletCard({
    required this.id,
    required this.label,
    this.network = '',
    this.last4 = '',
    this.expMonth = 0,
    this.expYear = 0,
    this.state = 'active',
    this.added,
    this.lastUsed,
  });

  factory WalletCard.fromWire(JsonMap wire) => WalletCard(
    id: asStringOr(wire['id'], ''),
    label: asStringOr(wire['label'], 'Card'),
    network: asStringOr(wire['network'], ''),
    last4: asStringOr(wire['last4'], ''),
    expMonth: asInt(wire['exp-month'] ?? wire['expMonth']) ?? 0,
    expYear: asInt(wire['exp-year'] ?? wire['expYear']) ?? 0,
    state: asStringOr(wire['state'], 'active'),
    added: parseTime(wire['added']),
    lastUsed: parseTime(wire['last-used'] ?? wire['lastUsed']),
  );

  final String id;
  final String label;
  final String network;
  final String last4;
  final int expMonth;
  final int expYear;
  final String state;
  final DateTime? added;
  final DateTime? lastUsed;

  String get expiryLabel => expMonth == 0 || expYear == 0
      ? ''
      : '${expMonth.toString().padLeft(2, '0')}/${expYear.toString().padLeft(4, '0')}';
  String get stateLabel => switch (state) {
    'active' => 'Active',
    'expired' => 'Expired',
    'revoked' => 'Revoked',
    _ => 'Unknown',
  };
}

class WalletAuthorization {
  const WalletAuthorization({
    required this.id,
    required this.card,
    required this.amount,
    this.currency = 'USD',
    this.capKind = 'cumulative',
    this.merchantScope = const [],
    this.fees = 'included',
    this.tax = 'included',
    this.shipping = 'included',
    this.expires,
    this.status = 'active',
    this.spent = 0,
    this.reserved = 0,
    this.advisory = true,
    this.created,
  });

  factory WalletAuthorization.fromWire(JsonMap wire) => WalletAuthorization(
    id: asStringOr(wire['id'], ''),
    card: asStringOr(wire['card'], ''),
    amount: asInt(wire['amount']) ?? 0,
    currency: asStringOr(wire['currency'], 'USD'),
    capKind: asStringOr(wire['cap-kind'] ?? wire['capKind'], 'cumulative'),
    merchantScope: [
      for (final merchant in asList(
        wire['merchant-scope'] ?? wire['merchantScope'],
      ))
        if (asString(merchant) != null) asString(merchant)!,
    ],
    fees: asStringOr(wire['fees'], 'included'),
    tax: asStringOr(wire['tax'], 'included'),
    shipping: asStringOr(wire['shipping'], 'included'),
    expires: parseTime(wire['expires']),
    status: asStringOr(wire['status'], 'active'),
    spent: asInt(wire['spent']) ?? 0,
    reserved: asInt(wire['reserved']) ?? 0,
    advisory: asBool(wire['advisory'], fallback: true),
    created: parseTime(wire['created']),
  );

  final String id;
  final String card;
  final int amount;
  final String currency;
  final String capKind;
  final List<String> merchantScope;
  final String fees;
  final String tax;
  final String shipping;
  final DateTime? expires;
  final String status;
  final int spent;
  final int reserved;
  final bool advisory;
  final DateTime? created;

  int get remaining => (amount - spent - reserved).clamp(0, amount);
  bool get perTransaction => capKind == 'per-transaction';
  bool get allIn => fees == 'included';

  bool expiredAt(DateTime now) => expires != null && !expires!.isAfter(now);

  String get statusLabel {
    if (status == 'active' && expiredAt(DateTime.now())) return 'Expired';
    return switch (status) {
      'active' => 'Active',
      'exhausted' => 'Exhausted',
      'expired' => 'Expired',
      'revoked' => 'Revoked',
      _ => 'Unknown',
    };
  }

  String get capLabel => perTransaction ? 'Per transaction' : 'Cumulative';

  String get scopeLabel =>
      merchantScope.isEmpty ? 'Any merchant' : merchantScope.join(', ');

  /// Why [charge] may not be made under this authorization, or null when the
  /// minimal model allows it.  [duplicate] is the caller's judgement that the
  /// same merchant and amount are already pending; it is a refusal, not a
  /// silent retry.  This is the model the broker must enforce; the UI never
  /// claims it is enforceable without a broker.
  String? refuse({
    required int charge,
    required String merchant,
    required String currency,
    required DateTime now,
    bool duplicate = false,
  }) {
    if (status != 'active') return 'Not active';
    if (expiredAt(now)) return 'Expired';
    if (charge <= 0) return 'No amount';
    if (currency != this.currency) return 'Currency';
    if (merchantScope.isNotEmpty &&
        !merchantScope.any(
          (scope) => scope.toLowerCase() == merchant.toLowerCase(),
        )) {
      return 'Merchant';
    }
    if (perTransaction && charge > amount) return 'Over cap';
    if (!perTransaction && spent + reserved + charge > amount) {
      return 'Over cap';
    }
    if (duplicate) return 'Duplicate';
    return null;
  }
}

class WalletPurchase {
  const WalletPurchase({
    required this.id,
    required this.authorization,
    required this.merchant,
    required this.amount,
    this.currency = 'USD',
    this.status = 'proposed',
    this.at,
  });

  factory WalletPurchase.fromWire(JsonMap wire) => WalletPurchase(
    id: asStringOr(wire['id'], ''),
    authorization: asStringOr(wire['authorization'], ''),
    merchant: asStringOr(wire['merchant'], ''),
    amount: asInt(wire['amount']) ?? 0,
    currency: asStringOr(wire['currency'], 'USD'),
    status: asStringOr(wire['status'], 'proposed'),
    at: parseTime(wire['at']),
  );

  final String id;
  final String authorization;
  final String merchant;
  final int amount;
  final String currency;
  final String status;
  final DateTime? at;

  bool get proposed => status == 'proposed';
  String get statusLabel => switch (status) {
    'proposed' => 'Proposed',
    'approved' => 'Approved',
    'declined' => 'Declined',
    'settled' => 'Settled',
    'duplicate' => 'Duplicate',
    _ => 'Unknown',
  };
}

/// A first-class resource's access: what the agent may do with it, not
/// whether the resource exists.
class AccessGrant {
  const AccessGrant({
    required this.kind,
    required this.label,
    this.scope = 'workspace',
    this.owner = 'user',
    this.state = 'active',
    this.availability = 'ready',
    this.access = 'none',
    this.detail = '',
    this.expires,
  });

  factory AccessGrant.fromWire(JsonMap wire) => AccessGrant(
    kind: asStringOr(wire['kind'], 'resource'),
    label: asStringOr(wire['label'], 'Resource'),
    scope: asStringOr(wire['scope'], 'workspace'),
    owner: asStringOr(wire['owner'], 'user'),
    state: asStringOr(wire['state'], 'active'),
    availability: asStringOr(wire['availability'], 'ready'),
    access: asStringOr(wire['access'], 'none'),
    detail: asStringOr(wire['detail'], ''),
    expires: parseTime(wire['expires']),
  );

  final String kind;
  final String label;
  final String scope;
  final String owner;
  final String state;
  final String availability;
  final String access;
  final String detail;
  final DateTime? expires;

  String get accessLabel => switch (access) {
    'allowed' => 'Allowed',
    'ask' => 'Ask',
    _ => 'None',
  };

  bool get revocable => access != 'none' && access != 'blocked';
}

class AuditEntry {
  const AuditEntry({
    required this.at,
    required this.action,
    required this.resource,
    this.actor = 'user',
    this.scope = 'workspace',
  });

  factory AuditEntry.fromWire(JsonMap wire) => AuditEntry(
    at: parseTime(wire['at']) ?? DateTime.now(),
    action: asStringOr(wire['action'], 'Changed'),
    resource: asStringOr(wire['resource'], 'Resource'),
    actor: asStringOr(wire['actor'], 'user'),
    scope: asStringOr(wire['scope'], 'workspace'),
  );

  final DateTime at;
  final String action;
  final String resource;
  final String actor;
  final String scope;
}

/// A harness credential: a declared secret from the built-in secrets
/// module, shown through secret-sandbox.  The label is what the agent asks
/// for; the fingerprint identifies the value without being one.
class CredentialResource {
  const CredentialResource({
    required this.label,
    this.fingerprint = '',
    this.usable = false,
    this.error,
    this.lastUsed,
  });

  factory CredentialResource.fromWire(JsonMap wire) => CredentialResource(
    label: asStringOr(wire['label'], 'Credential'),
    fingerprint: asStringOr(wire['fingerprint'], ''),
    usable: asBool(wire['usable']),
    error: asString(wire['error']),
    lastUsed: parseTime(wire['last-use'] ?? wire['lastUsed']),
  );

  final String label;
  final String fingerprint;
  final bool usable;
  final String? error;
  final DateTime? lastUsed;

  String get stateLabel => usable ? 'Locked run · ready' : 'Unavailable';
}

class CredentialsStatus {
  const CredentialsStatus({
    this.status = 'unavailable',
    this.mask = false,
    this.locked = false,
    this.why,
    this.count = 0,
  });

  factory CredentialsStatus.fromWire(JsonMap wire) => CredentialsStatus(
    status: asStringOr(wire['status'], 'unavailable'),
    mask: asBool(wire['mask']),
    locked: asBool(wire['locked']),
    why: asString(wire['why']),
    count: asInt(wire['count']) ?? 0,
  );

  final String status;
  final bool mask;
  final bool locked;
  final String? why;
  final int count;

  bool get ready => status == 'ready';
  String get label => ready
      ? 'Locked run · ready'
      : status == 'needs-approval'
      ? 'Needs approval'
      : 'Unavailable';
}

/// `3.2 MB`; the sizes a settings page shows, without a trailing `.0`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 10 || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
