/// The voice conversation of one call.
///
/// Voice has two records, not one.  The *voice conversation* is what was said
/// and heard on the audio side: every user utterance as the speech model
/// returned it, and every line the voice actually spoke.  A *session message*
/// is what crosses into the chat: the transcript, sent as it came back from
/// speech to text.
///
/// There is no distillation and no context envelope.  An earlier version
/// removed hesitation sounds here, and added a bounded block of earlier voice
/// turns to a request that looked dependent.  Both were wrong for the same
/// reason: a request is not a thing to be rewritten, and the session's own
/// agent is the only reader that can tell which earlier turn a pronoun points
/// at.  The agent sees the conversation it is in; the voice only delivers the
/// words, in the event that carried them.  The Emacs client is the same, in
/// `lisp/ui/harness-ui-voice-conversation.el`; the design is in
/// `docs/design/voice-conversation.md`.
library;

import 'dart:math' as math;

/// One turn of the voice conversation.
enum VoiceConversationSpeaker { user, voice }

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

  /// The words of a user turn, as the speech model returned them; for a
  /// voice turn, what was spoken.
  final String? text;

  /// The raw transcript, as the speech model returned it.  User turns only.
  final String? raw;

  /// The message that crossed into the session, which is [raw] itself.
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
    this.recordChars = 4000,
  });

  final int maxTurns;
  final int recordChars;

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

  /// Record that the person said [raw], and that [sent] crossed into the
  /// session.  [sent] is [raw] itself: nothing is added to the message and
  /// nothing is taken out.
  VoiceConversationTurn? hear({
    required String raw,
    String? sent,
  }) {
    final line = _oneLine(raw, recordChars);
    if (line.isEmpty) return null;
    final turn = VoiceConversationTurn(
      id: 'v-${++_seq}',
      speaker: VoiceConversationSpeaker.user,
      raw: line,
      text: line,
      sent: sent ?? line,
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

  void _trim() {
    final limit = math.max(1, maxTurns);
    while (_turns.length > limit) {
      _turns.removeLast();
    }
  }
}
