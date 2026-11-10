// Pictures of the task board in the order a person attends to it: on a phone,
// the one scroll whose sections lead with what waits on the person and go on
// Review, Active, Pending, Backlog, Merging, Done, Cancelled; on a wide
// screen, the grid of workflow columns by lane rows, which the phone's order
// leaves as it was.
//
//   HARNESS_SHOTS=/some/directory flutter test test/task_board_order_screenshots_test.dart
//
// writes a PNG for each case there.  Without HARNESS_SHOTS the cases still
// run (they draw, and check what is on the screen), and write nothing.
//
// The phone's board is longer than a phone, so it is taken twice: the top of
// its scroll and its end.  The whole order in one picture is the widget
// test's, on a screen tall enough to draw every section
// (`test/task_column_order_test.dart`).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/phone_fonts.dart';
import 'support/real_fonts.dart';

enum _Scene { phoneTop, phoneEnd, wide }

const _cases = {
  'android-task-board-order': _Scene.phoneTop,
  'android-task-board-order-end': _Scene.phoneEnd,
  'task-board-order-wide': _Scene.wide,
};

const _sections = {
  'needs-input': 'Needs input',
  'review': 'Review',
  'active': 'Active',
  'pending': 'Pending',
  'backlog': 'Backlog',
  'merging': 'Merging',
  'done': 'Done',
  'cancelled': 'Cancelled',
};

/// Where a section of a phone's board starts, by its key: the lane of what
/// waits on the person, else the stage's section.
Finder _section(String section) => section == 'needs-input'
    ? find.byKey(const ValueKey('task-lane-needs-input'))
    : find.byKey(ValueKey('task-section-$section'));

/// The sections among [given] that the board draws, top to bottom, with
/// where each starts.
List<String> _drawnInOrder(WidgetTester tester, List<String> given) {
  final drawn = <String, double>{};
  for (final section in given) {
    if (_section(section).evaluate().isEmpty) continue;
    drawn[section] = tester.getTopLeft(_section(section)).dy;
    expect(
      find.descendant(of: _section(section), matching: find.text(_sections[section]!)),
      findsOneWidget,
      reason: 'the $section section says its name',
    );
  }
  final order = [for (final section in given) if (drawn.containsKey(section)) section];
  for (var i = 1; i < order.length; i++) {
    expect(
      drawn[order[i]]!,
      greaterThan(drawn[order[i - 1]]!),
      reason: '${order[i]} is below ${order[i - 1]}',
    );
  }
  return order;
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();

  const phone = Size(412, 915);
  const phoneRatio = 2.625;
  const wide = Size(1920, 1080);
  const wideRatio = 1.0;

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

      final isPhone = scene != _Scene.wide;
      final ratio = isPhone ? phoneRatio : wideRatio;
      tester.view.physicalSize = (isPhone ? phone : wide) * ratio;
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

      switch (scene) {
        case _Scene.phoneTop:
          // The top of the scroll: what waits on the person, then the work
          // ready for review, then the work at work.
          expect(
            _drawnInOrder(tester, ['needs-input', 'review', 'active']),
            ['needs-input', 'review', 'active'],
          );
          // Every priority is on the board at once.
          for (final priority in [
            'High priority',
            'Medium priority',
            'Low priority',
          ]) {
            expect(
              find.textContaining(priority, findRichText: true),
              findsWidgets,
              reason: priority,
            );
          }
        case _Scene.phoneEnd:
          // The end of the same scroll: the waiting work, then the work that
          // is over.
          final list = find
              .descendant(
                of: find.byType(RefreshIndicator),
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(list).position.jumpTo(
            tester.state<ScrollableState>(list).position.maxScrollExtent,
          );
          await settle(4);
          final drawn = _drawnInOrder(tester, [
            'pending',
            'backlog',
            'done',
            'cancelled',
          ]);
          expect(drawn, containsAllInOrder(['pending', 'backlog', 'done']));
        case _Scene.wide:
          // A wide board is the grid of workflow columns by lane rows,
          // whatever the phone's order is.
          final lefts = {
            for (final stage in taskColumns)
              stage: tester.getTopLeft(find.text(_sections[stage]!)).dx,
          };
          for (var i = 1; i < taskColumns.length; i++) {
            expect(
              lefts[taskColumns[i]]!,
              greaterThan(lefts[taskColumns[i - 1]]!),
              reason: '${taskColumns[i]} is right of ${taskColumns[i - 1]}',
            );
          }
          final tops = {
            for (final lane in taskLanes)
              lane: tester.getTopLeft(find.byKey(ValueKey('task-lane-$lane'))).dy,
          };
          for (var i = 1; i < taskLanes.length; i++) {
            expect(
              tops[taskLanes[i]]!,
              greaterThan(tops[taskLanes[i - 1]]!),
              reason: '${taskLanes[i]} is below ${taskLanes[i - 1]}',
            );
          }
      }

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: isPhone ? 2 : 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('$shots/$file${real ? '' : '-ahem'}.png');
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
    });
  }
}
