/// The voice conversation and the request it sends to the session.
///
/// Voice has two records, not one.  The *voice conversation* is what was said
/// and heard on the audio side: every user utterance as the speech model
/// returned it, and every line the voice actually spoke.  A *session message*
/// is what crosses into the chat: a request distilled from one delegation,
/// and -- only when the request cannot stand alone -- the last few turns of
/// the voice conversation.
///
/// Distillation is local and deterministic.  It removes hesitation sounds,
/// comma-set discourse markers, stutters and an explicit self-correction;
/// every content word, name, path and number stays, and the raw transcript is
/// never rewritten.  Context is the last few turns that fit a small budget,
/// in plain text with speaker labels, and a self-contained request travels
/// without it.  The rules and their alternatives are in
/// `docs/design/voice-conversation.md`; the Emacs client has the same rules in
/// `lisp/ui/harness-ui-voice-conversation.el`.
library;

import 'dart:math' as math;

/// One turn of the voice conversation.
enum VoiceConversationSpeaker { user, voice }

const List<String> _hesitations = <String>[
  'um', 'umm', 'ummm', 'uh', 'uhh', 'uhm', 'er', 'erm', 'ah', 'eh',
  'hmm', 'hmmm',
];
const List<String> _affirmations = <String>['uh-huh', 'mm-hmm', 'mhm', 'mm'];
const List<String> _realDoubles = <String>['had', 'that', 'is', 'do', 'be'];
const String _annotationWords =
    r'noise|music|laugh|applause|silence|blank|inaudible|cough|sigh|clap|beep|sneeze|breath|crosstalk';
final RegExp _annotation =
    RegExp(r'\[[^\][]*\]|\([^()]*\)|\*[^*\n]*|♪|♫');
final RegExp _annotationNote = RegExp(_annotationWords, caseSensitive: false);
final RegExp _commaSetHesitation = RegExp(
  ',([ \t]*)(${_hesitations.map(RegExp.escape).join('|')})[ \t]*,',
  caseSensitive: false,
);
final RegExp _affirmationOnly = RegExp(
  '^[ \\t]*(${_affirmations.map(RegExp.escape).join('|')})[ \\t]*[.!?]?[ \\t]*\$',
  caseSensitive: false,
);
final RegExp _stutter = RegExp(
  r"(\b(?:[A-Za-z'’-]+[,]?[ \t]+){0,2}[A-Za-z'’-]+)[,;:]?[ \t]+\1\b",
  caseSensitive: false,
);
final RegExp _repair = RegExp(
  r'(?:\bno[,]?[ \t]+wait\b'
  r'|\bwait[,]?[ \t]+no\b'
  r'|\bsorry\b[,]?[ \t]+i[ \t]+mean\b'
  r'|,[ \t]*i[ \t]+mean\b'
  r'|,[ \t]*actually\b'
  r'|^[ \t]*actually\b)[,;:]?[ \t]*',
  caseSensitive: false,
);

String _wordsRegexp(Iterable<String> words) =>
    r'\b(?:' + words.map(RegExp.escape).join('|') + r')\b[,;:]?[ \t]*';

String _stripAnnotations(String text) => text.replaceAllMapped(
  _annotation,
  (match) => _annotationNote.hasMatch(match[0]!) ? ' ' : match[0]!,
);

String _stripDiscourse(String text) {
  var result = text.replaceAll(
    RegExp(r',[ \t]*(?:you know|i mean|like)[ \t]*,', caseSensitive: false),
    ',',
  );
  result = result.replaceAll(
    RegExp(
      r'^[ \t]*(?:you know|i mean|like)[ \t]*,[ \t]*',
      caseSensitive: false,
    ),
    '',
  );
  return result.replaceAllMapped(
    RegExp(
      r',[ \t]*(?:you know|i mean)[ \t]*([.!?]|$)',
      caseSensitive: false,
    ),
    (match) => match[1] ?? '',
  );
}

String _repairText(String text) {
  var result = text;
  for (var guard = 0; guard < 8; guard++) {
    final match = _repair.firstMatch(result);
    if (match == null) break;
    final after = result.substring(match.end);
    if (!RegExp(r'[A-Za-z0-9]').hasMatch(after)) break;
    result = after;
  }
  return result;
}

String _removeWords(String text, Iterable<String> words) => text.replaceAll(
  RegExp(_wordsRegexp(words), caseSensitive: false),
  '',
);

String _removeAffirmations(String text) {
  final without = _removeWords(text, _affirmations);
  return RegExp(r'[A-Za-z0-9]').hasMatch(without) ? without : text;
}

String _collapseStutters(String text) {
  var result = text;
  for (var guard = 0; guard < 8; guard++) {
    final next = result.replaceAllMapped(_stutter, (match) {
      final phrase = match[1]!;
      return !phrase.contains(RegExp(r'\s')) &&
              _realDoubles.contains(phrase.toLowerCase())
          ? match[0]!
          : phrase;
    });
    if (next == result) break;
    result = next;
  }
  return result;
}

String _tidy(String text) {
  var result = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  result = result.replaceAllMapped(
    RegExp(r' +([,.;:!?])'),
    (match) => match[1]!,
  );
  result = result.replaceAllMapped(
    RegExp(r'([,;:])\s*\1+'),
    (match) => match[1]!,
  );
  result = result.replaceAllMapped(
    RegExp(r'([,;:])\s*([.!?])'),
    (match) => match[2]!,
  );
  result = result.replaceAll(RegExp(r'^[\s,;:]+'), '');
  result = result.replaceAll(RegExp(r'[\s,;:]+$'), '');
  return result.trim();
}

/// Return [text] with only its mumbles removed, or null when nothing is left.
///
/// Hesitation sounds, comma-set discourse markers, stutters, an explicit
/// self-correction and non-speech annotations go; content words, names,
/// paths, numbers, casing and punctuation stay.  This starts no process,
/// timer or model call.
String? distilledVoiceText(String? text) {
  if (text == null) return null;
  var result = text.trim();
  if (result.isEmpty) return null;
  result = _stripAnnotations(result);
  result = _repairText(result);
  result = _stripDiscourse(result);
  if (_affirmationOnly.hasMatch(result)) {
    // A bare `uh-huh` is a yes, not a mumble.
    return _tidy(result);
  }
  result = _removeAffirmations(result);
  result = result.replaceAll(_commaSetHesitation, ' ');
  result = _removeWords(result, _hesitations);
  result = _collapseStutters(result);
  result = _tidy(result);
  return RegExp(r'[A-Za-z0-9]').hasMatch(result) ? result : null;
}

const List<String> _anaphora = <String>[
  'it', 'its', "it's", 'that', "that's", 'this', 'these', 'those', 'them',
  'they', 'their', 'theirs', 'there', 'then', 'one', 'ones',
];
const List<String> _alwaysDependent = <String>[
  'same', 'other', 'another', 'previous', 'earlier', 'before', 'again',
  'also', 'too', 'either', 'both', 'latter', 'former', 'such',
];
const List<String> _answers = <String>[
  'yes', 'yeah', 'yep', 'no', 'nope', 'okay', 'ok', 'sure', 'right',
  'correct', 'wrong', 'continue', 'stop', 'wait',
];
const List<String> _continuations = <String>[
  'and', 'but', 'then', 'now', 'also', 'again',
];
final RegExp _dependentPhrases = RegExp(
  r'\bdo[ \t]+(?:it|that|this)\b'
  r'|\bgo[ \t]+ahead\b'
  r'|\bkeep[ \t]+going\b'
  r'|\bcarry[ \t]+on\b'
  r'|\bthe[ \t]+(?:first|second|third|last|next|other|same)[ \t]+one\b'
  r'|\b(?:same|other)[ \t]+(?:thing|one)\b'
  r'|^[ \t]*(?:fix|change|update|add|remove|delete|use|make)[ \t]+(?:it|that|this)\b',
  caseSensitive: false,
);

/// Whether [text] points at something it does not name.
///
/// A pronoun counts near the start, or in a request of six words or fewer, so
/// a longer sentence that names its own subject and says `it` later does not
/// ask for context.  An answer or continuation at the start, a word that
/// always links to an earlier turn, and a deictic phrase anywhere, do.
bool voiceRequestNeedsContext(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  final words = trimmed
      .toLowerCase()
      .split(RegExp(r"[^A-Za-z']+"))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return false;
  final head = words.take(4).toSet();
  bool near(List<String> candidates) =>
      candidates.any(head.contains) ||
      (words.length <= 6 && candidates.any(words.contains));
  if (near(_anaphora)) return true;
  if (words.any(_alwaysDependent.contains)) return true;
  if (_answers.contains(words.first) || _continuations.contains(words.first)) {
    return true;
  }
  return _dependentPhrases.hasMatch(trimmed);
}

/// One line of the voice conversation.
class VoiceConversationTurn {
  const VoiceConversationTurn({
    required this.id,
    required this.speaker,
    this.text,
    this.raw,
    this.sent,
    this.source,
    this.time,
  });

  final String id;
  final VoiceConversationSpeaker speaker;

  /// The distilled request for a user turn; null when nothing was sent.  For
  /// a voice turn, what was spoken.
  final String? text;

  /// The raw transcript, as the speech model returned it.  User turns only.
  final String? raw;

  /// The whole message that crossed into the session, context included.
  final String? sent;

  /// Where a voice line came from: `commentary`, `result`, `provider`,
  /// `backchannel` or `open`.
  final String? source;

  final DateTime? time;

  VoiceConversationTurn copyWith({String? text}) => VoiceConversationTurn(
    id: id,
    speaker: speaker,
    text: text ?? this.text,
    raw: raw,
    sent: sent,
    source: source,
    time: time,
  );
}

const String contextHeader = 'Voice conversation before this request:\n';

String _oneLine(String? text, int limit) {
  if (text == null) return '';
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.length <= limit) return line;
  return '${line.substring(0, limit - 1)}…';
}

/// The voice conversation of one call.
///
/// It is bounded, cleared when a call starts or ends, and kept by the client
/// that owns the call rather than by the chat session.
class VoiceConversation {
  VoiceConversation({
    this.maxTurns = 40,
    this.contextTurns = 4,
    this.contextChars = 700,
    this.turnChars = 240,
    this.recordChars = 4000,
    this.carryContext = true,
    this.distill = true,
  });

  final int maxTurns;
  final int contextTurns;
  final int contextChars;
  final int turnChars;
  final int recordChars;
  final bool carryContext;
  final bool distill;

  final List<VoiceConversationTurn> _turns = <VoiceConversationTurn>[];
  int _seq = 0;

  /// Newest first.
  List<VoiceConversationTurn> get turns =>
      List<VoiceConversationTurn>.unmodifiable(_turns);

  bool get isEmpty => _turns.isEmpty;

  void clear() {
    _turns.clear();
    _seq = 0;
  }

  /// The request text, unchanged when this client is not distilling.
  String? distilledText(String text) {
    if (!distill) {
      final trimmed = text.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return distilledVoiceText(text);
  }

  /// Record that the person said [raw] and that [distilled] crossed.
  VoiceConversationTurn? hear({
    required String raw,
    String? distilled,
    String? sent,
  }) {
    final line = _oneLine(raw, recordChars);
    if (line.isEmpty) return null;
    final turn = VoiceConversationTurn(
      id: 'v-${++_seq}',
      speaker: VoiceConversationSpeaker.user,
      raw: line,
      text: distilled == null || distilled.trim().isEmpty
          ? null
          : distilled.trim(),
      sent: sent,
      time: DateTime.now(),
    );
    _turns.insert(0, turn);
    _trim();
    return turn;
  }

  /// Record that the voice said [text].
  ///
  /// A [stream] fragment grows the newest voice turn instead of starting one.
  /// A complete line that contains the turns after it absorbs them, so a
  /// result that repeats its own sentences is recorded once.
  void say(String text, {String source = 'commentary', bool stream = false}) {
    final line = _oneLine(text, recordChars);
    if (line.isEmpty) return;
    final last = _turns.isEmpty ? null : _turns.first;
    if (last != null &&
        last.speaker == VoiceConversationSpeaker.voice &&
        last.text == line) {
      return;
    }
    if (stream &&
        last != null &&
        last.speaker == VoiceConversationSpeaker.voice) {
      _turns[0] = last.copyWith(
        text: _oneLine('${last.text ?? ''} $line', recordChars),
      );
      _trim();
      return;
    }
    var absorb = 0;
    while (absorb < _turns.length) {
      final turn = _turns[absorb];
      final old = turn.text;
      if (turn.speaker != VoiceConversationSpeaker.voice ||
          turn.source == 'backchannel' ||
          old == null ||
          old.isEmpty ||
          !line.contains(old)) {
        break;
      }
      absorb++;
    }
    if (absorb > 0) {
      _turns.removeRange(0, absorb);
    }
    if (_turns.isNotEmpty) {
      final next = _turns.first;
      final old = next.text;
      if (next.speaker == VoiceConversationSpeaker.voice &&
          old != null &&
          old.contains(line)) {
        return;
      }
    }
    _turns.insert(
      0,
      VoiceConversationTurn(
        id: 'v-${++_seq}',
        speaker: VoiceConversationSpeaker.voice,
        text: line,
        source: source,
        time: DateTime.now(),
      ),
    );
    _trim();
  }

  /// The bounded plain-text context block, or null when nothing fits.
  String? get context {
    // Newest first while the budget is applied; the block itself reads
    // oldest first, like a conversation.
    final kept = <VoiceConversationTurn>[];
    var total = contextHeader.length;
    for (final turn in _turns) {
      if (kept.length >= math.max(1, contextTurns)) break;
      final text = _contextText(turn);
      if (text == null) continue;
      kept.add(turn.copyWith(text: text));
      total += _label(turn.speaker).length + 3 + text.length;
    }
    while (kept.length > 1 && total > contextChars) {
      final removed = kept.removeLast();
      total -=
          _label(removed.speaker).length + 3 + (removed.text?.length ?? 0);
    }
    if (kept.isEmpty) return null;
    final body = kept.reversed
        .map((turn) => '${_label(turn.speaker)}: ${turn.text}')
        .join('\n');
    return '$contextHeader$body\n';
  }

  /// The session message: [text], with bounded context when it needs it.
  String request(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        !carryContext ||
        !voiceRequestNeedsContext(trimmed)) {
      return trimmed;
    }
    final block = context;
    return block == null ? trimmed : '$trimmed\n\n$block';
  }

  void _trim() {
    final limit = math.max(1, maxTurns);
    while (_turns.length > limit) {
      _turns.removeLast();
    }
  }

  String? _contextText(VoiceConversationTurn turn) {
    final text = turn.text;
    if (text == null || text.isEmpty) return null;
    if (turn.speaker == VoiceConversationSpeaker.voice &&
        turn.source == 'backchannel') {
      return null;
    }
    final limit = math.max(8, turnChars);
    return text.length > limit
        ? '${text.substring(0, limit - 1)}…'
        : text;
  }

  String _label(VoiceConversationSpeaker speaker) =>
      speaker == VoiceConversationSpeaker.user ? 'Person' : 'Voice';
}
