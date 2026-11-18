// Going back into a harness, stage by stage: the real `AppController`, a
// scripted harness whose stages take the time a phone's network gives
// them, and what a person is shown meanwhile.
//
//   flutter test test/resume_latency_test.dart
//
// It prints, as `BENCH resume` lines, the stage each case went through
// and how long it took: a cold resume (a launch), a foreground resume
// of a connection that still answers, and one of a connection that died
// without a word (a phone that was asleep, a network that changed),
// which is what a person sees as "resuming".  It holds the app to
// bounds: the stage is named and its age ticks, a dead socket is found
// in the time of the probe, and a connect that never completes is given
// up on.  The content is synthetic: no real transcript and no real
// device is read, and nothing connects to a harness on the network.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/ui/widgets/connection_stage.dart';
import 'package:harness_client/src/acp/acp_transport.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

const _address = 'ws://memory/acp';
const _token = 'hs1_device';

class _Rig {
  _Rig(this.harness, this.app);
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _launch({
  required Duration connect,
  required Duration initialize,
  required Duration answer,
}) async {
  SharedPreferences.setMockInitialValues({'address': _address, 'token': _token});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(signIn: true, knownSecrets: {_token})
    ..connectDelay = connect
    ..initializeDelay = initialize
    ..answerDelay = answer;
  final app = AppController(
    settings: settings,
    connector: harness.connector,
    reconnectDelays: const [Duration(milliseconds: 1)],
  );
  return _Rig(harness, app);
}

/// What a person sees change, and when: the phase, and the stage the app says
/// it is in.  `at` is milliseconds since the run began.
typedef _Sighting = ({int at, String phase, String? stage});

class _Watch {
  _Watch(this.app);
  final AppController app;
  final Stopwatch started = Stopwatch()..start();
  final List<_Sighting> sightings = [];
  late final void Function() _listener = _see;

  void attach() => app.addListener(_listener);
  void detach() => app.removeListener(_listener);

  void _see() {
    final sighting = (
      at: started.elapsedMilliseconds,
      phase: app.phase.name,
      stage: _stageOf(app),
    );
    if (sightings.isEmpty ||
        sightings.last.phase != sighting.phase ||
        sightings.last.stage != sighting.stage) {
      sightings.add(sighting);
    }
  }
}

/// The stage the app says it is in, when it says one (`AppController.stage`).
String? _stageOf(AppController app) => app.stage?.name;

/// A run of [runs] cold resumes, reporting what each stage took: the
/// benchmark of this file, printed as `BENCH resume` lines.
Future<void> _bench(String name, Future<void> Function(_Rig rig) run,
    {required int runs, required Duration connect, required Duration initialize,
    required Duration answer}) async {
  final totals = <int>[];
  var last = <_Sighting>[];
  for (var i = 0; i < runs; i++) {
    final rig = await _launch(connect: connect, initialize: initialize, answer: answer);
    final watch = _Watch(rig.app)..attach();
    try {
      await run(rig);
    } finally {
      watch.detach();
      rig.app.dispose();
    }
    last = watch.sightings;
    totals.add(watch.started.elapsedMilliseconds);
  }
  totals.sort();
  stdout.writeln(
    'BENCH resume case=$name runs=$runs '
    'median=${totals[totals.length ~/ 2]}ms '
    'min=${totals.first}ms max=${totals.last}ms '
    'stages=${[for (final s in last) '${s.at}:${s.phase}${s.stage == null ? '' : '/${s.stage}'}'].join(' ')}',
  );
}

/// The stages of [watch], in order, each once, ignoring the ones that say
/// nothing (`null`: a phase the app is in without naming a stage).
List<String> _named(_Watch watch) => [
  for (final sighting in watch.sightings)
    if (sighting.stage != null) sighting.stage!,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The stage times a phone's network gives a harness: a socket that takes
  // 40 ms to open, a harness that thinks 120 ms about `initialize` and 30 ms
  // about each request after it.
  const connect = Duration(milliseconds: 40);
  const initialize = Duration(milliseconds: 120);
  const answer = Duration(milliseconds: 30);

  group('a resume names its stages', () {
    test('a cold resume: connecting, handshaking, sessions, projects', () async {
      final rig = await _launch(connect: connect, initialize: initialize, answer: answer);
      final watch = _Watch(rig.app)..attach();
      addTearDown(rig.app.dispose);
      await rig.app.resume();
      watch.detach();
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.app.stage, isNull);
      expect(_named(watch), [
        'connecting',
        'handshaking',
        'readingSessions',
        'readingProjects',
      ]);
      // Each stage is entered once: a stage is a step, not a repaint.
      expect(_named(watch).toSet().length, _named(watch).length);
      await _bench('cold', (rig) => rig.app.resume(),
          runs: 3, connect: connect, initialize: initialize, answer: answer);
    });

    test('a foreground resume that answers: checking, then in', () async {
      final rig = await _launch(connect: connect, initialize: initialize, answer: answer);
      addTearDown(rig.app.dispose);
      await rig.app.connect(_address, token: _token);
      final watch = _Watch(rig.app)..attach();
      await rig.app.resumed();
      watch.detach();
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.app.stage, isNull);
      expect(_named(watch), ['checking']);
    });
  });

  group('a connection that died without a word', () {
    test('is found by the probe of a foreground resume, and replaced', () async {
      final rig = await _launch(connect: connect, initialize: initialize, answer: answer);
      addTearDown(rig.app.dispose);
      await rig.app.connect(_address, token: _token);
      // The network died: the socket is still open, and nothing comes back.
      rig.harness.silent = true;
      final watch = _Watch(rig.app)..attach();
      await rig.app.resumed();
      watch.detach();
      expect(rig.app.phase, ConnectionPhase.connected);
      expect(rig.harness.connects, 2);
      expect(_named(watch).first, 'checking');
      // What a person sat through before the app even began to reconnect: the
      // probe, and no more than its limit.
      final checking = watch.sightings.firstWhere((s) => s.stage == 'checking');
      final reconnecting = watch.sightings.firstWhere(
        (s) => s.phase == 'reconnecting',
      );
      expect(reconnecting.at - checking.at, lessThan(3000));
      stdout.writeln(
        'BENCH resume case=dead '
        'silent-until-reconnect=${reconnecting.at - checking.at}ms',
      );
    });
  });

  group('a connect that never completes', () {
    test('is given up on in time for the next attempt', () async {
      // The network is gone: opening the socket neither succeeds nor
      // fails, as a phone between cells has it.  The app must not wait
      // on it for ever.
      SharedPreferences.setMockInitialValues({
        'address': _address,
        'token': _token,
      });
      final settings = SettingsController();
      await settings.load();
      final hanging = Completer<AcpTransport>();
      var calls = 0;
      final harness = FakeHarness(signIn: true, knownSecrets: {_token})
        ..connectDelay = Duration.zero;
      final app = AppController(
        settings: settings,
        connector: (target, token) {
          calls++;
          return calls == 1
              ? hanging.future
              : harness.connector(target, token);
        },
        reconnectDelays: const [Duration(milliseconds: 1)],
        connectTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(app.dispose);
      final watch = _Watch(app)..attach();
      await app.resume();
      watch.detach();
      // The first try was given up on, and the next one got in.
      expect(calls, 2);
      expect(app.phase, ConnectionPhase.connected);
      expect(
        watch.sightings.any((s) => s.stage == 'waiting'),
        isTrue,
        reason: 'the wait between attempts is named too',
      );
      expect(
        _named(watch).first,
        'connecting',
        reason: 'the socket is the first thing waited for',
      );
    });
  });

  group('what a person is shown while it goes back in', () {
    testWidgets('the banner names the stage and its age', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
        reconnectDelays: const [Duration(seconds: 30)],
      );
      // The app disposes it as the tree goes, at the end of the test.
      await app.connect(_address, token: _token);
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The app itself: the banner is drawn in the shell, over the screens,
      // with the app's own style (which its widgets need).
      await tester.pumpWidget(HarnessApp(settings: settings, appController: app));
      expect(find.byKey(const Key('connection-banner')), findsNothing);

      harness.refuseConnects = 1000000;
      await harness.dropConnection('The connection dropped.');
      await tester.pump();
      await tester.pump();
      // The heading is the notice it always was; under it, the stage
      // and how long it has been going.
      expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
      expect(find.byKey(const Key('connection-stage')), findsOneWidget);
      // The harness refused the try at once, so the stage is the wait
      // for the next one, said as a noun phrase and an age.
      expect(find.text('Waiting to retry · now'), findsOneWidget);
      // A second later, the age says so: the wait is not silent.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Waiting to retry · 1s'), findsOneWidget);
      // The stage's own words, as the app names them.
      expect(stageLabel(ConnectionStage.handshaking), 'Handshake');
      expect(stageLabel(ConnectionStage.waiting), 'Waiting to retry');
      expect(stageLabel(ConnectionStage.checking), 'Checking connection');
      expect(stageLabel(ConnectionStage.readingSessions), 'Reading sessions');
      expect(stageLabel(ConnectionStage.readingProjects), 'Reading projects');
      expect(stageLabel(ConnectionStage.signingIn), 'Signing in');
      // The wait between tries is the last timer; let the tree go.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('the resume card names the stage and its age', (tester) async {
      SharedPreferences.setMockInitialValues({
        'address': _address,
        'token': _token,
      });
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness(signIn: true, knownSecrets: {_token})
        ..connectDelay = const Duration(seconds: 30);
      final app = AppController(
        settings: settings,
        connector: harness.connector,
        reconnectDelays: const [Duration(seconds: 30)],
      );
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HarnessApp(settings: settings, appController: app),
      );
      await tester.pump();
      expect(find.byKey(const Key('resume-card')), findsOneWidget);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Connecting · now'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Connecting · 2s'), findsOneWidget);
      // The form for an address is not what a device that holds one sees.
      expect(find.byKey(const Key('connect-address')), findsNothing);
      // The connect in flight is bounded by the app's own timeout; let it
      // run out as the tree goes, so nothing is left pending.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 31));
    });
  });
}
