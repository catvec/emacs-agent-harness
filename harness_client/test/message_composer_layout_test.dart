// The message box at a phone's width and a large text size: the field keeps
// the width for words, and the controls take a row of their own instead of
// squeezing a placeholder into a column of single letters.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/models/chat_thread.dart';
import 'package:harness_client/src/ui/adaptive/platform_style.dart';
import 'package:harness_client/src/ui/theme/harness_theme.dart';
import 'package:harness_client/src/ui/widgets/chat_threads.dart';
import 'package:harness_client/src/ui/widgets/message_composer.dart';

const _agentRef = ChatThreadRef(
  kind: 'chat',
  node: 'n1',
  who: 'agent',
  session: 's1',
  text: 'The parser is split in three.',
);

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 700,
  double textScale = 2,
  bool reply = false,
  bool keyboard = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  if (keyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
  }
  await tester.pumpWidget(
    HarnessStyle(
      style: HarnessPlatformStyle.material,
      child: MaterialApp(
        theme: HarnessTheme.material(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox.shrink()),
              MessageComposer(
                onSend: (_, _) => true,
                onStop: () {},
                running: false,
                cancelling: false,
                canAttach: true,
                canVoice: true,
                header: reply
                    ? ChatReplyBar(
                        draft: const ChatReplyDraft(
                          refs: [_agentRef],
                          threadId: 't-1',
                        ),
                        onCancel: () {},
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _field => find.byKey(const Key('composer-field'));

/// Where a line of [text] ends, as a line of the field's hint is drawn: the
/// same style, the same text size, the width the field leaves for its words.
List<(int, int)> _lines(WidgetTester tester, String text) {
  final hint = find.text('Message');
  final widget = tester.widget<Text>(hint);
  final size = tester.getSize(_field);
  final painter = TextPainter(
    text: TextSpan(text: text, style: widget.style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(tester.element(hint)),
  )..layout(maxWidth: size.width - 30);
  final ranges = <(int, int)>[];
  for (var at = 0; at < text.length; at++) {
    final range = painter.getLineBoundary(TextPosition(offset: at));
    if (ranges.isEmpty ||
        ranges.last.$1 != range.start ||
        ranges.last.$2 != range.end) {
      ranges.add((range.start, range.end));
    }
  }
  return ranges;
}

void main() {
  for (final width in <double>[320, 360]) {
    testWidgets('the field has the width of the phone at ${width.toInt()}', (
      tester,
    ) async {
      await _pump(tester, width: width);
      final size = tester.getSize(_field);
      expect(
        size.width,
        greaterThanOrEqualTo(width - 24),
        reason: 'the controls are not beside the field',
      );
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Message the harness'), findsNothing);
      expect(find.byKey(const Key('composer-controls')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('composer-send'))).width,
        greaterThanOrEqualTo(42),
      );
      expect(
        tester.getSize(find.byKey(const Key('composer-attach'))).width,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('a word is not broken letter by letter at $width', (
      tester,
    ) async {
      await _pump(tester, width: width);
      // The placeholder is one line, and a sentence breaks between words.
      final message = _lines(tester, 'Message');
      expect(message, hasLength(1));
      const sentence =
          'The composer still covers the last message when the keyboard '
          'opens on a small screen.';
      final lines = _lines(tester, sentence);
      expect(lines.length, greaterThan(1));
      for (final (start, end) in lines) {
        if (end >= sentence.length) continue;
        // A line ends at a space, not in the middle of a word.
        expect(
          sentence[end - 1] == ' ' || sentence[end] == ' ',
          isTrue,
          reason:
              'line $start–$end breaks a word: ${sentence.substring(start, end)}',
        );
      }
    });

    testWidgets('the keyboard lifts the box and the reply bar at $width', (
      tester,
    ) async {
      await _pump(tester, width: width, reply: true, keyboard: true);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      expect(tester.getSize(_field).width, greaterThanOrEqualTo(width - 24));
      final send = tester.getRect(find.byKey(const Key('composer-send')));
      expect(send.bottom, lessThanOrEqualTo(700 - 280 + 1));
      await tester.enterText(
        _field,
        'Words that must stay whole when they wrap.',
      );
      await tester.pump();
      expect(find.text('Reply'), findsOneWidget);
      expect(
        tester.getSize(find.byType(MessageComposer)).height,
        lessThanOrEqualTo(420),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('with the keyboard down the box sits at the bottom at $width', (
      tester,
    ) async {
      await _pump(tester, width: width, reply: true);
      expect(find.text('Reply'), findsOneWidget);
      expect(tester.getSize(_field).width, greaterThanOrEqualTo(width - 24));
      final send = tester.getRect(find.byKey(const Key('composer-send')));
      expect(send.bottom, greaterThan(650));
    });

    testWidgets('a message of one\'s own has the same room at $width', (
      tester,
    ) async {
      await _pump(tester, width: width);
      await tester.enterText(_field, 'An ordinary message with no reply.');
      await tester.pump();
      expect(tester.getSize(_field).width, greaterThanOrEqualTo(width - 24));
      expect(find.byTooltip('Cancel reply'), findsNothing);
    });

    testWidgets(
      'a long message scrolls in the field, it is not cut at $width',
      (tester) async {
        await _pump(tester, width: width);
        final long = List.generate(
          12,
          (i) => 'Line ${i + 1} of a message that is longer than the box.',
        ).join('\n');
        await tester.enterText(_field, long);
        await tester.pump();
        // The box keeps its height; the words are all still in the field, which
        // scrolls them rather than cutting them off.
        expect(
          tester.getSize(_field).height,
          lessThanOrEqualTo(190),
          reason: 'the field grows past the room left for the conversation',
        );
        final editable = tester.widget<EditableText>(find.byType(EditableText));
        expect(editable.controller.text, long);
        expect(find.text(long), findsOneWidget);
      },
    );
  }

  testWidgets('a wide window keeps the controls beside the field', (
    tester,
  ) async {
    await _pump(tester, width: 900, height: 800, textScale: 1);
    expect(find.byKey(const Key('composer-controls')), findsNothing);
    expect(find.text('Message'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
