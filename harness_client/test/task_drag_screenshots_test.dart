// Pictures of the task board with a card being carried to another column: the
// wide board, with every column beside the others and the drop named where the
// card would go, and the phone, with every column shown as a section while one
// is carried.
//
//   HARNESS_SHOTS=/some/directory flutter test test/task_drag_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still run
// (they draw, and check what is on the screen), and write nothing.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/screens/tasks_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

enum _Scene { board, drag, phoneDrag }

// Named as the screenshots of the README are.
const _cases = {
  'task-board': _Scene.board,
  'task-board-drag': _Scene.drag,
  'android-task-drag': _Scene.phoneDrag,
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  const wide = Size(1920, 1080);
  const phone = Size(412, 915);
  const wideRatio = 1.0;
  const phoneRatio = 2.0;

  for (final MapEntry(key: file, value: scene) in _cases.entries) {
    testWidgets('draws $file', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      final harness = FakeHarness()
        ..seedOtherProjectTasks()
        ..seedTaskSessions();
      final app = AppController(
        settings: settings,
        connector: harness.connector,
      );
      await app.connect('ws://memory/acp');

      final phoneScene = scene == _Scene.phoneDrag;
      final ratio = phoneScene ? phoneRatio : wideRatio;
      final size = phoneScene ? phone : wide;
      tester.view.physicalSize = size * ratio;
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = FakeViewPadding(
        top: 24 * ratio,
        bottom: 24 * ratio,
      );
      tester.view.padding = tester.view.viewPadding;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);

      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: HarnessApp(
            settings: settings,
            appController: app,
            themeBuilder: phoneFonts,
          ),
        ),
      );
      await tester.pump();
      Future<void> settle([int rounds = 8]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 120));
        }
      }

      await settle(10);
      await tester.tap(find.text('Tasks'));
      await settle(6);

      /// Lift the card of [taskId], carry it over [target], and leave it
      /// there while the picture is taken.
      Future<TestGesture> carry(String taskId, Finder target) async {
        final card = find.byKey(ValueKey('task-card-$taskId'));
        await tester.ensureVisible(card);
        await tester.pump();
        final gesture = await tester.startGesture(
          tester.getCenter(card),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
        await tester.ensureVisible(target);
        await tester.pump();
        await gesture.moveTo(tester.getCenter(target));
        await tester.pump(const Duration(milliseconds: 200));
        return gesture;
      }

      TestGesture? carried;
      switch (scene) {
        case _Scene.board:
          // The columns of a wide board, side by side, with a card to carry.
          expect(find.byType(TaskCard), findsWidgets);
          expect(find.text('Start now'), findsNothing);
        case _Scene.drag:
          // A card is carried along its lane, to another column of it.
          carried = await carry(
            'task-3',
            find.byKey(const ValueKey('task-cell-low-active')),
          );
          // The column it is over names what leaving it there would do.
          expect(find.text('Start now'), findsOneWidget);
        case _Scene.phoneDrag:
          // The stages of a phone's one list, every priority in them, in the
          // order a person attends to them: Review comes first, above Active,
          // and the card is carried to it.  (The columns that hold nothing
          // are targets too while a card is carried; the picture holds one
          // card over the first section, and `task_drag_test.dart` takes the
          // empty ones.)
          expect(find.text('Merging'), findsNothing);
          carried = await carry('task-1', find.text('Review'));
          expect(find.text('Put in review'), findsOneWidget);
          expect(
            tester.getTopLeft(find.text('Review')).dy,
            lessThan(tester.getTopLeft(find.text('Active')).dy),
          );
      }

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: phoneScene ? 2 : 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('$shots/$file${real ? '' : '-ahem'}.png');
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
      await carried?.cancel();
      await tester.pump();
    });
  }
}
