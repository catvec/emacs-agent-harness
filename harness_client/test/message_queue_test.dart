// A message queued for a conversation's next turn while the agent works: the
// box that queues it, the strip that shows it, and sending, editing or
// deleting it again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/session.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/session_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/queued_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _session = 's1';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _connected({void Function(FakeHarness harness)? arrange}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  arrange?.call(harness);
  final app = AppController(settings: settings, connector: harness.connector);
  addTearDown(app.dispose);
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: HarnessScope(
        app: rig.app,
        settings: rig.settings,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HarnessTheme.material(Brightness.light),
          home: const SessionScreen(sessionId: _session),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Let a slow turn run out, and the reads it scheduled come and go, so that
/// no timer outlives the test.
Future<void> _rest(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  // The end of the turn schedules a read of the sessions, a moment later.
  await tester.pump(const Duration(milliseconds: 500));
}

Finder get _field => find.byKey(const Key('composer-field'));

/// What [of] finds inside the queue's strip.
Finder _inStrip(Finder strip, Finder of) =>
    find.descendant(of: strip, matching: of);

/// What the message box holds.
String _typed(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _field, matching: find.byType(EditableText)),
    )
    .controller
    .text;

/// Put a message in the queue of the harness the app talks to, as another
/// client would have.
void _seedQueue(FakeHarness harness, List<Map<String, Object?>> items) {
  harness.sessions[_session]!['queue'] = items;
}

Map<String, Object?> _item(String id, String text, {Object? from}) => {
  'id': id,
  'text': text,
  'attachments': <Object?>[],
  'ts': 1.0,
  'from': from,
};

/// Start a turn that runs long enough to queue another message into.
Future<void> _startSlowTurn(WidgetTester tester) async {
  await tester.enterText(_field, 'Take it slowly');
  await tester.pump();
  await tester.tap(find.byKey(const Key('composer-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

/// Queue [text] from the box, which must be offered while the agent works.
Future<void> _queueFromBox(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('composer-queue')));
  await _settle(tester, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a message queued while the agent works', () {
    testWidgets('leaves the box and waits above it', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = await _connected();
      await _pump(tester, rig);
      await _startSlowTurn(tester);

      expect(
        find.byKey(const Key('composer-queue')),
        findsOneWidget,
        reason: 'the box offers the queue while the turn runs',
      );
      expect(find.text('Message for the next turn'), findsOneWidget);
      expect(find.bySemanticsLabel('Queue message'), findsOneWidget);

      await _queueFromBox(tester, 'Also update the docs');

      expect(rig.harness.queuedMessages, [(_session, 'Also update the docs')]);
      final strip = find.byKey(const Key('session-queue'));
      expect(strip, findsOneWidget);
      expect(find.byType(QueuedMessages), findsOneWidget);
      expect(_inStrip(strip, find.text('Queue')), findsOneWidget);
      expect(_inStrip(strip, find.text('1')), findsOneWidget);
      expect(
        _inStrip(strip, find.text('Also update the docs')),
        findsOneWidget,
      );
      expect(_inStrip(strip, find.text('Queued')), findsOneWidget);
      expect(_inStrip(strip, find.text('Send all')), findsNothing);
      // The words went to the queue, not to the box.
      expect(_typed(tester), isEmpty);
      await _rest(tester);
      semantics.dispose();
    });

    testWidgets('sends every queued message, in the order they were added', (
      tester,
    ) async {
      final rig = await _connected();
      await _pump(tester, rig);
      await _startSlowTurn(tester);
      await _queueFromBox(tester, 'Also update the docs');
      await _queueFromBox(tester, 'And run the tests');

      final queue = rig.harness.queueOf(_session);
      expect(queue.map((item) => item['text']), [
        'Also update the docs',
        'And run the tests',
      ]);
      final strip = find.byKey(const Key('session-queue'));
      expect(_inStrip(strip, find.text('2')), findsOneWidget);
      expect(_inStrip(strip, find.text('Send all')), findsOneWidget);
      await _rest(tester);
    });
  });

  group('the strip of a conversation', () {
    testWidgets('sends one message now, the others staying queued', (
      tester,
    ) async {
      final rig = await _connected(
        arrange: (harness) => _seedQueue(harness, [
          _item('q-1', 'First queued'),
          _item('q-2', 'Second queued'),
        ]),
      );
      await _pump(tester, rig);
      expect(find.text('First queued'), findsOneWidget);
      expect(find.text('Second queued'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('queue-send-q-1')));
      await _settle(tester);

      expect(rig.harness.sentQueues.single.qids, ['q-1']);
      expect(rig.harness.sentQueues.single.text, 'First queued');
      expect(rig.harness.queueOf(_session).map((item) => item['text']), [
        'Second queued',
      ]);
      expect(find.text('Second queued'), findsOneWidget);
    });

    testWidgets('sends every message now with one button', (tester) async {
      final rig = await _connected(
        arrange: (harness) => _seedQueue(harness, [
          _item('q-1', 'First queued'),
          _item('q-2', 'Second queued'),
        ]),
      );
      await _pump(tester, rig);
      await tester.tap(find.byKey(const Key('queue-send-all')));
      await _settle(tester);

      expect(rig.harness.sentQueues.single.qids, isNull);
      expect(
        rig.harness.sentQueues.single.text,
        'First queued\n\nSecond queued',
      );
      expect(rig.harness.queueOf(_session), isEmpty);
      expect(find.byType(QueuedMessages), findsNothing);
    });

    testWidgets('takes a message back into the box to write it again', (
      tester,
    ) async {
      final rig = await _connected(
        arrange: (harness) =>
            _seedQueue(harness, [_item('q-1', 'Make it shorter')]),
      );
      await _pump(tester, rig);
      await tester.tap(find.byKey(const ValueKey('queue-edit-q-1')));
      await _settle(tester);

      expect(rig.harness.queueOf(_session), isEmpty);
      expect(find.byType(QueuedMessages), findsNothing);
      expect(_typed(tester), 'Make it shorter');
    });

    testWidgets('deletes a message the model never gets', (tester) async {
      final rig = await _connected(
        arrange: (harness) => _seedQueue(harness, [_item('q-1', 'Never mind')]),
      );
      await _pump(tester, rig);
      await tester.tap(find.byKey(const ValueKey('queue-remove-q-1')));
      await _settle(tester);

      expect(rig.harness.queueOf(_session), isEmpty);
      expect(find.byType(QueuedMessages), findsNothing);
    });

    testWidgets('shows what another client queued, and who sent it', (
      tester,
    ) async {
      final rig = await _connected();
      await _pump(tester, rig);
      expect(find.byType(QueuedMessages), findsNothing);

      rig.harness.announce('session/queue-changed', [
        _session,
        [
          _item(
            'q-9',
            'Rebase the branch',
            from: {'kind': 'system', 'source': 'merge queue'},
          ),
        ],
      ]);
      await _settle(tester);

      expect(find.text('Rebase the branch'), findsOneWidget);
      expect(find.text('Harness · merge queue · Queued'), findsOneWidget);
    });

    testWidgets('offers no edit of a message that has pictures', (
      tester,
    ) async {
      final rig = await _connected(
        arrange: (harness) => _seedQueue(harness, [
          {
            'id': 'q-1',
            'text': '',
            'attachments': [
              {'type': 'image', 'mimeType': 'image/png', 'data': 'aGk='},
            ],
          },
        ]),
      );
      await _pump(tester, rig);

      expect(find.text('(1 image)'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-edit-q-1')), findsNothing);
      expect(find.byKey(const ValueKey('queue-send-q-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue-remove-q-1')), findsOneWidget);
    });
  });

  group('the copy of the queue', () {
    testWidgets('is the named words, with no sentence among them', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final rig = await _connected(
        arrange: (harness) => _seedQueue(harness, [
          _item('q-1', 'First queued'),
          _item('q-2', 'Second queued'),
        ]),
      );
      await _pump(tester, rig);

      final strip = find.byKey(const Key('session-queue'));
      expect(_inStrip(strip, find.text('Queue')), findsOneWidget);
      expect(_inStrip(strip, find.text('2')), findsOneWidget);
      expect(_inStrip(strip, find.text('Queued')), findsNWidgets(2));
      expect(_inStrip(strip, find.text('Send all')), findsOneWidget);
      expect(_inStrip(strip, find.byTooltip('Send now')), findsNWidgets(2));
      expect(_inStrip(strip, find.byTooltip('Edit')), findsNWidgets(2));
      expect(_inStrip(strip, find.byTooltip('Delete')), findsNWidgets(2));
      expect(find.bySemanticsLabel('Queued messages, 2'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('a harness that cannot queue', () {
    testWidgets('leaves the box as it was, without a queue button', (
      tester,
    ) async {
      final rig = await _connected(
        arrange: (harness) => harness.methods.remove('session/queue'),
      );
      await _pump(tester, rig);
      await _startSlowTurn(tester);

      expect(find.byKey(const Key('composer-queue')), findsNothing);
      expect(find.text('The agent is working…'), findsOneWidget);
      expect(find.text('Message for the next turn'), findsNothing);
      await _rest(tester);
    });
  });

  group('a queue the harness refuses', () {
    testWidgets('says why, and puts the words back in the box', (tester) async {
      final rig = await _connected(
        arrange: (harness) => harness.queueError = 'The queue is full',
      );
      await _pump(tester, rig);
      await _startSlowTurn(tester);
      await _queueFromBox(tester, 'Also update the docs');

      expect(find.textContaining('The queue is full'), findsOneWidget);
      expect(find.byType(QueuedMessages), findsNothing);
      expect(_typed(tester), 'Also update the docs');
      await _rest(tester);
    });
  });

  test('a queue item reads its pictures, and says how many', () {
    final item = QueueItem.listFrom([
      {
        'id': 'q-1',
        'text': '',
        'attachments': [
          {'type': 'image', 'mimeType': 'image/png', 'data': 'aGk='},
          {'type': 'image', 'mimeType': 'image/jpeg', 'data': 'aGk='},
        ],
      },
    ]).single;
    expect(item.hasAttachments, isTrue);
    expect(item.images, 2);
    expect(item.displayText, '(2 images)');
  });
}
