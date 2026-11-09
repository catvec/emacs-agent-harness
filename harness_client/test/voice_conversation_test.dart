import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/voice/voice_conversation.dart';

void main() {
  group('distillation', () {
    test('removes mumbles and keeps content words', () {
      const cases = <String, String?>{
        'Uh, add a docstring, um, to the the parser.':
            'add a docstring to the parser.',
        'so, um, what I want is, uh, a queue.':
            'so what I want is a queue.',
        'I want to I want to add a test.': 'I want to add a test.',
        'You know, the parser is slow.': 'the parser is slow.',
        "It's like, really slow.": "It's like, really slow.",
        "It's like really slow.": "It's like really slow.",
        'Er, the, er, test is broken.': 'the test is broken.',
        '[BLANK_AUDIO] um [laughter].': null,
        'Um, uh, hmm.': null,
      };
      cases.forEach((raw, expected) {
        expect(distilledVoiceText(raw), expected, reason: raw);
      });
    });

    test('never removes content or real doubles', () {
      const kept = <String>[
        'Add a comment to TokenBucket.take about its refill and retry behavior.',
        'I mean it.',
        'I mean the parser, not the tokenizer.',
        'had had enough',
        'that that is wrong',
        'what it is is a bug',
        'Read parsers.py:12 and fix it.',
        'Yes.',
        'Right.',
        'Uh-huh.',
      ];
      for (final text in kept) {
        expect(distilledVoiceText(text), text, reason: text);
      }
      final distilled = distilledVoiceText(
        'Uh, add a docstring, um, to the the parser.',
      )!;
      expect(distilled, contains('docstring'));
      expect(distilled, contains('parser'));
      expect(distilled, isNot(contains('um')));
      expect(distilled, isNot(contains('uh')));
    });

    test('keeps only the correction the speaker made', () {
      const cases = <String, String?>{
        'add a test, no wait, add a docstring': 'add a docstring',
        'add a test, I mean, add a docstring': 'add a docstring',
        'use a queue, actually, use the timer': 'use the timer',
        'Actually, add a test.': 'add a test.',
        'add a test, no wait': 'add a test, no wait',
      };
      cases.forEach((raw, expected) {
        expect(distilledVoiceText(raw), expected, reason: raw);
      });
    });

    test('distilling a distilled request changes nothing more', () {
      const cases = <String>[
        'Uh, add a docstring, um, to the the parser.',
        'so, um, what I want is, uh, a queue.',
        'add a test, no wait, add a docstring',
        'I want to I want to add a test.',
        'You know, the parser is slow.',
      ];
      for (final raw in cases) {
        final once = distilledVoiceText(raw);
        expect(distilledVoiceText(once), once, reason: raw);
      }
    });

    test('a long utterance stays fast', () {
      final words = List<String>.generate(400, (_) => 'parser um uh the');
      final text = 'Uh, ${words.join(' ')}, no wait, fix it.';
      final watch = Stopwatch()..start();
      final result = distilledVoiceText(text);
      watch.stop();
      expect(result, isNotNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('the conversation', () {
    test('records both sides and keeps the raw words', () {
      final conversation = VoiceConversation();
      conversation.hear(
        raw: 'Uh, use a queue, no wait, use the timer.',
        distilled: 'use the timer',
        sent: 'use the timer',
      );
      conversation.say('The timer is replaced.', source: 'result');
      final turns = conversation.turns;
      expect(turns, hasLength(2));
      expect(turns.first.speaker, VoiceConversationSpeaker.voice);
      expect(turns.first.text, 'The timer is replaced.');
      final user = turns.last;
      expect(user.speaker, VoiceConversationSpeaker.user);
      expect(user.raw, 'Uh, use a queue, no wait, use the timer.');
      expect(user.text, 'use the timer');
      expect(user.sent, 'use the timer');
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
        conversation.hear(
          raw: 'request $index',
          distilled: 'request $index',
        );
      }
      expect(conversation.turns, hasLength(3));
      expect(conversation.turns.first.raw, 'request 4');
      conversation.clear();
      expect(conversation.turns, isEmpty);
    });
  });

  group('the session message', () {
    test('a self-contained request travels without a wrapper', () {
      final conversation = VoiceConversation();
      conversation.say(
        'The timer wakes it every 200 ms.',
        source: 'commentary',
      );
      for (final text in const <String>[
        'Fix the failing parser test.',
        'Use a queue instead of polling.',
        'Make the parser faster so it handles big files.',
      ]) {
        expect(conversation.request(text), text);
      }
    });

    test('a dependent request carries what it points at', () {
      final conversation = VoiceConversation();
      conversation.say(
        'the timer wakes it every 200 ms',
        source: 'commentary',
      );
      conversation.say(
        'that would keep the old poll alive',
        source: 'result',
      );
      conversation.hear(
        raw: 'use a queue instead',
        distilled: 'use a queue instead',
        sent: 'use a queue instead',
      );
      final request = conversation.request('do that');
      expect(request, startsWith('do that\n\n'));
      expect(request, contains('Voice conversation before this request:\n'));
      expect(request, contains('Person: use a queue instead'));
      expect(
        request,
        contains('Voice: that would keep the old poll alive'),
      );
      expect(
        'Voice conversation before this request:'.allMatches(request).length,
        1,
      );
      expect(
        conversation.request('yes'),
        contains('Voice conversation before this request:'),
      );
    });

    test('the context block keeps its budgets', () {
      final conversation = VoiceConversation(
        contextTurns: 10,
        contextChars: 200,
        turnChars: 40,
      );
      for (var index = 0; index < 10; index++) {
        conversation.say(
          'voice turn $index ${'x' * 80}',
          source: 'commentary',
        );
      }
      final block = conversation.context!;
      expect(block.length, lessThanOrEqualTo(200));
      expect('\n'.allMatches(block).length, 4);
      expect(block, contains('voice turn 9'));
      expect(block, isNot(contains('voice turn 6 ')));
      expect(block, contains('…'));
    });

    test('backchannels are recorded but not context', () {
      final conversation = VoiceConversation();
      conversation.say('mm-hmm', source: 'backchannel');
      conversation.say(
        'The parser has two entry points.',
        source: 'commentary',
      );
      final block = conversation.context!;
      expect(block, contains('The parser has two entry points.'));
      expect(block, isNot(contains('mm-hmm')));
      expect(conversation.turns, hasLength(2));
    });

    test('the context can be turned off', () {
      final conversation = VoiceConversation(carryContext: false);
      conversation.say(
        'The timer wakes it every 200 ms.',
        source: 'commentary',
      );
      expect(conversation.request('do that'), 'do that');
    });

    test('distillation can be turned off', () {
      final conversation = VoiceConversation(distill: false);
      expect(
        conversation.distilledText('Uh, add a test.'),
        'Uh, add a test.',
      );
    });
  });
}
