// The permission-mode picker under a conversation, and the standard ACP
// session modes behind it.  The harness answers `initialize` with its bus
// extensions in `_harness.methods`; `session/set_mode` is a standard ACP
// method and is never one of them, so the picker must not be gated on that
// list, and what it offers must be the session's own `availableModes`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/session.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/session_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/layout_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);

  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({
  bool enhanced = true,
  bool failSetMode = false,
  List<Map<String, Object?>>? availableModes,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(
    enhanced: enhanced,
    failSetMode: failSetMode,
    availableModes: availableModes,
  );
  final app = AppController(settings: settings, connector: harness.connector);
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

/// The app on a screen of [size] logical points, on a conversation.
Future<void> _open(WidgetTester tester, _Rig rig, {required Size size}) async {
  const ratio = 2.0;
  tester.view.physicalSize = Size(size.width * ratio, size.height * ratio);
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.tap(find.text('Design the merge queue'));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The shield picker under the conversation's message box: the one control
/// this page has for the permission mode.
Finder get _shield => find.byIcon(Icons.shield_outlined);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('standard ACP session modes', () {
    test('are not extension discovery', () async {
      final rig = await _rig();
      final caps = rig.app.capability!;
      expect(caps.isHarness, isTrue);
      // The harness handles both, but they are standard ACP methods and are
      // never entries of `_harness.methods`.
      expect(caps.has('session/set_mode'), isFalse);
      expect(caps.has('session/set_model'), isFalse);
      expect(caps.has('session/get'), isTrue);
    });

    test(
      'come with session/load, even when the extension list omits them',
      () async {
        final rig = await _rig();
        final controller = rig.app.openSession('s2');
        await _until(() => !controller.loading, what: 'the conversation');

        expect(rig.app.capability!.has('session/set_mode'), isFalse);
        expect(controller.canChangeMode, isTrue);
        expect(controller.currentModeId, 'accept-edits');
        expect(controller.currentMode!.name, 'Accept edits');
        expect(controller.modes!.available.map((mode) => mode.id), [
          'ask',
          'accept-edits',
          'auto',
          'yolo',
        ]);
      },
    );

    test(
      'a chosen mode calls session/set_mode and becomes the shown one',
      () async {
        final rig = await _rig();
        final controller = rig.app.openSession('s2');
        await _until(() => !controller.loading, what: 'the conversation');

        await controller.setMode('yolo');

        expect(controller.error, isNull);
        expect(controller.currentModeId, 'yolo');
        final call = rig.harness.requests.lastWhere(
          (request) => request.$1 == 'session/set_mode',
        );
        expect(call.$2['sessionId'], 's2');
        expect(call.$2['modeId'], 'yolo');
      },
    );

    test('a refused change keeps the shown mode and says why', () async {
      final rig = await _rig(failSetMode: true);
      final controller = rig.app.openSession('s2');
      await _until(() => !controller.loading, what: 'the conversation');
      expect(controller.currentModeId, 'accept-edits');

      await controller.setMode('yolo');

      expect(controller.currentModeId, 'accept-edits');
      expect(controller.error, contains('unknown mode yolo'));
    });

    test('repeated changes each reach the agent', () async {
      final rig = await _rig();
      final controller = rig.app.openSession('s2');
      await _until(() => !controller.loading, what: 'the conversation');

      for (final mode in ['yolo', 'auto', 'ask']) {
        await controller.setMode(mode);
        expect(controller.currentModeId, mode);
      }
      expect(
        [
          for (final (method, params) in rig.harness.requests)
            if (method == 'session/set_mode') params['modeId'],
        ],
        ['yolo', 'auto', 'ask'],
      );
    });

    test('an agent changing its own mode moves the shown one', () async {
      // A plain ACP agent: no `session/get` to refresh, the update itself is
      // what the conversation reads.
      final rig = await _rig(enhanced: false);
      final controller = rig.app.openSession('s1');
      await _until(() => !controller.loading, what: 'the conversation');
      expect(controller.canChangeMode, isTrue);

      rig.harness.pushMode('s1', 'yolo');
      await _until(
        () => controller.currentModeId == 'yolo',
        what: 'the mode update',
      );
      expect(controller.currentMode!.name, 'YOLO');
    });

    test('reopening reads the modes again', () async {
      final rig = await _rig();
      final controller = rig.app.openSession('s2');
      await _until(() => !controller.loading, what: 'the conversation');
      await controller.setMode('auto');

      await controller.open(force: true);

      expect(controller.canChangeMode, isTrue);
      expect(controller.currentModeId, 'auto');
      expect(controller.modes!.available, hasLength(4));
    });

    test('a lost connection is read again when the conversation opens',
        () async {
      final rig = await _rig();
      final controller = rig.app.openSession('s2');
      await _until(() => !controller.loading, what: 'the conversation');
      await controller.setMode('yolo');

      rig.harness.refuseConnects = 1000000;
      await rig.harness.dropConnection('The connection dropped.');
      await _until(
        () => rig.app.phase == ConnectionPhase.reconnecting,
        what: 'the app to notice the lost connection',
      );
      rig.harness.refuseConnects = 0;
      await _until(
        () => rig.app.phase == ConnectionPhase.connected,
        what: 'the app to reconnect',
      );

      // Not forced: the conversation knows its connection was replaced, and
      // reads the session (and its modes) again.
      await controller.open();
      expect(controller.currentModeId, 'yolo');
      expect(controller.canChangeMode, isTrue);
    });

    test('a session that offers none has no picker', () async {
      final rig = await _rig(enhanced: false, availableModes: const []);
      final controller = rig.app.openSession('s1');
      await _until(() => !controller.loading, what: 'the conversation');
      expect(controller.modes, isNull);
      expect(controller.canChangeMode, isFalse);
    });

    test('a virtual session has no picker', () async {
      final rig = await _rig();
      final controller = SessionController(
        api: rig.app.harness!,
        sessionId: 'harness:projects',
        summary: const SessionSummary(id: 'harness:projects', virtual: true),
      );
      controller.adoptModes({
        'currentModeId': 'ask',
        'availableModes': [
          {'id': 'ask', 'name': 'Ask'},
        ],
      });
      expect(controller.canChangeMode, isFalse);
      controller.dispose();
    });

    test('a new session keeps its creation modes', () async {
      final rig = await _rig();
      final id = await rig.app.createSession(cwd: '/tmp/project');
      expect(id, isNotNull);
      final controller = rig.app.sessionController(id!);
      await _until(() => !controller.loading, what: 'the new conversation');
      expect(controller.canChangeMode, isTrue);
      expect(controller.currentModeId, 'ask');
    });
  });

  group('the permission-mode picker', () {
    for (final size in const [Size(1440, 900), Size(390, 844)]) {
      testWidgets('opens and changes the mode at ${size.width.toInt()}', (
        tester,
      ) async {
        final rig = await _rig();
        await _open(tester, rig, size: size);

        expect(_shield, findsOneWidget);
        expect(find.text('Ask'), findsWidgets);
        await tester.tap(_shield);
        await _settle(tester);

        // The modes the session offers, by the names the agent gave them,
        // and not the old sentence-long labels.
        expect(find.text('Permission mode'), findsOneWidget);
        for (final name in ['Ask', 'Accept edits', 'Auto', 'YOLO']) {
          expect(find.widgetWithText(ListTile, name), findsOneWidget);
        }
        expect(find.textContaining('reads allowed'), findsNothing);

        await tester.tap(find.text('Accept edits'));
        await _settle(tester);
        expect(_shield, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(HarnessPicker),
            matching: find.text('Accept edits'),
          ),
          findsOneWidget,
        );

        // A second change from the same page.
        await tester.tap(_shield);
        await _settle(tester);
        await tester.tap(find.text('Auto'));
        await _settle(tester);
        expect(
          find.descendant(
            of: find.byType(HarnessPicker),
            matching: find.text('Auto'),
          ),
          findsOneWidget,
        );
        expect(
          [
            for (final (method, params) in rig.harness.requests)
              if (method == 'session/set_mode') params['modeId'],
          ],
          ['accept-edits', 'auto'],
        );
      });
    }

    testWidgets('a refused change says why and keeps the mode', (tester) async {
      final rig = await _rig(failSetMode: true);
      await _open(tester, rig, size: const Size(1440, 900));

      await tester.tap(_shield);
      await _settle(tester);
      await tester.tap(find.text('YOLO'));
      await _settle(tester);

      expect(find.textContaining('unknown mode yolo'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HarnessPicker),
          matching: find.text('Ask'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a plain ACP agent that offers modes can change them', (
      tester,
    ) async {
      final rig = await _rig(enhanced: false);
      await _open(tester, rig, size: const Size(1440, 900));

      expect(rig.app.capability!.isHarness, isFalse);
      await tester.tap(_shield);
      await _settle(tester);
      await tester.tap(find.text('YOLO'));
      await _settle(tester);

      expect(
        find.descendant(
          of: find.byType(HarnessPicker),
          matching: find.text('YOLO'),
        ),
        findsOneWidget,
      );
      expect(
        [
          for (final (method, params) in rig.harness.requests)
            if (method == 'session/set_mode') params['modeId'],
        ],
        ['yolo'],
      );
    });

    testWidgets('the session menu offers the same choice', (tester) async {
      final rig = await _rig();
      await _open(tester, rig, size: const Size(1440, 900));

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await _settle(tester);
      expect(find.widgetWithText(ListTile, 'Permission mode'), findsOneWidget);
    });
  });
}
