import 'dart:math' as math;
import 'dart:typed_data';

/// One recorded utterance: mono PCM16, at the detector's sample rate.
class VoiceUtterance {
  const VoiceUtterance({
    required this.samples,
    required this.sampleRate,
    required this.level,
  });

  final Int16List samples;
  final int sampleRate;

  /// The loudest frame of the utterance, 0..1, for the orb.
  final double level;

  Duration get duration =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);

  /// The clip as a RIFF/WAVE file, which ACP audio blocks, whisper.cpp and
  /// OpenAI's transcription endpoint all take.
  Uint8List get wav => encodeWav(samples, sampleRate: sampleRate);
}

/// Cuts a stream of arbitrary-size PCM16 chunks into frames of a fixed
/// duration, which is what the detector can judge.  A chunk that ends in the
/// middle of a sample is carried to the next one.
class PcmFramer {
  PcmFramer({this.sampleRate = 16000, this.frameMillis = 20})
    : _frameBytes = (sampleRate * frameMillis ~/ 1000) * 2;

  final int sampleRate;
  final int frameMillis;
  final int _frameBytes;
  Uint8List _leftover = Uint8List(0);

  /// The frames [bytes] completed, oldest first.  A partial frame stays here
  /// until the next call completes it.
  List<Int16List> add(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    final all = Uint8List(_leftover.length + bytes.length)
      ..setAll(0, _leftover)
      ..setAll(_leftover.length, bytes);
    final frames = <Int16List>[];
    var offset = 0;
    while (all.length - offset >= _frameBytes) {
      frames.add(_pcm16(all, offset, _frameBytes));
      offset += _frameBytes;
    }
    _leftover = offset == all.length ? Uint8List(0) : all.sublist(offset);
    return frames;
  }

  static Int16List _pcm16(Uint8List bytes, int offset, int length) {
    final view = ByteData.sublistView(bytes, offset, offset + length);
    final samples = Int16List(length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return samples;
  }
}

/// What counts as speech, and how long a pause ends an utterance.
class VoiceActivityConfig {
  const VoiceActivityConfig({
    this.sampleRate = 16000,
    this.frameMillis = 20,
    this.startThreshold = 0.018,
    this.endThreshold = 0.010,
    this.startHold = const Duration(milliseconds: 160),
    this.gateHold = const Duration(milliseconds: 60),
    this.gateEndSilence = const Duration(milliseconds: 320),
    this.echoThreshold = 0.055,
    this.echoHold = const Duration(milliseconds: 220),
    this.endSilence = const Duration(milliseconds: 850),
    this.preRoll = const Duration(milliseconds: 300),
    this.trailingKeep = const Duration(milliseconds: 200),
    this.minUtterance = const Duration(milliseconds: 240),
    this.maxUtterance = const Duration(seconds: 30),
  });

  final int sampleRate;
  final int frameMillis;

  /// RMS, as a fraction of full scale, at which a quiet stream starts speech.
  final double startThreshold;

  /// RMS under which a speaking stream counts as silent.  A little lower than
  /// [startThreshold] so a voice that trails off does not flicker.
  final double endThreshold;

  /// How much speech in a row starts an utterance.
  final Duration startHold;

  /// How much speech in a row flips the low-latency gate.  This is much
  /// shorter than [startHold]: the gate holds assistant output while the
  /// first words arrive, before the utterance is complete or transcribed.
  final Duration gateHold;

  /// How much silence closes the gate when it never became an utterance,
  /// such as a tap or a cough.
  final Duration gateEndSilence;

  /// The gate's threshold while the assistant's own speech may be in the
  /// microphone.  A device without echo cancellation can otherwise hear
  /// itself and interrupt itself.
  final double echoThreshold;

  /// How much speech in a row is needed to take the floor while assistant
  /// audio is playing.
  final Duration echoHold;

  /// How much silence ends one.
  final Duration endSilence;

  /// Audio kept from before the detector heard speech, so a clipped first
  /// syllable is not lost.
  final Duration preRoll;

  /// Silence kept at the end of a clip, so the last consonant survives.
  final Duration trailingKeep;

  /// A shorter burst is a cough, a door, or a tap: it is dropped.
  final Duration minUtterance;

  /// A longer utterance is cut here and sent; the next one starts after it.
  final Duration maxUtterance;

  int frames(Duration duration) =>
      math.max(1, duration.inMilliseconds ~/ frameMillis);
}

/// Energy-based voice activity detection over fixed PCM frames.
///
/// It is deliberately small and local: no audio leaves the device before an
/// utterance ends, and the clip that leaves is one utterance rather than a
/// continuous stream.  The live provider does not use it (WebRTC has its own
/// echo cancellation and the provider its own turn detection), but the clip
/// provider needs both ends of an utterance to make a WAV.
class VoiceActivityDetector {
  VoiceActivityDetector({this.config = const VoiceActivityConfig()});

  final VoiceActivityConfig config;

  final List<Int16List> _preRoll = <Int16List>[];
  final List<Int16List> _utterance = <Int16List>[];
  int _speechRun = 0;
  int _silenceRun = 0;
  int _gateRun = 0;
  int _gateSilence = 0;
  bool _speaking = false;
  bool _gateActive = false;
  double _level = 0;
  double _peak = 0;

  /// Whether the detector is in the middle of an utterance.
  bool get speaking => _speaking;

  /// Whether speech is active now, at the gate's shorter onset hold.
  ///
  /// This is the signal that must reach the assistant before a transcript
  /// exists.  It is true while the first words are heard and false after a
  /// short silence that never became an utterance.
  bool get gateActive => _gateActive;

  /// The smoothed microphone level, 0..1, for the orb.  Updated on every
  /// frame whether there is speech or not.
  double get level => _level;

  /// Whether [level] is at speech strength right now.
  bool get hearsSpeech => _level >= config.startThreshold;

  /// Feed one frame and return the utterances it completed (usually none).
  ///
  /// [outputActive] is true while the assistant's own speech is playing;
  /// the gate then needs a louder, longer signal, so speaker echo does not
  /// stop the reply.
  List<VoiceUtterance> addFrame(Int16List frame, {bool outputActive = false}) {
    if (frame.isEmpty) return const [];
    final rms = frameRms(frame);
    _level = (_level * 0.65) + (math.min(1, rms / 0.14) * 0.35);
    final gateThreshold = outputActive
        ? math.max(config.startThreshold, config.echoThreshold)
        : config.startThreshold;
    final gateHold = outputActive ? config.echoHold : config.gateHold;
    if (rms >= gateThreshold) {
      _gateRun++;
    } else {
      _gateRun = 0;
    }
    if (!_gateActive && _gateRun >= config.frames(gateHold)) {
      _gateActive = true;
      _gateSilence = 0;
    }
    if (_gateActive) {
      if (rms < config.endThreshold) {
        _gateSilence++;
      } else {
        _gateSilence = 0;
      }
      final gateEnd = outputActive ? config.echoHold : config.gateEndSilence;
      if (!_speaking && _gateSilence >= config.frames(gateEnd)) {
        _gateActive = false;
        _gateSilence = 0;
        _gateRun = 0;
      }
    }
    if (_speaking) {
      _addToUtterance(frame, rms);
      if (rms < config.endThreshold) {
        _silenceRun++;
      } else {
        _silenceRun = 0;
      }
      final silence = _silenceRun * config.frameMillis;
      final length = _utterance.length * config.frameMillis;
      if (silence >= config.endSilence.inMilliseconds ||
          length >= config.maxUtterance.inMilliseconds) {
        final done = _finish();
        return done == null ? const [] : [done];
      }
      return const [];
    }
    _preRoll.add(frame);
    final keep = config.frames(config.preRoll);
    while (_preRoll.length > keep) {
      _preRoll.removeAt(0);
    }
    if (rms >= config.startThreshold) {
      _speechRun++;
    } else {
      _speechRun = 0;
    }
    if (_speechRun >= config.frames(config.startHold)) {
      _speaking = true;
      _silenceRun = 0;
      _peak = 0;
      _utterance
        ..clear()
        ..addAll(_preRoll);
      _preRoll.clear();
      for (final held in _utterance) {
        _peak = math.max(_peak, frameRms(held));
      }
    }
    return const [];
  }

  void _addToUtterance(Int16List frame, double rms) {
    _utterance.add(frame);
    if (rms > _peak) _peak = rms;
  }

  /// End what is being recorded, if anything, without waiting for silence.
  /// A screen that is closing sends the last words rather than dropping them.
  VoiceUtterance? flush() {
    if (!_speaking) return null;
    return _finish();
  }

  /// Forget anything held, e.g. while the microphone is muted.
  void reset() {
    _preRoll.clear();
    _utterance.clear();
    _speechRun = 0;
    _silenceRun = 0;
    _gateRun = 0;
    _gateSilence = 0;
    _speaking = false;
    _gateActive = false;
    _silenceRun = 0;
    _peak = 0;
    _level = 0;
  }

  VoiceUtterance? _finish() {
    _speaking = false;
    _gateActive = false;
    _gateRun = 0;
    _gateSilence = 0;
    _speechRun = 0;
    final trailing = _silenceRun;
    _silenceRun = 0;
    _preRoll.clear();
    if (_utterance.isEmpty) return null;
    final keepTrailing = config.frames(config.trailingKeep);
    final keep = math.max(1, _utterance.length - trailing + keepTrailing);
    final end = math.min(_utterance.length, keep);
    final samples = Int16List(end * _utterance.first.length);
    var offset = 0;
    for (var i = 0; i < end; i++) {
      samples.setRange(offset, offset + _utterance[i].length, _utterance[i]);
      offset += _utterance[i].length;
    }
    final length = Duration(
      microseconds: samples.length * 1000000 ~/ config.sampleRate,
    );
    final peak = _peak;
    _utterance.clear();
    _peak = 0;
    _level = 0;
    if (length < config.minUtterance) return null;
    return VoiceUtterance(
      samples: samples,
      sampleRate: config.sampleRate,
      level: math.min(1, peak / 0.14),
    );
  }
}

/// Root mean square of a PCM16 frame, as a fraction of full scale.
double frameRms(Int16List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final sample in samples) {
    final value = sample / 32768.0;
    sum += value * value;
  }
  return math.sqrt(sum / samples.length);
}

/// A mono 16-bit PCM WAV file.
Uint8List encodeWav(
  Int16List samples, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  final dataBytes = samples.length * 2;
  final bytes = ByteData(44 + dataBytes);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // fmt chunk size
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// The duration of a mono 16-bit PCM WAV, or null when the header does not
/// read as one.  Used to name clips and to refuse an empty recording.
Duration? wavDuration(Uint8List wav) {
  if (wav.length < 44) return null;
  final view = ByteData.sublistView(wav);
  if (view.getUint8(0) != 0x52 ||
      view.getUint8(1) != 0x49 ||
      view.getUint8(2) != 0x46 ||
      view.getUint8(3) != 0x46) {
    return null;
  }
  final channels = view.getUint16(22, Endian.little);
  final rate = view.getUint32(24, Endian.little);
  final bits = view.getUint16(34, Endian.little);
  if (channels == 0 || rate == 0 || bits == 0) return null;
  final bytes = wav.length - 44;
  final frames = bytes ~/ (channels * (bits ~/ 8));
  return Duration(microseconds: frames * 1000000 ~/ rate);
}
