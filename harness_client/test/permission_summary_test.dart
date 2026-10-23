// A permission request the person is asked about carries a short summary of
// its call, written by a cheap model while the person reads it: the harness
// asks at once and says, in the request, that a summary is on its way; the
// summary comes as `session/pending-updated`, or the news that there will be
// none.  The card shows the placeholder, then the summary marked as a model's
// words, or nothing at all when there is none: the request is answered as it
// always was, and nothing in the app reads the summary but the person.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/interaction.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/tool_showcase.dart';
import 'support/transcript_log.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Session `s-live` of a harness that is working on something, open on a
/// phone.
Future<FakeHarness> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final log = TranscriptLog()
    ..user('Run the build')
    ..call('c1', 'bash', title: 'Bash: rm -rf build && make', result: false);
  harness.sessions['s-live'] = {
    ...toolShowcaseSession(),
    'id': 's-live',
    'name': 'Run the build',
    'status': 'running',
  };
  harness.nodes['s-live'] = [...log.nodes];
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
  await tester.pump();
  await _settle(tester);
  await tester.tap(find.text('Run the build'));
  await _settle(tester, 30);
  return harness;
}

final _note = find.byKey(const ValueKey('permission-summary'));

const _written = 'Deletes the build directory, then rebuilds the project.';

void main() {
  group('the request', () {
    InteractionRequest request(Map<String, Object?> harness) =>
        InteractionRequest(
          method: 'session/request_permission',
          sessionId: 's',
          params: {
            'toolCall': {'toolCallId': 'c1', 'title': 'Bash: make'},
            '_harness': {'pendingId': 'p1', ...harness},
          },
        );

    test('says a summary is on its way, or carries the one written', () {
      expect(request({}).summarizing, isFalse);
      expect(request({}).summary, isNull);

      final waiting = request({'summarizing': true});
      expect(waiting.summarizing, isTrue);
      expect(waiting.summary, isNull);

      final written = request({
        'summary': '  $_written\n',
        'summaryModel': 'claude:claude-haiku-4-5',
        'summarizing': true,
      });
      // A summary is there: nothing is on its way any more.
      expect(written.summary, _written);
      expect(written.summaryModel, 'claude:claude-haiku-4-5');
      expect(written.summarizing, isFalse);

      // A blank one is none.
      expect(request({'summary': '  '}).summary, isNull);
    });

    test('a question has none', () {
      final question = InteractionRequest(
        method: '_harness/ask_user',
        sessionId: 's',
        params: {
          'question': 'Which?',
          '_harness': {'summary': 'x', 'summarizing': true},
        },
      );
      expect(question.summary, isNull);
      expect(question.summarizing, isFalse);
      expect(question.learnSummary({'summary': 'x'}), isFalse);
      expect(question.summary, isNull);
    });

    test('learns the summary, or that there will be none', () {
      final waiting = request({'summarizing': true});
      expect(
        waiting.learnSummary({
          'summary': _written,
          'summary-model': 'claude:haiku',
          'summarizing': null,
        }),
        isTrue,
      );
      expect(waiting.summary, _written);
      expect(waiting.summaryModel, 'claude:haiku');
      expect(waiting.summarizing, isFalse);
      // The same news again changes nothing.
      expect(
        waiting.learnSummary({'summary': _written, 'summarizing': false}),
        isFalse,
      );

      final none = request({'summarizing': true});
      expect(none.learnSummary({'summarizing': null}), isTrue);
      expect(none.summary, isNull);
      expect(none.summarizing, isFalse);

      // A summary stays when late news says a summary is on its way.
      expect(waiting.learnSummary({'summarizing': true}), isFalse);
      expect(waiting.summary, _written);
      expect(waiting.summarizing, isFalse);
    });
  });

  testWidgets('the card says it is summarizing, then shows the summary as a '
      "model's words", (tester) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'summarizing': true},
    );
    await _settle(tester);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(_note, findsOneWidget);
    expect(find.text('Model summary'), findsOneWidget);
    expect(find.text('Summarizing…'), findsOneWidget);
    expect(find.text(_written), findsNothing);
    // It can be answered as ever, with the placeholder there.
    expect(find.text('Allow'), findsOneWidget);

    harness.pendingUpdated('s-live', 'perm-c1', {
      'summary': _written,
      'summary-model': 'claude:claude-haiku-4-5',
      'summarizing': null,
    });
    await _settle(tester);
    expect(find.text(_written), findsOneWidget);
    expect(find.text('Summarizing…'), findsNothing);
    // Marked as written by a model, and that it is advice; which model is
    // said to a screen reader.
    expect(find.text('Model summary'), findsOneWidget);
    expect(find.text('advice, can be wrong'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('written by claude:claude-haiku-4-5')),
      findsOneWidget,
    );
    // The call itself is still what is shown above it.
    expect(find.textContaining('rm -rf build && make'), findsWidgets);

    await tester.tap(find.text('Allow'));
    await _settle(tester, 6);
    expect((await answer)['outcome'], containsPair('optionId', 'allow-once'));
    expect(_note, findsNothing);
  });

  testWidgets('a model that gave none leaves the card as it was', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'summarizing': true},
    );
    await _settle(tester);
    expect(find.text('Summarizing…'), findsOneWidget);

    harness.pendingUpdated('s-live', 'perm-c1', {'summarizing': null});
    await _settle(tester);
    expect(_note, findsNothing);
    expect(find.text('Summarizing…'), findsNothing);
    expect(find.text('Model summary'), findsNothing);

    await tester.tap(find.text('Deny'));
    await _settle(tester, 6);
    expect((await answer)['outcome'], containsPair('optionId', 'deny-once'));
  });

  testWidgets('a request that comes with its summary shows it at once', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'summary': _written, 'summaryModel': 'claude:haiku'},
    );
    await _settle(tester);
    expect(find.text(_written), findsOneWidget);
    expect(find.text('Summarizing…'), findsNothing);
    await tester.tap(find.text('Deny'));
    await _settle(tester, 6);
    await answer;
  });

  testWidgets('what the harness said of a request before it arrived is not '
      'lost', (tester) async {
    final harness = await _open(tester);
    // The news of the summary comes first (a request read from the harness
    // is as old as the read); the request, made before it, says it is on
    // its way.
    harness.pendingUpdated('s-live', 'perm-c1', {
      'summary': _written,
      'summary-model': 'claude:haiku',
      'summarizing': null,
    });
    await _settle(tester, 4);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'summarizing': true},
    );
    await _settle(tester);
    expect(find.text(_written), findsOneWidget);
    expect(find.text('Summarizing…'), findsNothing);
    await tester.tap(find.text('Deny'));
    await _settle(tester, 6);
    await answer;
  });

  testWidgets('a request the harness does not summarize has no note', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
    );
    await _settle(tester);
    expect(find.text('PERMISSION'), findsOneWidget);
    expect(_note, findsNothing);
    await tester.tap(find.text('Allow'));
    await _settle(tester, 6);
    await answer;
  });
}
