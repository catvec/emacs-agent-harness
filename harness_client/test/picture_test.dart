// The pictures of the harness's machine, before any of them is drawn: what the
// harness answers for one (`session/image`), which files the app can draw, how
// a call knows the session it was made in, and how the app keeps the pictures
// it fetched (once for each, bounded, and forgotten with the connection).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/acp/acp_client.dart';
import 'package:harness_client/src/acp/capabilities.dart';
import 'package:harness_client/src/models/picture.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/models/transcript.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/pictures.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_image_picker.dart';

const _shot = '/work/task/shots/android-chat.png';

Future<(FakeHarness, AppController)> _connect({
  bool sessionPictures = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(sessionPictures: sessionPictures);
  harness.pictureFiles[_shot] = (mime: 'image/png', bytes: onePixelPng);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp');
  addTearDown(app.dispose);
  return (harness, app);
}

void main() {
  group('a picture the harness gives', () {
    test('is its bytes and the type they are', () {
      final picture = Picture.fromWire({
        'mime': 'image/png',
        'name': 'shot.png',
        'size': onePixelPng.length,
        'data': base64Encode(onePixelPng),
      });
      expect(picture.bytes, onePixelPng);
      expect(picture.mime, 'image/png');
      expect(picture.name, 'shot.png');
      expect(picture.isSvg, isFalse);
      expect(
        Picture.fromWire({'mime': 'image/svg+xml', 'data': 'PHN2Zy8+'}).isSvg,
        isTrue,
      );
    });

    test('is a PNG unless the harness says what else', () {
      expect(Picture.fromWire({'data': 'AAAA'}).mime, 'image/png');
    });

    test('is none when the answer holds no data or damaged data', () {
      expect(
        () => Picture.fromWire({'mime': 'image/png'}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'The harness sent no picture.',
          ),
        ),
      );
      expect(
        () => Picture.fromWire({'data': 'not base64 !'}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'The picture the harness sent is damaged.',
          ),
        ),
      );
    });
  });

  group('the app draws', () {
    test(
      'what is a PNG, a JPEG, a GIF, a WebP, a BMP or an SVG by its type',
      () {
        for (final mime in [
          'image/png',
          'image/jpeg',
          'image/gif',
          'image/webp',
          'image/bmp',
          'image/svg+xml',
          'IMAGE/PNG',
        ]) {
          expect(isDrawablePicture(mime), isTrue, reason: mime);
        }
        // A type it cannot draw is a file to it, whatever the name says.
        expect(isDrawablePicture('image/tiff', 'scan.png'), isFalse);
        expect(isDrawablePicture('video/mp4', 'clip.png'), isFalse);
        expect(isDrawablePicture('application/pdf'), isFalse);
      },
    );

    test('what has no type by the extension of its name', () {
      expect(isDrawablePicture(null, '/tmp/shot.PNG'), isTrue);
      expect(isDrawablePicture('', 'photo.jpeg'), isTrue);
      expect(isDrawablePicture('application/octet-stream', 'a.svg'), isTrue);
      expect(isDrawablePicture(null, 'scan.tiff'), isFalse);
      expect(isDrawablePicture(null, 'README'), isFalse);
      expect(isDrawablePicture(null, 'png'), isFalse);
      expect(isDrawablePicture(null), isFalse);
    });
  });

  group('a harness', () {
    test(
      'that has session/image gives pictures, one that has not does not',
      () {
        HarnessCapabilities capabilities(List<String> methods) =>
            HarnessCapabilities.fromInitialize({
              'protocolVersion': 1,
              '_harness': {'methods': methods},
            });
        expect(capabilities(['session/image']).sessionImages, isTrue);
        expect(capabilities(['session/get']).sessionImages, isFalse);
        final feature = capabilities(['session/image']).features
            .firstWhere((feature) => feature.name == 'Pictures');
        expect(feature.enabled, isTrue);
        expect(
          capabilities([]).features
              .firstWhere((feature) => feature.name == 'Pictures')
              .enabled,
          isFalse,
        );
      },
    );
  });

  group('a call', () {
    test('knows the session of the transcript it is in', () {
      final transcript = TranscriptState(sessionId: 's-1');
      transcript.apply({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'live',
        'title': 'Read file',
        'status': 'in_progress',
        '_harness': {'tool': 'read_file'},
      });
      // A result whose call this transcript never saw.
      transcript.apply({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'stray',
        'status': 'completed',
      });
      transcript.applyNode({
        'id': 'n1',
        'kind': 'tool-call',
        'call-id': 'replayed',
        'tool': 'read_file',
      });
      transcript.applyNode({
        'id': 'n2',
        'kind': 'tool-result',
        'call-id': 'result-only',
        'output': 'ok',
      });
      expect(transcript.toolsByCallId.keys, [
        'live',
        'stray',
        'replayed',
        'result-only',
      ]);
      for (final tool in transcript.toolsByCallId.values) {
        expect(tool.sessionId, 's-1', reason: tool.callId);
      }
    });

    test('knows none when the transcript is of no session', () {
      final transcript = TranscriptState();
      transcript.applyNode({
        'id': 'n1',
        'kind': 'tool-call',
        'call-id': 'c',
        'tool': 'read_file',
      });
      expect(transcript.toolsByCallId['c']!.sessionId, isNull);
    });
  });

  group('the evidence of a report', () {
    final report = TaskReport.fromWire({
      'summary': 'Done.',
      'evidence': [
        {'kind': 'image', 'path': _shot, 'caption': 'The chat'},
        {'image': '/work/task/shots/other.png'},
        {'kind': 'note', 'text': 'Checked by hand'},
        {'kind': 'note', 'text': '   '},
        {'caption': 'nothing else'},
        {'tool_call': 'bash#2'},
      ],
    });

    test('is read as items, those that say nothing left out', () {
      expect(report.items.map((item) => item.kind), [
        'image',
        'image',
        'note',
        'note',
        'tool-call',
      ]);
      expect(report.items.first.path, _shot);
    });

    test('is a line for each, as the task sheet has it', () {
      expect(report.evidenceLines, [
        'Screenshot: The chat',
        'Screenshot: other.png',
        'Checked by hand',
        'Tool call: bash#2',
      ]);
      expect(TaskReport.evidenceLine(report.items[3]), '');
    });
  });

  group('the pictures the app keeps', () {
    test('are fetched once for each file of a session', () async {
      final (harness, app) = await _connect();
      expect(app.pictures.available, isTrue);
      final first = await app.pictures.load('s-1', _shot);
      final again = await app.pictures.load('s-1', _shot);
      expect(identical(first, again), isTrue);
      expect(first.bytes, onePixelPng);
      expect(first.name, 'android-chat.png');
      expect(harness.imageRequests, [('s-1', _shot)]);
      // Another session may show another file of the same name.
      await app.pictures.load('s-2', _shot);
      expect(harness.imageRequests.length, 2);
      expect(app.pictures.count, 2);
      expect(app.pictures.bytes, onePixelPng.length * 2);
    });

    test('are known at once once they have come, and not after', () async {
      final (harness, app) = await _connect();
      expect(app.pictures.peek('s-1', _shot), isNull);
      final asked = app.pictures.load('s-1', _shot);
      // On its way, it is not there yet.
      expect(app.pictures.peek('s-1', _shot), isNull);
      final picture = await asked;
      await Future<void>.delayed(Duration.zero);
      expect(identical(app.pictures.peek('s-1', _shot), picture), isTrue);
      expect(app.pictures.peek('s-2', _shot), isNull);
      expect(harness.imageRequests.length, 1);
      app.pictures.clear();
      expect(app.pictures.peek('s-1', _shot), isNull);
    });

    test('are asked for again after a failure, which is not kept', () async {
      final (harness, app) = await _connect();
      harness.failImagesWith = 'The picture is larger than 16 MiB';
      await expectLater(
        app.pictures.load('s-1', _shot),
        throwsA(
          isA<AcpException>().having(
            (error) => error.message,
            'message',
            'The picture is larger than 16 MiB',
          ),
        ),
      );
      expect(app.pictures.count, 0);
      harness.failImagesWith = null;
      expect((await app.pictures.load('s-1', _shot)).bytes, onePixelPng);
      expect(harness.imageRequests.length, 2);
    });

    test('are the newest ones when more than the limit are held', () async {
      final (harness, app) = await _connect();
      for (final name in ['a', 'b', 'c']) {
        harness.pictureFiles['/work/$name.png'] = (
          mime: 'image/png',
          bytes: Uint8List(40),
        );
      }
      final pictures = HarnessPictures(() => app.api, limit: 100);
      await pictures.load('s-1', '/work/a.png');
      await pictures.load('s-1', '/work/b.png');
      expect(pictures.count, 2);
      // A third does not fit with both: the oldest goes.
      await pictures.load('s-1', '/work/c.png');
      expect(pictures.count, 2);
      expect(pictures.bytes, 80);
      await pictures.load('s-1', '/work/b.png');
      await pictures.load('s-1', '/work/c.png');
      expect(harness.imageRequests.length, 3, reason: 'b and c are kept');
      await pictures.load('s-1', '/work/a.png');
      expect(harness.imageRequests.length, 4, reason: 'a was dropped');
      // A picture larger than the limit is kept for as long as it is the
      // newest, so that what is looked at is not fetched over and over.
      final small = HarnessPictures(() => app.api, limit: 10);
      await small.load('s-1', '/work/a.png');
      expect(small.count, 1);
      await small.load('s-1', '/work/a.png');
      expect(harness.imageRequests.length, 5);
    });

    test('go with the connection', () async {
      final (harness, app) = await _connect();
      await app.pictures.load('s-1', _shot);
      expect(app.pictures.count, 1);
      await app.disconnect();
      expect(app.pictures.count, 0);
      expect(app.pictures.bytes, 0);
      expect(app.pictures.available, isFalse);
      await expectLater(
        app.pictures.load('s-1', _shot),
        throwsA(isA<AcpException>()),
      );
      expect(harness.imageRequests.length, 1);
    });

    test('are none from a harness that does not give them', () async {
      final (harness, app) = await _connect(sessionPictures: false);
      expect(app.pictures.available, isFalse);
      expect(harness.imageRequests, isEmpty);
    });
  });
}
