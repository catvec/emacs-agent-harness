import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_conversation.dart';

void main() {
  group('the record', () {
    test('keeps the words as heard', () {
      const cases = <String>[
        'Uh, add a docstring, um, to the the parser.',
        'add a test, no wait, add a docstring',
        'I want to I want to add a test.',
        'You know, the parser is slow.',
        'Yes.',
        'Uh-huh.',
      ];
      for (final raw in cases) {
        final conversation = VoiceConversation();
        conversation.hear(raw: raw);
        final turn = conversation.turns.single;
        expect(turn.raw, raw, reason: raw);
        expect(turn.text, raw, reason: raw);
        expect(turn.sent, raw, reason: raw);
      }
    });

    test('adds nothing to the message', () {
      final conversation = VoiceConversation();
      conversation.say(
        'The timer wakes it every 200 ms.',
        source: 'commentary',
      );
      conversation.hear(raw: 'do that');
      final turn = conversation.turns.first;
      expect(turn.sent, 'do that');
      expect(turn.sent, isNot(contains('Voice conversation')));
      expect(turn.sent, isNot(contains('The timer wakes it')));
    });
  });

  group('the conversation', () {
    test('records both sides and keeps the raw words', () {
      final conversation = VoiceConversation();
      conversation.hear(raw: 'Uh, use a queue, no wait, use the timer.');
      conversation.say('The timer is replaced.', source: 'result');
      final turns = conversation.turns;
      expect(turns, hasLength(2));
      expect(turns.first.speaker, VoiceConversationSpeaker.voice);
      expect(turns.first.text, 'The timer is replaced.');
      final user = turns.last;
      expect(user.speaker, VoiceConversationSpeaker.user);
      expect(user.raw, 'Uh, use a queue, no wait, use the timer.');
      expect(user.text, 'Uh, use a queue, no wait, use the timer.');
      expect(user.sent, 'Uh, use a queue, no wait, use the timer.');
    });

    test('a full result absorbs its streamed pieces', () {
      final conversation = VoiceConversation();
      conversation.say('The parser is ready.', source: 'commentary');
      conversation.say('The tests pass.', source: 'commentary');
      conversation.say(
        'The parser is ready. The tests pass.',
        source: 'result',
      );
      expect(conversation.turns, hasLength(1));
      expect(
        conversation.turns.single.text,
        'The parser is ready. The tests pass.',
      );
      conversation.say(
        'The parser is ready. The tests pass.',
        source: 'result',
      );
      expect(conversation.turns, hasLength(1));
    });

    test('provider caption fragments are one voice turn', () {
      final conversation = VoiceConversation();
      conversation.say('I can', source: 'provider', stream: true);
      conversation.say('do that.', source: 'provider', stream: true);
      expect(conversation.turns, hasLength(1));
      expect(conversation.turns.single.text, 'I can do that.');
    });

    test('keeps the newest turns only', () {
      final conversation = VoiceConversation(maxTurns: 3);
      for (var index = 0; index < 5; index++) {
        conversation.hear(raw: 'request $index');
      }
      expect(conversation.turns, hasLength(3));
      expect(conversation.turns.first.raw, 'request 4');
      conversation.clear();
      expect(conversation.turns, isEmpty);
    });
  });
}
