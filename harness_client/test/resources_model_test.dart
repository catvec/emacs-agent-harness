import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/resources.dart';

void main() {
  test('the browser answer is metadata only', () {
    final resources = WorkspaceResources.fromWire({
      'workspace': 'w1',
      'status': 'ready',
      'metadata-only': true,
      'browser': {
        'profile': {
          'label': 'Home',
          'kind': 'Chromium',
          'bytes': 2048,
          'sites': 1,
        },
        'sites': [
          {
            'origin': 'https://stoneco.example',
            'cookies': 12,
            'storage-bytes': 3200,
            'cache-bytes': 6400,
            'permissions': 2,
            'auth': 'signed-in',
            'value': 'SESSION-SECRET',
          },
        ],
        'logins': [
          {
            'id': 'lg-1',
            'origin': 'https://stoneco.example',
            'username': 'j•••@example.com',
            'state': 'active',
            'password': 'hunter2',
            'cookie': 'SESSION-SECRET',
          },
        ],
        'totals': {'cookies': 12, 'bytes': 2048},
      },
    });
    final browser = resources.browser!;
    expect(resources.ready, isTrue);
    expect(resources.metadataOnly, isTrue);
    expect(browser.sites.single.cookies, 12);
    expect(browser.sites.single.host, 'stoneco.example');
    expect(browser.sites.single.authLabel, 'Signed in');
    expect(
      browser.sites.single.dataLabel,
      'Cookies 12 · Site data 3.1 KB · Cache 6.3 KB',
    );
    expect(browser.logins.single.username, 'j•••@example.com');
    expect(browser.logins.single.stateLabel, 'Active');
    expect(browser.cookies, 12);
    // The model has no field for the wire's value, password or cookie; the
    // widget test holds that nothing renders them.
  });

  test('credentials come from the secrets module as metadata', () {
    final resources = WorkspaceResources.fromWire({
      'workspace': 'w1',
      'status': 'ready',
      'metadata-only': true,
      'browser-status': 'unavailable',
      'wallet-status': 'unavailable',
      'credentials': [
        {
          'label': 'deploy-key',
          'fingerprint': '4f9c2a1b',
          'usable': true,
          'value': 'SECRET-VALUE',
          'last-use': '2026-11-06T18:00:00Z',
        },
        {
          'label': 'npm-token',
          'fingerprint': 'b81e7d20',
          'usable': false,
          'error': 'Masking off',
        },
      ],
      'credentials-status': {
        'status': 'ready',
        'mask': true,
        'locked': true,
        'count': 2,
      },
    });
    expect(resources.statusLabel, 'Partial');
    expect(resources.credentialsReady, isTrue);
    expect(resources.browserReady, isFalse);
    expect(resources.credentials.singleOrNull, isNull);
    expect(resources.credentials.first.label, 'deploy-key');
    expect(resources.credentials.first.fingerprint, '4f9c2a1b');
    expect(resources.credentials.first.usable, isTrue);
    expect(resources.credentials.last.usable, isFalse);
    expect(resources.credentials.last.error, 'Masking off');
    expect(resources.credentialsStatus!.count, 2);
    // The wire's value is not a field of the model; the widget test holds
    // that it is never rendered.
  });

  test('an unavailable answer still says what is missing', () {
    final resources = WorkspaceResources.unavailable('w1', 'box-tools-missing');
    expect(resources.ready, isFalse);
    expect(resources.blocked, isTrue);
    expect(resources.statusLabel, 'Unavailable');
    expect(resources.reasonLabel, 'Computer tools');
    expect(
      WorkspaceResources.unavailable('w1', 'box-not-running').reasonLabel,
      'Computer off',
    );
    expect(
      WorkspaceResources.unavailable('w1', 'wallet-unavailable').reasonLabel,
      'Wallet provider',
    );
  });

  test('a cumulative authorization counts spent and reserved', () {
    final authorization = WalletAuthorization(
      id: 'a',
      card: 'c',
      amount: 1000,
      spent: 200,
      reserved: 300,
      merchantScope: const ['stoneco.example'],
    );
    expect(authorization.remaining, 500);
    expect(
      authorization.refuse(
        charge: 500,
        merchant: 'stoneco.example',
        currency: 'USD',
        now: DateTime.now(),
      ),
      isNull,
    );
    expect(
      authorization.refuse(
        charge: 501,
        merchant: 'stoneco.example',
        currency: 'USD',
        now: DateTime.now(),
      ),
      'Over cap',
    );
  });

  test('a per-transaction authorization does not hide its kind', () {
    final authorization = WalletAuthorization(
      id: 'a',
      card: 'c',
      amount: 1000,
      capKind: 'per-transaction',
    );
    expect(authorization.capLabel, 'Per transaction');
    expect(
      authorization.refuse(
        charge: 1000,
        merchant: 'x',
        currency: 'USD',
        now: DateTime.now(),
      ),
      isNull,
    );
    expect(
      authorization.refuse(
        charge: 1001,
        merchant: 'x',
        currency: 'USD',
        now: DateTime.now(),
      ),
      'Over cap',
    );
  });

  test('the minimal model refuses what a \$10 authorization must refuse', () {
    final now = DateTime.now();
    final base = WalletAuthorization(
      id: 'a',
      card: 'c',
      amount: 1000,
      merchantScope: const ['stoneco.example'],
      expires: now.add(const Duration(hours: 1)),
    );
    expect(
      base.refuse(
        charge: 0,
        merchant: 'stoneco.example',
        currency: 'USD',
        now: now,
      ),
      'No amount',
    );
    expect(
      base.refuse(
        charge: 900,
        merchant: 'evil.example',
        currency: 'USD',
        now: now,
      ),
      'Merchant',
    );
    expect(
      base.refuse(
        charge: 900,
        merchant: 'stoneco.example',
        currency: 'EUR',
        now: now,
      ),
      'Currency',
    );
    expect(
      base.refuse(
        charge: 900,
        merchant: 'stoneco.example',
        currency: 'USD',
        now: now,
        duplicate: true,
      ),
      'Duplicate',
    );
    final expired = WalletAuthorization(
      id: 'a',
      card: 'c',
      amount: 1000,
      status: 'expired',
    );
    expect(
      expired.refuse(charge: 100, merchant: 'x', currency: 'USD', now: now),
      'Not active',
    );
    final due = WalletAuthorization(
      id: 'a',
      card: 'c',
      amount: 1000,
      expires: now.subtract(const Duration(seconds: 1)),
    );
    expect(
      due.refuse(charge: 100, merchant: 'x', currency: 'USD', now: now),
      'Expired',
    );
    expect(due.statusLabel, 'Expired');
  });

  test('the wallet answer carries cards as references', () {
    final resources = WorkspaceResources.fromWire({
      'workspace': 'w1',
      'status': 'ready',
      'wallet': {
        'cards': [
          {
            'id': 'card-1',
            'label': 'Visa •••• 4242',
            'network': 'Visa',
            'last4': '4242',
            'exp-month': 9,
            'exp-year': 2028,
            'state': 'active',
            'pan': '4242424242424242',
            'cvv': '123',
          },
        ],
        'authorizations': [
          {
            'id': 'auth-1',
            'card': 'card-1',
            'amount': 1000,
            'currency': 'USD',
            'cap-kind': 'cumulative',
            'merchant-scope': ['stoneco.example'],
            'fees': 'included',
            'status': 'active',
            'spent': 0,
            'reserved': 940,
            'advisory': true,
          },
        ],
        'purchases': [
          {
            'id': 'buy-1',
            'authorization': 'auth-1',
            'merchant': 'stoneco.example',
            'amount': 940,
            'currency': 'USD',
            'status': 'proposed',
          },
        ],
      },
    });
    final wallet = resources.wallet!;
    final card = wallet.cards.single;
    expect(card.label, 'Visa •••• 4242');
    expect(card.last4, '4242');
    expect(card.expiryLabel, '09/2028');
    final authorization = wallet.authorizations.single;
    expect(authorization.remaining, 60);
    expect(authorization.advisory, isTrue);
    expect(wallet.purchases.single.proposed, isTrue);
    expect(wallet.cardOf(authorization)!.id, 'card-1');
  });

  test('sizes read as a person writes them', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1 KB');
    expect(formatBytes(3200), '3.1 KB');
    expect(formatBytes(412 * 1024 * 1024), '412 MB');
  });
}
