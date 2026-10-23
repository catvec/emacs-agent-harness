// The app shows a question, or a request for permission, only while the
// harness still waits for it.  The harness stops waiting when somebody
// answers (in Emacs, on another device, by a rule), when the turn that asked
// ends (it was cancelled, or failed), and when the session is closed; and the
// phone is not always there to hear it: it sleeps, it changes network, and
// the events it misses are never sent again.  What it shows for a session
// that nobody has open is whatever it last heard, so these tests make the
// harness stop waiting while the phone is out of reach, or without a word,
// and ask what the app shows once it has read the harness again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/session.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/session_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/adaptive_widgets.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

/// An app connected to a fake harness, which gets its connection back a few
/// milliseconds after it is lost.
Future<_Rig> _rig() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness();
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 5)],
    handshakeTimeout: const Duration(seconds: 2),
    probeTimeout: const Duration(milliseconds: 150),
  );
  await app.connect('ws://memory/acp');
  return _Rig(settings, harness, app);
}

/// Wait, in short steps, until [done].
Future<void> _until(bool Function() done, {String? what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${what ?? 'the app'}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

/// Wait until the app has stopped asking the harness for things: what it
/// does on its own after a connection is back (reading its lists again, say)
/// is done.
Future<void> _quiet(FakeHarness harness) async {
  var seen = -1;
  var steady = 0;
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (steady < 12) {
    if (DateTime.now().isAfter(deadline)) fail('The app never stopped asking.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final now = harness.requests.length;
    steady = now == seen ? steady + 1 : 0;
    seen = now;
  }
}

/// The connection is lost and stays out, with the app trying to get it back.
/// Returns what lets the harness be reached again.
Future<void Function()> _outage(_Rig rig) async {
  rig.harness.refuseConnects = 1000000;
  await rig.harness.dropConnection('The connection dropped.');
  await _until(
    () => rig.app.phase == ConnectionPhase.reconnecting,
    what: 'the app to notice the connection was lost',
  );
  return () => rig.harness.refuseConnects = 0;
}

/// The connection is back, and the app has read what it reads again.
Future<void> _reconnected(_Rig rig, {required int connects}) async {
  await _until(
    () => rig.app.isConnected && rig.harness.connects == connects,
    what: 'the connection',
  );
  await _quiet(rig.harness);
}

/// The harness holds a question as pending on session `s1`, which the person
/// opened and left again: the app keeps the conversation's controller, with
/// the question recovered in it.
Future<SessionController> _questionHeld(_Rig rig) async {
  rig.harness.leavePendingQuestion(
    's1',
    question: 'Which database?',
    options: ['sqlite', 'postgres'],
    requestId: 'q-held',
    announce: true,
  );
  final controller = rig.app.openSession('s1');
  await _until(
    () => controller.interactions.isNotEmpty,
    what: 'the question to be shown',
  );
  rig.app.closeSession();
  expect(rig.app.needsAttention('s1'), isTrue);
  return controller;
}

/// The harness holds the permission request `p-s2` of the seeded session
/// `s2` as pending, and the person opened that conversation and left again.
Future<SessionController> _permissionHeld(_Rig rig) async {
  final controller = rig.app.openSession('s2');
  await _until(
    () => controller.interactions.isNotEmpty,
    what: 'the permission request to be shown',
  );
  rig.app.closeSession();
  expect(rig.app.needsAttention('s2'), isTrue);
  return controller;
}

/// What the harness holds of session [sid] when nothing is waited for: the
/// state the session is in once its question was answered, its turn ended or
/// it was closed.  No event is sent.
void _nothingPending(FakeHarness harness, String sid, String status) {
  final session = harness.sessions[sid]!;
  session['pending'] = <Map<String, Object?>>[];
  session['status'] = status;
  session['updated'] = DateTime.now().millisecondsSinceEpoch / 1000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a request the harness stopped waiting for while the phone was out', () {
    // The three ways it stops: somebody answers, the turn that asked ends,
    // the session is closed.  Each leaves the session in a state of its own.
    const endings = <(String, String)>[
      ('was answered in Emacs', 'running'),
      ('belonged to a turn that ended', 'idle'),
      ('belonged to a session that was closed', 'inactive'),
    ];

    for (final (what, status) in endings) {
      test('a question that $what is gone when the connection is back', () async {
        final rig = await _rig();
        addTearDown(rig.app.dispose);
        final controller = await _questionHeld(rig);
        final back = await _outage(rig);
        // Nobody can tell the phone.
        _nothingPending(rig.harness, 's1', status);
        back();
        await _reconnected(rig, connects: 2);

        expect(rig.app.needsAttention('s1'), isFalse);
        expect(controller.interactions, isEmpty);
        expect(rig.app.summaryFor('s1')!.status, status);
        expect(rig.app.summaryFor('s1')!.isBlocked, isFalse);
        expect(rig.app.attentionCount, 0);
      });

      test('a permission request that $what is gone too', () async {
        final rig = await _rig();
        addTearDown(rig.app.dispose);
        final controller = await _permissionHeld(rig);
        final back = await _outage(rig);
        _nothingPending(rig.harness, 's2', status);
        back();
        await _reconnected(rig, connects: 2);

        expect(rig.app.needsAttention('s2'), isFalse);
        expect(controller.interactions, isEmpty);
        expect(rig.app.summaryFor('s2')!.isBlocked, isFalse);
        expect(rig.app.attentionCount, 0);
      });
    }

    test('only the one the harness stopped waiting for goes', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which port?',
        options: ['80', '8080'],
        requestId: 'q-second',
        announce: true,
      );
      await _until(
        () => controller.interactions.length == 2,
        what: 'the second question',
      );
      final back = await _outage(rig);
      rig.harness.sessions['s1']!['pending'] = [
        for (final item
            in rig.harness.sessions['s1']!['pending']! as List<Object?>)
          if ((item! as Map)['id'] == 'q-second') item,
      ];
      back();
      await _reconnected(rig, connects: 2);

      expect(controller.interactions.map((r) => r.harnessId), ['q-second']);
      expect(rig.app.needsAttention('s1'), isTrue);
    });

    test('a request the harness still holds stays', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      final back = await _outage(rig);
      back();
      await _reconnected(rig, connects: 2);

      expect(rig.app.needsAttention('s1'), isTrue);
      expect(controller.interactions.map((r) => r.harnessId), ['q-held']);
      expect(rig.app.summaryFor('s1')!.isBlocked, isTrue);
    });

    test('a request that came while the phone was out is waited on', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = rig.app.openSession('s1');
      await _until(() => !controller.loading, what: 'the conversation');
      rig.app.closeSession();
      expect(rig.app.needsAttention('s1'), isFalse);
      final back = await _outage(rig);
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-late',
      );
      back();
      await _reconnected(rig, connects: 2);

      expect(rig.app.needsAttention('s1'), isTrue);
    });
  });

  group('a request the harness stopped waiting for, and said nothing of', () {
    test('goes when the sessions are read again', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      // Answered somewhere else, and the event never reached the phone.
      _nothingPending(rig.harness, 's1', 'running');
      expect(rig.app.needsAttention('s1'), isTrue, reason: 'it was not told');

      await rig.app.refreshSessions();
      await _quiet(rig.harness);

      expect(rig.app.needsAttention('s1'), isFalse);
      expect(controller.interactions, isEmpty);
      expect(rig.app.summaryFor('s1')!.status, 'running');
    });

    test('goes when the harness sends the record of the session', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      _nothingPending(rig.harness, 's1', 'idle');

      // Whatever changes a session, the harness sends its record as it stands.
      await rig.app.harness!.setMode('s1', 'accept-edits');
      await _quiet(rig.harness);

      expect(rig.app.summaryFor('s1')!.status, 'idle');
      expect(rig.app.summaryFor('s1')!.pending, isEmpty);
      expect(controller.interactions, isEmpty);
      expect(rig.app.needsAttention('s1'), isFalse);
    });

    test('goes when the conversation is read again', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      _nothingPending(rig.harness, 's1', 'idle');

      await controller.refreshInfo();

      expect(controller.interactions, isEmpty);
      expect(controller.needsAttention, isFalse);
    });

    test('is not brought back by a listing older than the conversation', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      final controller = await _questionHeld(rig);
      _nothingPending(rig.harness, 's1', 'idle');
      await controller.refreshInfo();
      expect(controller.needsAttention, isFalse);

      // The listing was asked for before the harness changed the session,
      // and arrives after the conversation read it: it says what was true.
      final session = rig.harness.sessions['s1']!;
      session['status'] = 'blocked';
      session['updated'] =
          DateTime.now()
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch /
          1000;
      await rig.app.refreshSessions();
      await _quiet(rig.harness);

      expect(controller.summary!.status, 'idle');
      expect(rig.app.needsAttention('s1'), isFalse);
    });

    test('is not counted for a session the harness no longer lists', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      await _questionHeld(rig);
      expect(rig.app.attentionCount, 1);
      // Deleted while the phone was away.
      rig.harness.sessions.remove('s1');

      await rig.app.refreshSessions();
      await _quiet(rig.harness);

      expect(rig.app.sessions.map((s) => s.id), isNot(contains('s1')));
      expect(rig.app.attentionCount, 0);
    });

    test('goes from a conversation that is open, too', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      rig.harness.leavePendingQuestion(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-open',
      );
      final controller = rig.app.openSession('s1');
      await _until(
        () => controller.interactions.isNotEmpty,
        what: 'the question to be shown',
      );
      _nothingPending(rig.harness, 's1', 'running');

      await rig.app.refreshSessions();
      await _quiet(rig.harness);

      expect(rig.app.activeSession, same(controller));
      expect(controller.currentInteraction, isNull);
    });
  });

  group('a session that is closed', () {
    test('has no request the app waits to be answered, whatever the harness '
        'lists on it', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      // `s4` is inactive.  A harness that closed it with a question
      // pending (it used to) still lists the question.
      rig.harness.leavePendingQuestion(
        's4',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-left',
      );
      rig.harness.sessions['s4']!['status'] = 'inactive';
      await rig.app.refreshSessions();

      final controller = rig.app.openSession('s4');
      await _until(() => !controller.loading, what: 'the conversation');
      await _quiet(rig.harness);

      expect(controller.interactions, isEmpty);
      expect(rig.app.needsAttention('s4'), isFalse);
      expect(rig.app.attentionCount, 0);
    });
  });

  group('the record of a session', () {
    test('is replaced by a newer one, and kept where it says nothing', () {
      const old = SessionSummary(
        id: 's',
        title: 'Old name',
        status: 'blocked',
        model: 'claude:one',
        pending: [PendingRequest(id: 'p', kind: 'question')],
        extra: {'pending': [], 'name': 'Old name'},
      );
      final newer = SessionSummary.fromWire({
        'id': 's',
        'name': 'New name',
        'status': 'idle',
        'pending': <Object?>[],
      });
      final merged = old.merge(newer);
      expect(merged.title, 'New name');
      expect(merged.status, 'idle');
      // It says nothing of the model: the old one stays.
      expect(merged.model, 'claude:one');
      // It says there is nothing pending: nothing is.
      expect(merged.pending, isEmpty);
    });

    test('is not made inactive by a newer one that says nothing of its state', () {
      final old = SessionSummary.fromWire({'id': 's', 'status': 'blocked'});
      // `fromWire` reads a missing status as `inactive`.
      final partial = SessionSummary.fromWire({'id': 's', 'name': 'Renamed'});
      expect(partial.status, 'inactive');
      final merged = old.merge(partial);
      expect(merged.status, 'blocked');
      expect(merged.title, 'Renamed');
    });

    test('keeps what it was told of when the newer one does not say', () {
      final old = SessionSummary.fromWire({
        'id': 's',
        'status': 'blocked',
        'pending': [
          {'id': 'p', 'kind': 'question'},
        ],
        'todos': [
          {'id': 't', 'text': 'Do it', 'status': 'pending'},
        ],
      });
      // A plain ACP listing says nothing of the pending requests or todos.
      final newer = SessionSummary.fromAcpInfo({
        'sessionId': 's',
        'title': 'A title',
        '_meta': {'status': 'blocked'},
      });
      final merged = old.merge(newer);
      expect(merged.pending.map((p) => p.id), ['p']);
      expect(merged.todos.map((t) => t.id), ['t']);
      expect(merged.title, 'A title');
    });
  });

  group('the sessions list', () {
    testWidgets('stops saying a session needs you once it does not', (
      tester,
    ) async {
      final rig = await _rig();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      // The person opened the session that waits for a permission, and left.
      rig.app.openSession('s2');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      rig.app.closeSession();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('NEEDS YOU'), findsOneWidget);

      // It was decided in Emacs while the phone was away.
      rig.harness.refuseConnects = 1000000;
      await rig.harness.dropConnection('The connection dropped.');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(rig.app.phase, ConnectionPhase.reconnecting);
      _nothingPending(rig.harness, 's2', 'idle');
      rig.harness.refuseConnects = 0;
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      expect(rig.app.phase, ConnectionPhase.connected);
      expect(find.text('NEEDS YOU'), findsNothing);
      expect(rig.app.attentionCount, 0);
      expect(find.byType(HarnessNotice), findsNothing);
    });
  });

  group('the notice that a session needs an answer', () {
    test('is no banner the person has to close by hand', () async {
      final rig = await _rig();
      addTearDown(rig.app.dispose);
      // A question the harness asks the app, of a conversation nobody has
      // open.
      final reply = rig.harness.askUser(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-away',
      );
      await _until(() => rig.app.needsAttention('s1'), what: 'the question');
      expect(rig.app.attentionCount, 1);
      // It used to be said once, as an error to dismiss, which nothing took
      // back when the question went.
      expect(rig.app.lastActionError, isNull);

      rig.harness.answerElsewhere('s1', 'q-away', 'sqlite');
      await _until(
        () => !rig.app.needsAttention('s1'),
        what: 'the question to go',
      );
      expect(rig.app.attentionCount, 0);
      expect(rig.app.lastActionError, isNull);
      expect(await reply, {'answer': ''});
    });

    testWidgets('is on the page for as long as the session waits, and no longer', (
      tester,
    ) async {
      final rig = await _rig();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessApp(settings: rig.settings, appController: rig.app),
      );
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      await tester.tap(find.text('Settings'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.byType(HarnessNotice), findsNothing);

      final reply = rig.harness.askUser(
        's1',
        question: 'Which database?',
        options: ['sqlite', 'postgres'],
        requestId: 'q-away',
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.text('One session needs your answer'), findsOneWidget);
      expect(find.byType(HarnessErrorBanner), findsNothing);

      // Answered in Emacs: nothing is left on the page that says otherwise.
      rig.harness.answerElsewhere('s1', 'q-away', 'sqlite');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.byType(HarnessNotice), findsNothing);
      expect(find.byType(HarnessErrorBanner), findsNothing);
      expect(await reply, {'answer': ''});
    });
  });
}
