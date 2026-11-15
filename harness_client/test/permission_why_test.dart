// A permission request says why the person is asked: a safety judgment on
// the call, no verdict from the judge, the mode, a directory, or a
// confirmation only the person gives.  The harness sends it in
// `_harness.why` with a code, a label, an unsafe flag and the words behind
// it; the card draws it above the call, in the harness's words, amber and
// warning-iconed when it is a judgment and neutral when it is not.  A
// request the harness sent none for draws exactly as it always did.
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

final _note = find.byKey(const ValueKey('permission-why'));

const _unsafe = {
  'code': 'judge-deny',
  'label': 'Safety check · denied by the permission judge',
  'unsafe': true,
  'detail': 'it force pushes to the shared remote',
};

const _mode = {'code': 'mode', 'label': 'Permission mode'};

void main() {
  group('the request', () {
    InteractionRequest request(Map<String, Object?> why) => InteractionRequest(
      method: 'session/request_permission',
      sessionId: 's',
      params: {
        'toolCall': {'toolCallId': 'c1', 'title': 'Bash: make'},
        '_harness': {'pendingId': 'p1', 'why': why},
      },
    );

    test('carries the reason the harness sent', () {
      final unsafe = request(_unsafe).why!;
      expect(unsafe.code, 'judge-deny');
      expect(unsafe.label, 'Safety check · denied by the permission judge');
      expect(unsafe.unsafe, isTrue);
      expect(unsafe.detail, 'it force pushes to the shared remote');
    });

    test('a reason that is no judgment is not unsafe', () {
      final mode = request(_mode).why!;
      expect(mode.code, 'mode');
      expect(mode.label, 'Permission mode');
      expect(mode.unsafe, isFalse);
      expect(mode.detail, isNull);
      // The wire's false is a false, whatever spelling it comes in.
      expect(request({..._mode, 'unsafe': false}).why!.unsafe, isFalse);
      // A code the app does not know still shows the harness's words, and
      // is no judgment: only an explicit true is unsafe.
      expect(request({'code': 'future', 'label': 'Something'}).why!.unsafe, isFalse);
    });

    test('no reason, or a blank one, is none', () {
      expect(request(const {}).why, isNull);
      expect(request({'code': 'mode', 'label': '  '}).why, isNull);
      expect(request({'code': 'mode', 'detail': 'x'}).why, isNull);
      // A blank detail is no detail, rather than an empty line.
      expect(request({'label': 'Permission mode', 'detail': '  '}).why!.detail, isNull);
    });

    test('a question has none', () {
      final question = InteractionRequest(
        method: '_harness/ask_user',
        sessionId: 's',
        params: {
          'question': 'Which?',
          '_harness': {'why': _unsafe},
        },
      );
      expect(question.why, isNull);
    });
  });
  testWidgets('a safety judgment is drawn as one, above the call', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'why': _unsafe},
    );
    await _settle(tester);
    expect(_note, findsOneWidget);
    expect(find.text('Why'), findsOneWidget);
    expect(
      find.text('Safety check · denied by the permission judge'),
      findsOneWidget,
    );
    expect(find.text('it force pushes to the shared remote'), findsOneWidget);
    // Above the call, and above the answers.
    final whyY = tester.getTopLeft(_note).dy;
    final inputY = tester.getTopLeft(find.textContaining('rm -rf build && make').last).dy;
    final allowY = tester.getTopLeft(find.text('Allow')).dy;
    expect(whyY, lessThan(inputY));
    expect(inputY, lessThan(allowY));
    // The call is still answered as it always was.
    expect(find.text('Allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await _settle(tester, 6);
    expect((await answer)['outcome'], containsPair('optionId', 'allow-once'));
  });

  testWidgets('a reason that is no judgment says so, and is not amber', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {
        'why': {
          'code': 'judge-timeout',
          'label': 'No safety verdict · judge timeout',
          'unsafe': false,
          'detail': 'it took longer than 30s',
        },
      },
    );
    await _settle(tester);
    expect(_note, findsOneWidget);
    expect(find.text('No safety verdict · judge timeout'), findsOneWidget);
    expect(find.text('it took longer than 30s'), findsOneWidget);
    // The info icon, not the warning one: nothing was judged.
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    await tester.tap(find.text('Deny'));
    await _settle(tester, 6);
    await answer;
  });

  testWidgets('the unsafe reason wears the warning, and a screen reader '
      'hears it', (tester) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
      extra: {'why': _unsafe},
    );
    await _settle(tester);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    expect(
      find.bySemanticsLabel(
        RegExp('Why · Safety check · denied by the permission judge · unsafe · your decision'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Deny'));
    await _settle(tester, 6);
    await answer;
  });

  testWidgets('a request with no reason is drawn as it always was', (
    tester,
  ) async {
    final harness = await _open(tester);
    final answer = harness.askPermission(
      's-live',
      callId: 'c1',
      title: 'Bash: rm -rf build && make',
    );
    await _settle(tester);
    expect(_note, findsNothing);
    expect(find.text('Why'), findsNothing);
    expect(find.text('PERMISSION'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await _settle(tester, 6);
    await answer;
  });
}
