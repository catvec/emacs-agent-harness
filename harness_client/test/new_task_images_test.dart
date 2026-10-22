import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/app.dart';
import 'package:harness_client/src/acp/acp_message.dart';
import 'package:harness_client/src/models/task.dart';
import 'package:harness_client/src/state/app_controller.dart';
import 'package:harness_client/src/state/settings_controller.dart';
import 'package:harness_client/src/ui/widgets/image_attachments.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_harness.dart';
import 'support/fake_image_picker.dart';

class _Rig {
  _Rig(this.settings, this.harness, this.app);
  final SettingsController settings;
  final FakeHarness harness;
  final AppController app;
}

Future<_Rig> _rig({bool taskPictures = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsController();
  await settings.load();
  final harness = FakeHarness(taskPictures: taskPictures);
  final app = AppController(settings: settings, connector: harness.connector);
  await app.connect('ws://memory/acp', token: '');
  return _Rig(settings, harness, app);
}

Future<void> _pump(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HarnessApp(settings: rig.settings, appController: rig.app),
  );
  await tester.pump();
  await _settle(tester, 8);
}

Future<void> _settle(WidgetTester tester, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The picker a person would use, which gives [choose]; put back after.
FakeImagePicker _picker(List<XFile> Function() choose) {
  final previous = ImagePickerPlatform.instance;
  final picker = FakeImagePicker(choose);
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = previous);
  return picker;
}

/// Open the new task sheet.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Tasks'));
  await _settle(tester, 5);
  await tester.tap(find.byIcon(Icons.add_rounded));
  await _settle(tester, 4);
  expect(find.text('Submit task'), findsOneWidget);
}

Finder get _promptField => find.ancestor(
  of: find.text('Describe the change, the bug, or the question…'),
  matching: find.byType(TextField),
);

Finder get _attach => find.byKey(const Key('task-attach'));

Finder _thumbnail(String name) => find.byWidgetPredicate(
  (widget) =>
      widget is ImageAttachmentThumbnail && widget.attachment.name == name,
);

/// The `task/submit` requests the harness got, with their params.
List<JsonMap> _submissions(_Rig rig) => [
  for (final (method, params) in rig.harness.requests)
    if (method == '_harness/task/submit') params,
];

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Submit task'));
  await tester.tap(find.text('Submit task'));
  await _settle(tester, 10);
}

void main() {
  testWidgets('the new task sheet attaches pictures and sends their bytes', (
    tester,
  ) async {
    final rig = await _rig();
    final jpeg = fakeJpeg();
    final picker = _picker(
      () => [
        pickedImage('layout.png', onePixelPng),
        pickedImage('camera.jpg', jpeg),
      ],
    );
    await _pump(tester, rig);
    await _openSheet(tester);
    expect(find.text('Attach images'), findsOneWidget);

    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    expect(picker.opened, 1);
    expect(_thumbnail('layout.png'), findsOneWidget);
    expect(_thumbnail('camera.jpg'), findsOneWidget);
    // The button now adds more, and the pictures wait in the draft too.
    expect(find.text('Add more'), findsOneWidget);
    expect(rig.app.drafts.task.attachments.map((a) => a.name), [
      'layout.png',
      'camera.jpg',
    ]);

    await tester.enterText(_promptField, 'Make the button look like this');
    await tester.pump();
    await _submit(tester);

    final sent = _submissions(rig).single;
    expect(sent['prompt'], 'Make the button look like this');
    final attachments = (asList(asMap(sent['opts'])['attachments']));
    expect(attachments, hasLength(2));
    final first = asMap(attachments[0]);
    expect(first['name'], 'layout.png');
    expect(first['mime'], 'image/png');
    expect(base64Decode(first['data'] as String), onePixelPng);
    final second = asMap(attachments[1]);
    expect(second['name'], 'camera.jpg');
    expect(second['mime'], 'image/jpeg');
    expect(base64Decode(second['data'] as String), jpeg);

    // Sent: nothing is kept of it, and the task carries its pictures.
    expect(rig.app.drafts.task.isEmpty, isTrue);
    expect(rig.app.drafts.task.attachments, isEmpty);
    final task = rig.harness.tasks.values.last;
    expect((task['attachments'] as List).length, 2);
  });

  testWidgets('a picture can be taken off again before the task is sent', (
    tester,
  ) async {
    final rig = await _rig();
    _picker(
      () => [
        pickedImage('one.png', onePixelPng),
        pickedImage('two.png', onePixelPng),
      ],
    );
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    expect(find.byType(ImageAttachmentThumbnail), findsNWidgets(2));

    await tester.tap(
      find.descendant(
        of: _thumbnail('one.png'),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await _settle(tester, 3);
    expect(_thumbnail('one.png'), findsNothing);
    expect(_thumbnail('two.png'), findsOneWidget);
    expect(rig.app.drafts.task.attachments.map((a) => a.name), ['two.png']);

    await tester.enterText(_promptField, 'Only the second');
    await tester.pump();
    await _submit(tester);
    final attachments = asList(
      asMap(_submissions(rig).single['opts'])['attachments'],
    );
    expect(attachments.map((a) => asMap(a)['name']), ['two.png']);
  });

  testWidgets('a task with no pictures is sent as it always was', (
    tester,
  ) async {
    final rig = await _rig();
    _picker(() => const []);
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 4);
    expect(find.byType(ImageAttachmentThumbnail), findsNothing);
    expect(find.text('Attach images'), findsOneWidget);

    await tester.enterText(_promptField, 'Words only');
    await tester.pump();
    await _submit(tester);
    expect(
      asMap(_submissions(rig).single['opts']).containsKey('attachments'),
      isFalse,
    );
  });

  testWidgets(
    'the pictures stay with the description when the sheet is closed',
    (tester) async {
      final rig = await _rig();
      _picker(() => [pickedImage('keep.png', onePixelPng)]);
      await _pump(tester, rig);
      await _openSheet(tester);
      await tester.ensureVisible(_attach);
      await tester.tap(_attach);
      await _settle(tester, 6);
      // Pictures alone are worth keeping, as words are.
      expect(rig.app.drafts.task.isEmpty, isFalse);

      // Closed without sending, by accident.
      Navigator.of(tester.element(find.text('Submit task'))).pop();
      await _settle(tester, 6);
      expect(find.text('Submit task'), findsNothing);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await _settle(tester, 4);
      expect(_thumbnail('keep.png'), findsOneWidget);
    },
  );

  testWidgets('no more than four pictures go with a task', (tester) async {
    final rig = await _rig();
    _picker(
      () => [for (var i = 1; i <= 6; i++) pickedImage('p$i.png', onePixelPng)],
    );
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    expect(find.byType(ImageAttachmentThumbnail), findsNWidgets(4));
    expect(rig.app.drafts.task.attachments, hasLength(4));
    // Nothing more to attach.
    expect(_attach, findsNothing);
  });

  testWidgets('a picture the harness would refuse is kept off, and said', (
    tester,
  ) async {
    final rig = await _rig();
    final bitmap = Uint8List.fromList([0x42, 0x4D, 0, 0, 0, 0]);
    final huge = Uint8List(maxTaskImageBytes + 1)
      ..setAll(0, onePixelPng.sublist(0, 8));
    _picker(
      () => [
        pickedImage('photo.bmp', bitmap),
        pickedImage('wallpaper.png', huge),
        pickedImage('fine.png', onePixelPng),
      ],
    );
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    expect(_thumbnail('fine.png'), findsOneWidget);
    expect(_thumbnail('photo.bmp'), findsNothing);
    expect(_thumbnail('wallpaper.png'), findsNothing);
    final said = tester.widget<Text>(
      find.byKey(const Key('task-attachment-error')),
    );
    expect(
      said.data,
      contains(
        'photo.bmp is not a picture a task takes (PNG, JPEG, GIF, WEBP)',
      ),
    );
    expect(said.data, contains('wallpaper.png is larger than 10 MB'));
    // It is said as an error: in the error colour, not the muted one.
    final theme = Theme.of(
      tester.element(find.byKey(const Key('task-attachment-error'))),
    );
    expect(said.style?.color, theme.colorScheme.error);
    expect(rig.app.drafts.task.attachments.map((a) => a.name), ['fine.png']);
  });

  testWidgets('a picker that fails says so, and the sheet goes on', (
    tester,
  ) async {
    final rig = await _rig();
    _picker(() => throw StateError('no photo library here'));
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    final said = tester.widget<Text>(
      find.byKey(const Key('task-attachment-error')),
    );
    expect(said.data, contains('cannot open the photo picker'));
    expect(said.data, contains('no photo library here'));
    expect(find.text('Attach images'), findsOneWidget);
  });

  testWidgets(
    'a harness that does not say it takes pictures is not offered any',
    (tester) async {
      final rig = await _rig(taskPictures: false);
      final picker = _picker(() => [pickedImage('lost.png', onePixelPng)]);
      await _pump(tester, rig);
      await _openSheet(tester);
      expect(find.text('Attach images'), findsNothing);
      expect(_attach, findsNothing);
      expect(picker.opened, 0);
      // Tasks are sent as they were.
      await tester.enterText(_promptField, 'No pictures here');
      await tester.pump();
      await _submit(tester);
      expect(
        asMap(_submissions(rig).single['opts']).containsKey('attachments'),
        isFalse,
      );
    },
  );

  testWidgets('the task sheet shows the pictures a task was sent with', (
    tester,
  ) async {
    final rig = await _rig();
    _picker(() => [pickedImage('shown.png', onePixelPng)]);
    await _pump(tester, rig);
    await _openSheet(tester);
    await tester.ensureVisible(_attach);
    await tester.tap(_attach);
    await _settle(tester, 6);
    await tester.enterText(_promptField, 'Show me');
    await tester.pump();
    await _submit(tester);

    await tester.tap(find.text('Show me').first);
    await _settle(tester, 6);
    expect(find.text('ATTACHMENTS'), findsOneWidget);
    expect(find.text('shown.png'), findsOneWidget);
  });

  testWidgets('the message composer attaches pictures as it did', (
    tester,
  ) async {
    final rig = await _rig();
    final picker = _picker(() => [pickedImage('shot.png', onePixelPng)]);
    await _pump(tester, rig);
    await tester.tap(find.text('Design the merge queue'));
    await _settle(tester, 6);
    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await _settle(tester, 4);
    expect(picker.opened, 1);
    expect(
      find.descendant(
        of: find.byType(MessageComposer),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('composer-send')));
    await _settle(tester, 6);
    final prompt = [
      for (final (method, params) in rig.harness.requests)
        if (method == 'session/prompt') params,
    ].single;
    final image = asMapList(prompt['prompt'])
        .firstWhere((block) => block['type'] == 'image');
    expect(image['mimeType'], 'image/png');
    expect(base64Decode(image['data'] as String), onePixelPng);
    expect(asMap(image['_harness'])['label'], 'shot.png');
  });

  group('pictures are known by their bytes', () {
    test('PNG, JPEG, GIF and WebP', () {
      expect(sniffImageMime(onePixelPng), 'image/png');
      expect(sniffImageMime(fakeJpeg()), 'image/jpeg');
      expect(
        sniffImageMime(Uint8List.fromList(ascii.encode('GIF89a....'))),
        'image/gif',
      );
      expect(
        sniffImageMime(Uint8List.fromList(ascii.encode('GIF87a....'))),
        'image/gif',
      );
      expect(
        sniffImageMime(
          Uint8List.fromList(
            ascii.encode('RIFF\u0000\u0000\u0000\u0000WEBPVP8 '),
          ),
        ),
        'image/webp',
      );
    });

    test('nothing else, whatever it is called', () {
      expect(sniffImageMime(Uint8List.fromList([0x42, 0x4D, 0, 0])), isNull);
      expect(
        sniffImageMime(Uint8List.fromList(ascii.encode('<svg></svg>'))),
        isNull,
      );
      expect(sniffImageMime(Uint8List(0)), isNull);
      // A WAVE file shares its RIFF header with WebP.
      expect(
        sniffImageMime(
          Uint8List.fromList(
            ascii.encode('RIFF\u0000\u0000\u0000\u0000WAVEfmt '),
          ),
        ),
        isNull,
      );
      // Too short to be what it starts like.
      expect(sniffImageMime(Uint8List.fromList([0x89, 0x50, 0x4E])), isNull);
    });

    test('a name is the last resort', () {
      expect(imageMimeOfName('a.PNG'), 'image/png');
      expect(imageMimeOfName('a.webp'), 'image/webp');
      expect(imageMimeOfName('a.gif'), 'image/gif');
      expect(imageMimeOfName('IMG_0001'), 'image/jpeg');
    });
  });

  group('what the harness says of a task', () {
    test('the files attached to it are named', () {
      final task = HarnessTask.fromWire({
        'id': 't-1',
        'attachments': [
          {'name': 'shot.png', 'path': '/state/attachments/t-1/shot.png'},
          {'path': '/state/attachments/t-1/other.png'},
          {'mime': 'image/png'},
        ],
      });
      expect(task.attachments, ['shot.png', 'other.png']);
      expect(HarnessTask.fromWire({'id': 't-2'}).attachments, isEmpty);
    });

    test('the settings name the types a task takes as data', () {
      final says = TaskSettingsInfo.fromWire({
        'inlineAttachments': ['image/png', 'image/jpeg'],
      });
      expect(says.takesImages, isTrue);
      expect(says.inlineAttachments, ['image/png', 'image/jpeg']);
      final kebab = TaskSettingsInfo.fromWire({
        'inline-attachments': ['image/webp'],
      });
      expect(kebab.takesImages, isTrue);
      // An older harness does not say: it takes none.
      expect(TaskSettingsInfo.fromWire({}).takesImages, isFalse);
      expect(
        TaskSettingsInfo.fromWire({
          'inlineAttachments': ['text/plain'],
        }).takesImages,
        isFalse,
      );
    });
  });
}
