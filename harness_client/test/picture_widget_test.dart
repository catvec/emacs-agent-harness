// A picture of the harness's machine, drawn where the app names it: while it
// comes, once it has, when it cannot, and larger when it is tapped; and the
// places that name one -- the file a `read_file` call read, the screenshots a
// task handed in, the report in the task's sheet -- drawing it, or, where the
// harness gives no pictures, naming it as before.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/models/picture.dart';
import 'package:harness_client/src/models/tool_display.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/pictures.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/screens/tool_detail_screen.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/harness_picture.dart';
import 'package:harness_client/src/ui/widgets/tool_body.dart';
import 'package:harness_client/src/ui/widgets/transcript_view.dart';

import 'support/fake_image_picker.dart';
import 'support/tool_showcase.dart';

/// A source of pictures that a test is in charge of: it records what it was
/// asked for and answers as the test says, at once or when it is told to.
class FakeSource implements PictureSource {
  FakeSource({this.available = true});

  @override
  bool available;

  /// What was asked for, as (session, path).
  final requests = <(String, String)>[];

  /// What the next request is answered with.
  Picture answer = Picture(
    bytes: onePixelPng,
    mime: 'image/png',
    name: 'shot.png',
  );

  /// Fail the next requests with this.
  Object? failure;

  /// Leave requests unanswered until [release].
  bool hold = false;
  final _held = <Completer<Picture>>[];

  @override
  Future<Picture> load(String sessionId, String path) {
    requests.add((sessionId, path));
    if (hold) {
      final held = Completer<Picture>();
      _held.add(held);
      return held.future;
    }
    final failure = this.failure;
    if (failure != null) return Future<Picture>.error(failure);
    return Future.value(answer);
  }

  /// What is known already, as a source that kept it would say.
  Picture? kept;

  @override
  Picture? peek(String sessionId, String path) => kept;

  /// Answer the requests that wait.
  void release() {
    for (final held in _held) {
      held.complete(answer);
    }
    _held.clear();
  }
}

Widget _app(
  Widget body, {
  FakeSource? source,
  HarnessPlatformStyle style = HarnessPlatformStyle.material,
  bool page = false,
}) {
  Widget child = page
      ? body
      : Scaffold(body: SingleChildScrollView(child: body));
  if (source != null) child = PictureScope(source: source, child: child);
  return HarnessStyle(
    style: style,
    child: MaterialApp(
      theme: HarnessTheme.material(Brightness.light),
      home: child,
    ),
  );
}

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Time passes in the real world, as decoding a picture takes: a picture has
/// no size until its first frame is decoded, and a test that pumps frames
/// alone never sees one.
Future<void> _decoded(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (_loading.evaluate().isEmpty) return;
  }
}

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<rect width="10" height="10" fill="#3366cc"/></svg>';

final _drawn = find.byKey(const ValueKey('picture-drawn'));
final _loading = find.byKey(const ValueKey('picture-loading'));
final _failed = find.byKey(const ValueKey('picture-failed'));
final _viewer = find.byKey(const ValueKey('picture-viewer'));

void main() {
  group('a picture of the harness', () {
    testWidgets('is a placeholder while it comes, then the picture', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource()..hold = true;
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/shots/chat.png'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(_loading, findsOneWidget);
      expect(_drawn, findsNothing);
      expect(source.requests, [('s-1', '/work/shots/chat.png')]);
      source.release();
      await _settle(tester);
      // It has come; it is decoded in a moment, and until it is, it has no
      // size, so the placeholder stays.
      expect(_drawn, findsOneWidget);
      expect(_loading, findsOneWidget);
      await _decoded(tester);
      expect(_loading, findsNothing);
      expect(_drawn, findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.getSize(_drawn).width, greaterThan(0));
    });

    testWidgets('is drawn at once when the source has it already', (
      tester,
    ) async {
      await _phone(tester);
      // The picture is known, and asking again would be answered late.
      final source = FakeSource()
        ..hold = true
        ..kept = Picture(bytes: onePixelPng, mime: 'image/png');
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/a.png'),
          source: source,
        ),
      );
      await tester.pump();
      expect(_drawn, findsOneWidget);
      // Not a placeholder of the request, which is still on its way.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('is asked for once, however often it is drawn again', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource();
      const picture = HarnessPicture(sessionId: 's-1', path: '/work/a.png');
      await tester.pumpWidget(_app(picture, source: source));
      await _settle(tester);
      await tester.pumpWidget(_app(picture, source: source));
      await _settle(tester);
      expect(source.requests.length, 1);
      // Another file is another picture.
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/b.png'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(source.requests.last, ('s-1', '/work/b.png'));
      expect(source.requests.length, 2);
    });

    testWidgets('is drawn as a drawing when the harness gave an SVG', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource()
        ..answer = Picture(
          bytes: Uint8List.fromList(utf8.encode(_svg)),
          mime: 'image/svg+xml',
          name: 'chart.svg',
        );
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/chart.svg'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows itself larger on a page of its own, which closes', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource();
      await tester.pumpWidget(
        _app(
          const HarnessPicture(
            sessionId: 's-1',
            path: '/work/shots/chat.png',
            name: 'The chat',
          ),
          source: source,
        ),
      );
      await _settle(tester);
      expect(_viewer, findsNothing);
      await _decoded(tester);
      await tester.tap(_drawn);
      await _settle(tester);
      expect(_viewer, findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      // The picture has the whole page to be looked into.
      expect(
        tester.getSize(find.byType(InteractiveViewer)),
        tester.getSize(_viewer),
      );
      // The page is named for the picture.
      expect(find.text('The chat'), findsOneWidget);
      // It was not asked for again: the page has the picture the card had.
      expect(source.requests.length, 1);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(_viewer, findsNothing);
      expect(_drawn, findsOneWidget);
    });

    testWidgets('zooms in on a double tap and out on the next', (tester) async {
      await _phone(tester);
      await tester.pumpWidget(
        _app(
          PictureViewerScreen(
            picture: Picture(bytes: onePixelPng, mime: 'image/png'),
            title: 'x',
          ),
          page: true,
        ),
      );
      TransformationController? controller() => tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController;
      expect(controller()!.value.getMaxScaleOnAxis(), 1.0);
      final at =
          tester.getCenter(find.byType(InteractiveViewer)) +
          const Offset(60, 40);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller()!.value.getMaxScaleOnAxis(), closeTo(3.0, 1e-6));
      // The place that was tapped stays where the finger is.
      final inverse = Matrix4.inverted(controller()!.value);
      final under = MatrixUtils.transformPoint(inverse, at);
      expect(under.dx, closeTo(at.dx, 1e-6));
      expect(under.dy, closeTo(at.dy, 1e-6));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller()!.value.getMaxScaleOnAxis(), 1.0);
    });

    testWidgets('says why it could not come, and can be asked for again', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource()
        ..failure = const AcpException(
          -32603,
          'big.png is 20 MiB, larger than the 16 MiB a picture may be',
        );
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/big.png'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(_failed, findsOneWidget);
      expect(find.text('The picture could not be loaded'), findsOneWidget);
      expect(
        find.text('big.png is 20 MiB, larger than the 16 MiB a picture may be'),
        findsOneWidget,
      );
      expect(_drawn, findsNothing);
      // The harness has it now.
      source.failure = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      await _decoded(tester);
      expect(source.requests.length, 2);
      expect(_failed, findsNothing);
      expect(_drawn, findsOneWidget);
    });

    testWidgets('says what went wrong in words when it was no answer at all', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource()
        ..failure = const FormatException('The harness sent no picture.');
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/a.png'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(find.text('The harness sent no picture.'), findsOneWidget);
    });

    testWidgets('is nothing where no harness is able to give it', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource(available: false);
      await tester.pumpWidget(
        _app(
          const HarnessPicture(sessionId: 's-1', path: '/work/a.png'),
          source: source,
        ),
      );
      await _settle(tester);
      expect(source.requests, isEmpty);
      expect(_loading, findsNothing);
      expect(_drawn, findsNothing);
      expect(_failed, findsNothing);
      // And with no source at all, as a widget on its own has none.
      await tester.pumpWidget(
        _app(const HarnessPicture(sessionId: 's-1', path: '/work/a.png')),
      );
      await _settle(tester);
      expect(_drawn, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('can be drawn only for a session that is known', (
      tester,
    ) async {
      await _phone(tester);
      final results = <String?, bool>{};
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              for (final id in [null, '', 's-1']) {
                results[id] = canDrawPictures(context, id);
              }
              return const SizedBox.shrink();
            },
          ),
          source: FakeSource(),
        ),
      );
      expect(results, {null: false, '': false, 's-1': true});
    });
  });

  group('what a call handed back', () {
    TranscriptState transcript(List<Map<String, Object?>> nodes) {
      final transcript = TranscriptState(sessionId: 's-1');
      for (final node in nodes) {
        transcript.applyNode(node);
      }
      transcript.finish();
      return transcript;
    }

    List<Map<String, Object?>> readFile(
      List<Map<String, Object?>> attachments, {
      String path = '/work/shots/chat.png',
    }) => [
      {
        'id': 'a',
        'kind': 'tool-call',
        'tool': 'read_file',
        'call-id': 'c',
        'title': 'Read file: shots/chat.png',
        'input': {'path': 'shots/chat.png'},
      },
      {
        'id': 'b',
        'kind': 'tool-result',
        'call-id': 'c',
        'output': 'Image chat.png (image/png, 12 KiB, 800x600 px).',
        'attachments': attachments,
      },
    ];

    Future<void> open(
      WidgetTester tester,
      TranscriptState state, {
      FakeSource? source,
      String title = 'Read file: shots/chat.png',
    }) async {
      await _phone(tester);
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 2000,
            child: TranscriptView(items: state.items, showThinking: true),
          ),
          source: source,
        ),
      );
      await _settle(tester);
      await tester.tap(find.textContaining(title));
      await _settle(tester);
    }

    testWidgets('is drawn: the picture a read_file call read', (tester) async {
      final source = FakeSource();
      await open(
        tester,
        transcript(
          readFile([
            {
              'path': '/work/shots/chat.png',
              'mime': 'image/png',
              'size': 12000,
              'name': 'chat.png',
            },
          ]),
        ),
        source: source,
      );
      // The call's session is asked for the file the call names.
      await _decoded(tester);
      expect(source.requests, [('s-1', '/work/shots/chat.png')]);
      expect(_drawn, findsOneWidget);
      expect(find.text('PICTURE'), findsOneWidget);
      expect(find.text('ATTACHMENTS'), findsNothing);
      // The words that describe it come under it.
      expect(find.textContaining('Image chat.png (image/png'), findsOneWidget);
      final picture = tester.getTopLeft(_drawn).dy;
      final words = tester
          .getTopLeft(find.textContaining('Image chat.png (image/png'))
          .dy;
      expect(picture, lessThan(words));
    });

    testWidgets('is named where the harness gives no pictures', (tester) async {
      final source = FakeSource(available: false);
      await open(
        tester,
        transcript(
          readFile([
            {
              'path': '/work/shots/chat.png',
              'mime': 'image/png',
              'name': 'chat.png',
            },
          ]),
        ),
        source: source,
      );
      expect(source.requests, isEmpty);
      expect(_drawn, findsNothing);
      expect(find.text('ATTACHMENTS'), findsOneWidget);
      expect(find.text('chat.png'), findsOneWidget);
      expect(find.textContaining('Image chat.png (image/png'), findsOneWidget);
    });

    testWidgets('is drawn for the pictures and names the rest', (tester) async {
      final source = FakeSource();
      await open(
        tester,
        transcript(
          readFile([
            {
              'path': '/work/shots/chat.png',
              'mime': 'image/png',
              'name': 'chat.png',
            },
            {'path': '/work/clip.mp4', 'mime': 'video/mp4', 'name': 'clip.mp4'},
            {
              'path': '/work/scan.tiff',
              'mime': 'image/tiff',
              'name': 'scan.tiff',
            },
          ]),
        ),
        source: source,
      );
      // Only a picture the app can draw is asked for.
      expect(source.requests, [('s-1', '/work/shots/chat.png')]);
      expect(_drawn, findsOneWidget);
      expect(find.text('ATTACHMENTS'), findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('scan.tiff'), findsOneWidget);
    });

    testWidgets('is named when the call is of no known session', (
      tester,
    ) async {
      final state = TranscriptState();
      for (final node in readFile([
        {
          'path': '/work/shots/chat.png',
          'mime': 'image/png',
          'name': 'chat.png',
        },
      ])) {
        state.applyNode(node);
      }
      final source = FakeSource();
      await open(tester, state, source: source);
      expect(source.requests, isEmpty);
      expect(find.text('ATTACHMENTS'), findsOneWidget);
    });

    testWidgets('is drawn larger on the call\'s page of its own', (
      tester,
    ) async {
      await _phone(tester);
      final source = FakeSource();
      final state = transcript(
        readFile([
          {
            'path': '/work/shots/chat.png',
            'mime': 'image/png',
            'name': 'chat.png',
          },
        ]),
      );
      await tester.pumpWidget(
        PictureScope(
          source: source,
          child: HarnessStyle(
            style: HarnessPlatformStyle.material,
            child: MaterialApp(
              theme: HarnessTheme.material(Brightness.light),
              home: ToolDetailScreen(tool: state.toolsByCallId['c']!),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(source.requests, [('s-1', '/work/shots/chat.png')]);
      expect(_drawn, findsOneWidget);
      expect(find.text('PICTURE'), findsOneWidget);
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
    });
  });

  group('the evidence a task handed in', () {
    TranscriptState handIn({String? sessionId = toolShowcaseId}) {
      final transcript = TranscriptState(sessionId: sessionId);
      for (final node in toolShowcaseNodes()) {
        if (node['call-id'] == 'call-hand-in') transcript.applyNode(node);
      }
      transcript.finish();
      return transcript;
    }

    Future<void> openHandIn(
      WidgetTester tester,
      TranscriptState state,
      FakeSource? source,
    ) async {
      await _phone(tester);
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 3000,
            child: TranscriptView(items: state.items, showThinking: true),
          ),
          source: source,
        ),
      );
      await _settle(tester);
      await tester.tap(find.textContaining('Hand in the finished work'));
      await _settle(tester);
    }

    const shots = '/tmp/harness-1000/$toolShowcaseId/shots';

    testWidgets('shows its screenshots under the line that names them', (
      tester,
    ) async {
      final source = FakeSource();
      await openHandIn(tester, handIn(), source);
      // Both screenshots, by the paths the report names, of the session that
      // handed them in.
      expect(source.requests, [
        (toolShowcaseId, '$shots/android-tool-call.png'),
        (toolShowcaseId, '$shots/android-hand-in.png'),
      ]);
      expect(_drawn, findsNWidgets(2));
      // Each stands under its line, and above the next piece of evidence.
      final first = find.textContaining('A bash call opened');
      await tester.ensureVisible(first);
      await tester.pump();
      expect(
        tester.getTopLeft(_drawn.first).dy,
        greaterThan(tester.getBottomLeft(first).dy),
      );
      expect(
        tester.getBottomLeft(_drawn.last).dy,
        lessThan(tester.getTopLeft(find.text('The analyzer')).dy),
      );
      // Their names stay, for those who read the report to its end.
      expect(find.text('android-tool-call.png'), findsOneWidget);
    });

    testWidgets('names them where the harness gives no pictures', (
      tester,
    ) async {
      final source = FakeSource(available: false);
      await openHandIn(tester, handIn(), source);
      expect(source.requests, isEmpty);
      expect(_drawn, findsNothing);
      expect(find.text('android-tool-call.png'), findsOneWidget);
      expect(find.text('android-hand-in.png'), findsOneWidget);
    });

    testWidgets('names them in a call of no known session', (tester) async {
      final source = FakeSource();
      await openHandIn(tester, handIn(sessionId: null), source);
      expect(source.requests, isEmpty);
      expect(find.text('android-tool-call.png'), findsOneWidget);
    });

    testWidgets('says of a picture that is gone that it is, and names it', (
      tester,
    ) async {
      final source = FakeSource()
        ..failure = const AcpException(
          -32603,
          'android-hand-in.png is gone from the harness’s machine, or cannot be read',
        );
      await openHandIn(tester, handIn(), source);
      expect(_failed, findsNWidgets(2));
      expect(
        find.textContaining('is gone from the harness’s machine'),
        findsNWidgets(2),
      );
      // The rest of the report is there.
      expect(find.text('PROBLEM'), findsOneWidget);
      expect(find.text('The analyzer'), findsOneWidget);
    });

    testWidgets('shows them larger in the call\'s full view', (tester) async {
      await _phone(tester);
      final source = FakeSource();
      final tool = handIn().toolsByCallId['call-hand-in']!;
      await tester.pumpWidget(
        PictureScope(
          source: source,
          child: HarnessStyle(
            style: HarnessPlatformStyle.material,
            child: MaterialApp(
              theme: HarnessTheme.material(Brightness.light),
              home: ToolDetailScreen(tool: tool),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(source.requests.length, 2);
      expect(_drawn, findsNWidgets(2));
      expect(find.byType(EvidenceRow), findsNWidgets(5));
    });

    testWidgets('does not draw what the app cannot draw', (tester) async {
      await _phone(tester);
      final source = FakeSource();
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              EvidenceRow(
                item: EvidenceItem(kind: 'image', path: '/work/scan.tiff'),
                sessionId: 's-1',
              ),
              EvidenceRow(
                item: EvidenceItem(kind: 'video', path: '/work/clip.mp4'),
                sessionId: 's-1',
              ),
              EvidenceRow(
                item: EvidenceItem(kind: 'file', path: '/work/notes.txt'),
                sessionId: 's-1',
              ),
            ],
          ),
          source: source,
        ),
      );
      await _settle(tester);
      // A TIFF, a video and a file are named.
      expect(source.requests, isEmpty);
      expect(_drawn, findsNothing);
      expect(find.text('scan.tiff'), findsWidgets);
      expect(find.text('clip.mp4'), findsWidgets);
      expect(find.text('notes.txt'), findsWidgets);
    });
  });
}
