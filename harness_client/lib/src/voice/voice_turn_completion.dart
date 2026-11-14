/// Why a transcribed conversational turn has not been submitted yet.
///
/// This conservative English fallback is shared with the other clients through
/// test/fixtures/voice-turn-completion.json. It does not infer prosody or rewrite
/// the person's words. Audio-only prompts have no words to classify.
enum VoiceTurnReason { grace, continuation, cutOff }

extension VoiceTurnReasonLabel on VoiceTurnReason {
  String get label => switch (this) {
    VoiceTurnReason.grace => 'Finishing thought',
    VoiceTurnReason.continuation => 'Waiting for continuation',
    VoiceTurnReason.cutOff => 'Possible cut-off',
  };
}

final _quoted = RegExp('"[^"\\n]*"|\'[^\'\\n]*\'|“[^”\\n]*”|‘[^’\\n]*’');
final _terminal = RegExp(r'[\s.!?,;:…—–-]+$');
final _pause = RegExp(
  r'\b(?:one (?:second|sec|moment)|hold on(?: (?:a|one) (?:second|sec|moment))?'
  r'|let me think|give me (?:a|one) (?:moment|second|sec)'
  r'|wait(?: (?:a|one))? (?:sec(?:ond)?|moment)'
  r'|(?:i )?(?:need to )?catch my breath|um+|uh+|erm+|hmm+)$',
);
final _named = RegExp(
  r'\b(?:called|named|labelled|labeled|phrase|word|says?|message is)\s*$',
);
final _dangling = RegExp(
  r'\b(?:and|or|but|because|although|unless|whereas|whether|if|when|while'
  r'|with|without|to|from|into|onto|in|on|at|about|of|for|by|than|that|which'
  r'|the|a|an|my|your|our|their|its)$',
);
final _requestStem = RegExp(
  r'^(?:(?:please )?(?:could|would|can|will) you'
  r'|i (?:want|need|would like)(?: you)?(?: to)?)$',
);
final _recovery = RegExp(
  r'^(?:please[\s,]+)?(?:continue|go\s+on)(?:[\s,]+please)?[.!?,;:]*$',
  caseSensitive: false,
);

/// A standalone recovery cue, not an embedded or quoted mention of one.
bool isVoiceTurnRecovery(String text) => _recovery.hasMatch(text.trim());

VoiceTurnReason classifyVoiceTurn(String text, {bool truncated = false}) {
  // Named/quoted pause phrases are content, not an instruction to wait.
  final unquoted = text.toLowerCase().replaceAll(_quoted, ' ').trim();
  final ending = unquoted.replaceFirst(_terminal, '').trim();
  final pauseEnding = ending.replaceFirst(RegExp(r',?\s+please$'), '');
  final pause = _pause.firstMatch(pauseEnding);
  final namedPause = pause != null &&
      _named.hasMatch(pauseEnding.substring(0, pause.start));
  if (pause != null && !namedPause) {
    return VoiceTurnReason.continuation;
  }
  if (truncated || RegExp(r'(?:\.{2,}|…|[—–-])\s*$').hasMatch(unquoted)) {
    return VoiceTurnReason.cutOff;
  }
  // The whole named phrase is content; its final "on" is not a dangling
  // preposition either. A real hard cut above still takes precedence.
  if (namedPause) return VoiceTurnReason.grace;
  // A complete wh-question can naturally end in a preposition.
  final question = unquoted.endsWith('?') &&
      RegExp(r'^(?:what|which|who|where|when|why|how)\b').hasMatch(ending) &&
      RegExp(r'\b(?:with|without|to|from|into|onto|in|on|at|about|of|for|by)$')
          .hasMatch(ending);
  final completeCommand = isVoiceTurnRecovery(text) ||
      RegExp(r'^(?:please )?(?:turn .+ on|log in|sign in)$').hasMatch(ending);
  if (_requestStem.hasMatch(ending) ||
      (!question && !completeCommand && _dangling.hasMatch(ending))) {
    return VoiceTurnReason.cutOff;
  }
  return VoiceTurnReason.grace;
}
