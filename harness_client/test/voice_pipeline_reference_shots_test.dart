// True comparison sheets: the approved pixels themselves, and the app.
//
//   HARNESS_SHOTS=/some/directory flutter test test/voice_pipeline_reference_shots_test.dart
//
// Every sheet puts a crop of one of Noah's approved originals above a real
// screenshot of the app's own widget, at the same size, and says which file
// and which rectangle the crop came from.  The crops are committed under
// docs/media/voice-ribbon-review/reference-crops/ and cut by
// scripts/voice-ribbon-reference-crops.py, which records each one's source
// file, its SHA-256 and the exact rectangle in CROPS.json -- so nothing here
// is a redrawn impression of the approved picture, and the provenance of
// every pixel can be checked.
//
// The pictures are fixtures.  The events are the protocol's own, scripted
// rather than captured from a live microphone, and each sheet says so.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/voice_pipeline.dart';
import 'package:harness_client/src/ui/widgets/voice_ribbon.dart';
import 'package:harness_client/src/voice/voice_backend.dart';
import 'package:harness_client/src/voice/voice_pipeline.dart';

import 'support/real_fonts.dart';

final _now = DateTime(2026, 11, 7, 12, 4);

/// Every stage occupied at once, so a sheet shows all the bar forms together
/// the way the approved bar-language row does.
VoicePipelineSnapshot _allStages() => VoicePipelineSnapshot(
  generation: 1,
  input: VoiceInputState.live,
  level: 0.56,
  levelSeen: true,
  levelAt: _now,
  speechActive: true,
  segments: const [
    VoiceSegment(
      id: 'r-2',
      stage: VoicePipelineStage.dropped,
      generation: 1,
      duration: Duration(milliseconds: 640),
      drop: VoiceSegmentDrop.tooShort,
    ),
    VoiceSegment(
      id: 'u-4',
      stage: VoicePipelineStage.accepted,
      generation: 1,
      duration: Duration(milliseconds: 1400),
      text: 'and then the',
    ),
    VoiceSegment(
      id: 'u-3',
      stage: VoicePipelineStage.transcribing,
      generation: 1,
      duration: Duration(seconds: 2),
      text: 'check the merge queue',
      revision: 2,
    ),
    VoiceSegment(
      id: 'u-2',
      stage: VoicePipelineStage.transcribed,
      generation: 1,
      duration: Duration(seconds: 1),
      text: 'is the build green',
      revision: 1,
    ),
    VoiceSegment(
      id: 'u-1',
      stage: VoicePipelineStage.answered,
      generation: 1,
      duration: Duration(seconds: 3),
      text: 'run the tests',
      turnId: 't-1',
      revision: 1,
    ),
  ],
  turns: const [
    VoiceTurn(
      id: 't-1',
      stage: 'done',
      generation: 1,
      segmentIds: ['u-1'],
      replyIds: ['n-1'],
    ),
  ],
  replies: const [
    VoiceReply(
      id: 'n-1',
      stage: VoiceReplyStage.speaking,
      generation: 1,
      turnId: 't-1',
      text: 'They all pass.',
    ),
  ],
  accepted: 4,
  dropped: 1,
  spoken: 0,
  playing: true,
);

Widget _app(Widget child, Size size, {double scale = 1}) => HarnessStyle(
  style: HarnessPlatformStyle.material,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HarnessTheme.material(Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
      child: child,
    ),
  ),
);

/// The crops, read once and kept as decoded images.
class _Crops {
  _Crops._(this.manifest, this.images);

  final Map<String, dynamic> manifest;
  final Map<String, ui.Image> images;

  /// The crop's own recorded rectangle in the original, in its pixels.
  String box(String name) =>
      (manifest[name]['source_box'] as List).join(', ');

  /// The original file the crop came from.
  String source(String name) => manifest[name]['source'] as String;

  /// Where the crops live, found from this file rather than from the working
  /// directory: a suite run from a copy of the app still finds them, and one
  /// run where they are absent says so instead of failing to load.
  static Directory? directory() {
    var dir = Directory.current;
    for (var step = 0; step < 6; step++) {
      final crops = Directory(
        '${dir.path}/docs/media/voice-ribbon-review/reference-crops',
      );
      if (File('${crops.path}/CROPS.json').existsSync()) return crops;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static Future<_Crops?> load() async {
    final dir = directory();
    if (dir == null) return null;
    final manifest =
        jsonDecode(File('${dir.path}/CROPS.json').readAsStringSync())
            as Map<String, dynamic>;
    final images = <String, ui.Image>{};
    for (final entry in manifest.entries) {
      final file = File('${dir.path}/${entry.value['file'] as String}');
      final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
      final frame = await codec.getNextFrame();
      images[entry.key] = frame.image;
    }
    return _Crops._(manifest, images);
  }
}

/// A picture of one crop, drawn at WIDTH.
class _Crop extends StatelessWidget {
  const _Crop(this.image, this.width);

  final ui.Image image;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scale = width / image.width;
    return SizedBox(
      width: width,
      height: image.height * scale,
      child: RawImage(image: image, fit: BoxFit.contain),
    );
  }
}

/// The caption over a picture: what it is, and where it came from.
class _Caption extends StatelessWidget {
  const _Caption(this.text, {this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: muted ? const Color(0xFF7C838A) : const Color(0xFFC9CFD4),
        fontSize: 10,
        height: 1.3,
      ),
    );
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['HARNESS_SHOTS'];
  final real = await loadRealFonts();
  final suffix = real ? '' : '-ahem';
  final sheetCrops = await _Crops.load();
  // The sheets compare against the committed crops of Noah's originals.  A
  // copy of the app that does not carry them -- a build check that copies
  // harness_client alone -- has nothing to compare against, so the sheets say
  // they are skipped rather than failing to load.
  final skipSheets = sheetCrops == null;

  /// Draw one sheet: the approved pixels above the app, with what each is.
  Future<void> sheet(
    WidgetTester tester, {
    required String name,
    required String reference,
    required double width,
    required double height,
    required Widget widget,
    bool compact = false,
    double scale = 1,
    String note = '',
  }) async {
    const ratio = 2.0;
    tester.view.physicalSize = Size(width * ratio, height * ratio);
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    // A sheet only runs where the crops are, so the null case never reaches
    // here; the assertion is for the analyzer, not for a person.
    final crops = sheetCrops!;
    final image = crops.images[reference]!;
    // The crop is drawn at the sheet's own width, so the approved bar and the
    // app's bar are compared at one size rather than at two.
    // Draw the crop at the app pill's own height, so the approved bar and
    // the app's bar are compared at one size rather than at two.  The crop is
    // 123 px tall including its margin; the pill inside it is 111.
    final pillHeight = 46.0;
    // The linear crops are 111 px pills; the badge crop is a 145 px cell
    // holding a 135 px disc.  Each is drawn so the approved picture is at the
    // app's own scale rather than at a size of its own: the badge is drawn so
    // its disc is the size of the disc the app's ring draws, which is what
    // makes the two comparable at one scale rather than at two.
    final cropScale = compact
        ? VoiceRibbonView.ringDisc / 135.0
        : pillHeight / 111.0;
    final cropWidth = image.width * cropScale;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: _app(
          Theme(
            data: HarnessTheme.material(Brightness.dark),
            child: Scaffold(
              backgroundColor: const Color(0xFF0D0D0F),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Caption(
                      'Approved original · ${crops.source(reference)} '
                      '· crop ${crops.box(reference)}',
                    ),
                    const SizedBox(height: 4),
                    if (compact)
                      Center(child: _Crop(image, cropWidth))
                    else
                      _Crop(image, cropWidth),
                    const SizedBox(height: 12),
                    const _Caption(
                      'Implementation · harness_client, scripted events',
                    ),
                    const SizedBox(height: 4),
                    if (compact)
                      // The ring at its own size, so the approved badge beside
                      // it and the app's disc are compared at one scale.
                      SizedBox(
                        height: VoiceRibbonView.ringSide,
                        child: Center(child: widget),
                      )
                    else
                      SizedBox(height: 46, child: widget),
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _Caption(note, muted: true),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Size(width, height),
          scale: scale,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.takeException(), isNull);
    if (shots != null) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final picture = await render.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$shots/voice-ribbon-versus-$name$suffix.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data!.buffer.asUint8List());
      });
    }
  }

  testWidgets('ordinary', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'ordinary',
      reference: 'panel-a-ribbon',
      width: 560,
      height: 250,
      widget: VoicePipelineView(snapshot: _allStages(), clock: () => _now),
      note:
          'Rendering difference: the original is a vector drawing at its own '
          'size; this is the app painting the same bars at the pill height it '
          'is given.',
    );
  });

  testWidgets('narrow', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'narrow',
      reference: 'panel-a-ribbon',
      width: 330,
      height: 230,
      widget: VoicePipelineView(snapshot: _allStages(), clock: () => _now),
      note: 'A narrow full-size surface keeps the linear ribbon.',
    );
  });

  testWidgets('large text', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'large-text',
      reference: 'panel-a-ribbon',
      width: 460,
      height: 320,
      scale: 2,
      widget: VoicePipelineView(snapshot: _allStages(), clock: () => _now),
      note: 'At 200% text a full-size surface still keeps the linear ribbon.',
    );
  });

  testWidgets('compact', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'compact',
      // One approved badge, not the concept's four: the fixture is one stage,
      // and a row of four squeezed to the sheet's width would draw the
      // approved disc at a third of the ring's size and call it one scale.
      reference: 'buddy-words',
      width: 320,
      height: 430,
      compact: true,
      // A populated pipe, not one stage: the approved badge shows the rim's
      // whole treatment, so the comparison has to show the ring carrying
      // marks all the way round rather than two marks in one arc.
      widget: VoicePipelineView(
        snapshot: _allStages(),
        compact: true,
        clock: () => _now,
      ),
      note:
          'The approved badge shows one treatment round the whole rim; this '
          'compact surface carries the later clockwise pipe semantics, with '
          'the approved disc drawn at the ring\'s own size.',
    );
  });

  testWidgets('bar language', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'bar-language',
      reference: 'bar-language',
      width: 780,
      height: 290,
      widget: VoicePipelineView(snapshot: _allStages(), clock: () => _now),
      note:
          'The six approved stage shapes above; below, the app drawing all '
          'five stages and a drop at once.',
    );
  });

  testWidgets('emacs character cells', skip: skipSheets, (tester) async {
    await sheet(
      tester,
      name: 'emacs-cells',
      reference: 'client-emacs',
      width: 780,
      height: 280,
      widget: VoicePipelineView(snapshot: _allStages(), clock: () => _now),
      note:
          'The approved Emacs mockup draws the same pipe in character cells; '
          'the Emacs client\'s own two forms are docs/media/voice-ribbon.png '
          'and voice-ribbon-compact.png.',
    );
  });
}
