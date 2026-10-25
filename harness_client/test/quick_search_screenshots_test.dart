// Pictures of the quick search on phones, drawn with the fonts of a phone.
//
//   HARNESS_SHOTS=/some/directory flutter test test/quick_search_screenshots_test.dart
//
// writes a PNG for each case there (the pictures of the README are made so:
// `HARNESS_SHOTS=screenshots flutter test test/quick_search_screenshots_test.dart`).  Without HARNESS_SHOTS the cases still
// run (they draw, and check that what they show is whole on the picture's
// screen), and write nothing.  The harness is the fake one with the search
// scripted (`SearchingHarness`): the pictures show what the app draws of
// what a harness answers, not what a model says.
//
// The page is drawn as the app draws it, in a `MaterialApp` of the app's own
// theme, but for what the test engine cannot do on its own: a style that names
// no font family is drawn in the test font, as squares, and the theme's
// buttons are such styles, so here they name Roboto (see `real_fonts.dart`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/quick_search_catalogue.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/app_scope.dart';
import 'package:harness_client/src/ui/screens/quick_search_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/quick_search_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/quick_search_harness.dart';
import 'support/real_fonts.dart';

/// What a picture is of, and how it is drawn.
class _Shot {
  const _Shot(
    this.file,
    this.steps, {
    this.place = const QuickSearchPlace(SearchOrigin.sessions),
    this.width = 360,
    this.height = 800,
    this.apple = false,
    this.dark = false,
    this.offersSearch = true,
    this.app = false,
  });

  final String file;
  final Future<void> Function(_Scene scene) steps;

  /// Where the search is opened from.
  final QuickSearchPlace place;
  final double width;
  final double height;
  final bool apple;
  final bool dark;
  final bool offersSearch;

  /// Drawn as part of the whole app, with its tabs, not as the page alone.
  final bool app;
}

class _Scene {
  _Scene(this.tester, this.search, this.app);
  final WidgetTester tester;
  final SearchingHarness search;
  final AppController app;

  /// The searches the harness is still thinking about.
  final List<Completer<Object?>> thinking = [];

  /// The harness thinks, and goes on thinking until [finish].
  void think() => search.onAsk = (_) {
    final gate = Completer<Object?>();
    thinking.add(gate);
    return gate.future;
  };

  /// Let the harness go on: it answers, and is reachable again, so that
  /// nothing is left waiting when the picture is done.
  Future<void> finish() async {
    search.harness.refuseConnects = 0;
    for (final gate in thinking) {
      gate.complete(plan());
    }
    await settle(12);
  }

  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Show a tab of the whole app.
  Future<void> tab(String label) async {
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is NavigationBar || widget is CupertinoTabBar,
        ),
        matching: find.text(label),
      ),
    );
    await settle(4);
  }

  Future<void> ask(String line) async {
    await tester.enterText(find.byKey(const Key('quick-search-field')), line);
    await tester.pump();
    await tester.tap(find.byKey(const Key('quick-search-submit')));
    await settle(6);
  }
}

const _answer =
    'Open **New task** with the **+** on the Tasks screen, then tap '
    '**Attach images** and pick the pictures. A conversation’s message box '
    'has the same button:\n\n'
    '1. Tap the image button.\n'
    '2. Pick up to four pictures.\n'
    '3. Send the message or the task.';

final _attach = plan(
  query: 'how do I attach an image to a task?',
  answer: _answer,
  commands: [
    foundCommand(
      'new-task',
      keys: 'Tasks tab › +',
      label: 'Submit a new task',
      doc:
          'Describe the work, pick project and priority, attach images, '
          'write it up or plan it first, and send it.',
    ),
    foundCommand(
      'attach-images',
      keys: 'Tasks tab › + › Attach images; in a conversation › image button',
      label: 'Attach images to a task or a message',
      doc:
          'The image button of the new-task sheet and of a conversation’s '
          'message box sends pictures along with the text.',
    ),
  ],
  sessions: [
    foundSession(
      's1',
      name: 'Design the merge queue',
      snippet: 'attach the screenshots to the task as images',
      ranges: [
        [0, 6],
        [11, 22],
      ],
    ),
  ],
);

final _board = plan(
  query: 'get rid of the screenshots task',
  bias: 'tasks',
  tasks: [
    foundTask(
      'task-2',
      'Review the emulator screenshots',
      'review: finished, waits for your review',
    ),
    foundTask(
      'task-1',
      'Build the Flutter ACP client',
      'in progress: working',
      session: 's3',
    ),
  ],
  sessions: [
    foundSession(
      's2',
      name: 'Fix duplicate task titles',
      status: 'blocked',
      snippet: 'rename the duplicate screenshots task titles',
      ranges: [
        [21, 32],
      ],
    ),
  ],
  actions: [
    proposedAction(
      'task-2',
      'archive',
      title: 'Review the emulator screenshots',
    ),
  ],
);

final _cases = <_Shot>[
  // The way in: the button at the end of the header of a page.
  _Shot('android-quick-search-way-in', (scene) async {
    await scene.settle();
  }, app: true),
  _Shot('android-quick-search-way-in-tasks', (scene) async {
    await scene.tab('Tasks');
  }, app: true),
  _Shot('android-quick-search-way-in-chat', (scene) async {
    await scene.tester.tap(find.text('Design the merge queue'));
    await scene.settle(6);
  }, app: true),
  _Shot('android-quick-search-hint', (scene) async {
    scene.app.quickSearchHistory
      ..add('where did I debug the merge queue?')
      ..add('stop the docs task');
  }, place: const QuickSearchPlace(SearchOrigin.tasks)),
  _Shot(
    'android-quick-search-answer',
    (scene) async {
      scene.search.onAsk = (_) => _attach;
      await scene.ask('how do I attach an image to a task?');
    },
    place: const QuickSearchPlace(SearchOrigin.settings),
    height: 1100,
  ),
  // The picture ends under the first session: the test engine draws the
  // labels of an iPhone's buttons, which name no font, as squares.
  _Shot(
    'ios-quick-search-answer',
    (scene) async {
      scene.search.onAsk = (_) => _attach;
      await scene.ask('how do I attach an image to a task?');
    },
    place: const QuickSearchPlace(SearchOrigin.settings),
    width: 390,
    height: 890,
    apple: true,
  ),
  _Shot(
    'android-quick-search-answer-dark',
    (scene) async {
      scene.search.onAsk = (_) => _attach;
      await scene.ask('how do I attach an image to a task?');
    },
    place: const QuickSearchPlace(SearchOrigin.usage),
    height: 1100,
    dark: true,
  ),
  _Shot(
    'android-quick-search-tasks',
    (scene) async {
      scene.search.onAsk = (_) => _board;
      await scene.ask('get rid of the screenshots task');
    },
    place: const QuickSearchPlace(SearchOrigin.tasks),
    height: 1000,
  ),
  _Shot(
    'android-quick-search-done',
    (scene) async {
      scene.search.onAsk = (_) => _board;
      await scene.ask('get rid of the screenshots task');
      await scene.tester.tap(find.byKey(const Key('quick-search-do-it')));
      await scene.settle(6);
    },
    place: const QuickSearchPlace(SearchOrigin.tasks),
    height: 1000,
  ),
  _Shot('android-quick-search-waiting', (scene) async {
    scene.think();
    await scene.ask('where did I debug the merge queue?');
  }),
  _Shot('android-quick-search-nothing', (scene) async {
    scene.search.onAsk = (_) => plan(
      query: 'zzzz qqqq',
      widened: true,
      note: 'Nothing matched: no task, session or command.',
    );
    await scene.ask('zzzz qqqq');
  }),
  _Shot('android-quick-search-failed', (scene) async {
    scene.search.onAsk = (_) =>
        throw const SearchFailure('The model took longer than 45s');
    await scene.ask('where did I debug the merge queue?');
  }),
  _Shot('android-quick-search-reconnecting', (scene) async {
    await scene.tester.enterText(
      find.byKey(const Key('quick-search-field')),
      'the merge queue',
    );
    await scene.tester.pump();
    scene.search.harness.refuseConnects = 1000000;
    await scene.search.harness.dropConnection('The connection dropped.');
    await scene.settle(4);
  }),
  _Shot('android-quick-search-unsupported', (scene) async {
    await scene.settle(2);
  }, offersSearch: false),
];

/// The theme of the app, with the theme's buttons naming the font they are
/// drawn in: the test engine draws a style that names none as squares.
ThemeData _named(ThemeData theme) {
  ButtonStyle? roboto(ButtonStyle? style) {
    final text = style?.textStyle?.resolve(const {});
    return style?.copyWith(
      textStyle: WidgetStatePropertyAll(text?.copyWith(fontFamily: 'Roboto')),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: roboto(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: roboto(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: roboto(theme.textButtonTheme.style),
    ),
  );
}

/// The icons of an iPhone, which the pictures in its style draw: the font is
/// in the package that has the icons, found where the package config says.
Future<void> _loadCupertinoIcons() async {
  final config = File('.dart_tool/package_config.json').absolute;
  if (!config.existsSync()) return;
  final packages = jsonDecode(config.readAsStringSync())['packages'] as List;
  for (final package in packages) {
    if (package['name'] != 'cupertino_icons') continue;
    var root = '${package['rootUri']}';
    if (!root.endsWith('/')) root = '$root/';
    final base = Uri.parse(root).hasScheme
        ? Uri.parse(root)
        : config.parent.uri.resolve(root);
    final font = File.fromUri(base.resolve('assets/CupertinoIcons.ttf'));
    if (!font.existsSync()) return;
    final loader = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await loader.load();
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();
  await _loadCupertinoIcons();

  for (final shot in _cases) {
    testWidgets('draws ${shot.file}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      if (shot.apple) {
        await settings.setPreviewPlatform(PreviewPlatform.cupertino);
      }
      if (shot.dark) await settings.setThemeMode(ThemeMode.dark);
      final search = SearchingHarness(
        harness: FakeHarness(),
        offersSearch: shot.offersSearch,
      );
      search.harness.seedOtherProjectTasks();
      final app = AppController(
        settings: settings,
        connector: search.connector,
        reconnectDelays: const [Duration(milliseconds: 5)],
        handshakeTimeout: const Duration(seconds: 2),
        probeTimeout: const Duration(milliseconds: 150),
      );
      await app.connect('ws://memory/acp');

      const ratio = 2.0;
      tester.view.physicalSize = Size(shot.width * ratio, shot.height * ratio);
      tester.view.devicePixelRatio = ratio;
      tester.view.viewPadding = const FakeViewPadding(
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
      final brightness = shot.dark ? Brightness.dark : Brightness.light;
      final Widget home = shot.app
          ? HarnessApp(settings: settings, appController: app)
          : HarnessStyle(
              style: shot.apple
                  ? HarnessPlatformStyle.cupertino
                  : HarnessPlatformStyle.material,
              child: HarnessScope(
                app: app,
                settings: settings,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: _named(HarnessTheme.material(Brightness.light)),
                  darkTheme: _named(HarnessTheme.material(Brightness.dark)),
                  themeMode: shot.dark ? ThemeMode.dark : ThemeMode.light,
                  builder: (context, child) => shot.apple
                      ? CupertinoTheme(
                          data: HarnessTheme.cupertino(brightness),
                          child: child!,
                        )
                      : child!,
                  home: QuickSearchScreen(app: app, place: shot.place),
                ),
              ),
            );
      await tester.pumpWidget(RepaintBoundary(key: boundary, child: home));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      if (shot.apple) tester.takeException();
      final scene = _Scene(tester, search, app);
      await shot.steps(scene);
      if (shot.apple) tester.takeException();

      if (shot.app) {
        expect(find.byKey(QuickSearchEntry.buttonKey), findsOneWidget);
      }
      // Nothing the picture shows is cut off by the screen.
      final screen = Rect.fromLTWH(0, 0, shot.width, shot.height);
      for (final key in const [
        'quick-search-field',
        'quick-search-found',
        'quick-search-waiting',
        'quick-search-error',
        'quick-search-hint',
      ]) {
        for (final element in find.byKey(Key(key)).evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          expect(
            rect.left,
            greaterThanOrEqualTo(-0.01),
            reason: '${shot.file}: $key starts inside the screen',
          );
          expect(
            rect.right,
            lessThanOrEqualTo(screen.right + 0.01),
            reason: '${shot.file}: $key ends inside the screen',
          );
        }
      }

      if (shots != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$shots/${shot.file}${real ? '' : '-ahem'}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
        });
      }
      await scene.finish();
    });
  }
}
