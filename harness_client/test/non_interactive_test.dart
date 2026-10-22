import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/session.dart';

void main() {
  test('a session is interactive unless the harness says otherwise', () {
    expect(SessionSummary.fromWire({'id': 's'}).nonInteractive, isFalse);
    expect(
      SessionSummary.fromWire({'id': 's', 'non-interactive': true})
          .nonInteractive,
      isTrue,
    );
    expect(
      SessionSummary.fromWire({'id': 's', 'nonInteractive': true})
          .nonInteractive,
      isTrue,
    );
  });

  test('a new answer from the harness replaces the old one', () {
    final on = SessionSummary.fromWire({'id': 's', 'non-interactive': true});
    final off = on.merge(
      SessionSummary.fromWire({'id': 's', 'non-interactive': false}),
    );
    expect(off.nonInteractive, isFalse);
    expect(off.withNonInteractive(true).nonInteractive, isTrue);
  });
}
