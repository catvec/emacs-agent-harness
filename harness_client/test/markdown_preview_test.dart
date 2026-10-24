// A row of a list shows the first words of something written in Markdown: a
// task's card, the report it was handed in with.  Those words are the text
// without its syntax -- no `##`, no asterisks, no backticks, no `](url)` --
// since a row cannot draw a heading or a list, and a person reads the
// markers as noise.
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_client/src/ui/format.dart';

void main() {
  group('the words of Markdown', () {
    test('a heading is its words, and the text under it follows', () {
      expect(
        markdownPreview('## What was wrong\n\nThe board showed raw text.'),
        'What was wrong · The board showed raw text.',
      );
      expect(
        markdownPreview('# One\n### Three ###\nBody'),
        'One · Three · Body',
      );
      // Setext headings keep their words, and drop the line under them.
      expect(markdownPreview('Title\n=====\nBody'), 'Title · Body');
      expect(markdownPreview('Title\n-----\nBody'), 'Title · Body');
    });

    test('the lines of an item run on, the items do not', () {
      expect(
        markdownPreview('- one item\n  that goes on\n- another\n\nAfter it'),
        'one item that goes on · another · After it',
      );
    });

    test('the lines of a paragraph run on, the paragraphs do not', () {
      expect(
        markdownPreview(
          'One line\nanother   line\n\nA second one\nof two lines',
        ),
        'One line another line · A second one of two lines',
      );
    });

    test('bold, italics, strikethrough and code are their words', () {
      expect(
        markdownPreview('**Fixed** the _board_ and *cards*, not ~~lists~~.'),
        'Fixed the board and cards, not lists.',
      );
      expect(
        markdownPreview('Run `flutter test` and ``a ` tick`` now'),
        'Run flutter test and a ` tick now',
      );
      expect(markdownPreview('***both*** and __strong__'), 'both and strong');
    });

    test('a link is its text and a picture its description', () {
      expect(
        markdownPreview(
          'See [the docs](https://example.com/a_(b)) and ![a shot](x.png), '
          '[the run](harness:call/bash#2), [ref][1] or <https://example.com>.',
        ),
        'See the docs and a shot, the run, ref or https://example.com.',
      );
    });

    test('list markers, quotes, rules and fences are dropped', () {
      expect(
        markdownPreview('- one\n* two\n+ three\n1. four\n2) five'),
        'one · two · three · four · five',
      );
      expect(markdownPreview('- [x] done\n- [ ] to do'), 'done · to do');
      expect(
        markdownPreview('> quoted\n> > deeper\n\n---\nafter'),
        'quoted deeper · after',
      );
      expect(
        markdownPreview('Run:\n\n```dart\nvoid main() {}\n```\n\nDone.'),
        'Run: · void main() {} · Done.',
      );
      expect(markdownPreview('~~~\ncode\n~~~'), 'code');
    });

    test('a table is its cells', () {
      expect(markdownPreview('| a | b |\n|---|:-:|\n| 1 | 2 |'), 'a b · 1 2');
    });

    test('words that only look like syntax stay as they are', () {
      // Underscores inside a word, spaced asterisks, a lone marker.
      expect(
        markdownPreview('call snake_case_name; 2 * 3 * 4; a * b; 5 > 3'),
        'call snake_case_name; 2 * 3 * 4; a * b; 5 > 3',
      );
      expect(
        markdownPreview('match *.dart and *.el files'),
        'match *.dart and *.el files',
      );
      // A generic type is not an HTML tag.
      expect(
        markdownPreview('a `List<int>` and a Future<String>'),
        'a List<int> and a Future<String>',
      );
      // An escape is its character.
      expect(
        markdownPreview(r'a \*literal\* star and a \# hash'),
        'a *literal* star and a # hash',
      );
    });

    test('HTML tags go, their words stay', () {
      expect(
        markdownPreview('one<br>two <b>bold</b> <!-- gone --> three'),
        'one two bold three',
      );
    });

    test('it is cut to a line of at most max characters', () {
      final long = '**${'word ' * 60}end**';
      final preview = markdownPreview(long, max: 40);
      expect(preview.length, 40);
      expect(preview, endsWith('…'));
      expect(preview, isNot(contains('*')));
      expect(markdownPreview('short'), 'short');
    });

    test('nothing, or only syntax, is nothing', () {
      expect(markdownPreview(''), '');
      expect(markdownPreview('  \n\n  '), '');
      expect(markdownPreview('---\n***\n```\n```'), '');
    });

    test('plain text is left alone, its line breaks made spaces', () {
      expect(
        markdownPreview('One line\nanother   line'),
        'One line another line',
      );
    });
  });
}
