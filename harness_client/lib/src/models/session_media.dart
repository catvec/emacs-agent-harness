import '../acp/acp_message.dart';

/// What a session can receive from a camera or a screen capture, as the
/// harness answers `session/media`.
///
/// This is the workspace/provider side of capture.  It is a still-frame
/// endpoint (`session/prompt` with an ACP image block), never a video-track
/// endpoint: the harness has no media sink, and says so in [realtime].
class SessionMediaCapabilities {
  const SessionMediaCapabilities({
    required this.session,
    this.endpoint = 'session/prompt',
    this.images = false,
    this.realtime = false,
    this.realtimeReason,
    this.maxBytes = 184320,
    this.maxWidth = 640,
    this.maxHeight = 360,
    this.maxPerMinute = 30,
    this.mimeTypes = const ['image/png', 'image/jpeg'],
    this.model,
    this.vision,
    this.reason,
  });

  factory SessionMediaCapabilities.fromWire(JsonMap wire) {
    final frames = asMap(wire['frames']);
    final rawVision = wire['vision'];
    final bool? vision = switch (rawVision) {
      true => true,
      false => false,
      'true' => true,
      'false' => false,
      _ => null,
    };
    return SessionMediaCapabilities(
      session: asStringOr(wire['session'], ''),
      endpoint: asStringOr(wire['endpoint'], 'session/prompt'),
      images: asBool(wire['images']),
      realtime: asBool(wire['realtime']),
      realtimeReason: asString(
        wire['realtime-reason'] ?? wire['realtimeReason'],
      ),
      maxBytes: asInt(frames['max-bytes'] ?? frames['maxBytes']) ?? 184320,
      maxWidth: asInt(frames['max-width'] ?? frames['maxWidth']) ?? 640,
      maxHeight: asInt(frames['max-height'] ?? frames['maxHeight']) ?? 360,
      maxPerMinute:
          asInt(frames['max-per-minute'] ?? frames['maxPerMinute']) ?? 30,
      mimeTypes: [
        for (final item in asList(frames['mime-types'] ?? frames['mimeTypes']))
          if (asString(item) case final value?) value,
      ],
      model: asString(wire['model']),
      vision: vision,
      reason: asString(wire['reason']),
    );
  }

  /// The session the frames are sent to.
  final String session;

  /// The receiving ACP method.
  final String endpoint;

  /// Whether the harness accepts an image content block at all.
  final bool images;

  /// Whether the harness carries a live video track.  False: it has no media
  /// sink, so a client must not draw a `live video` state for it.
  final bool realtime;

  final String? realtimeReason;

  final int maxBytes;
  final int maxWidth;
  final int maxHeight;
  final int maxPerMinute;
  final List<String> mimeTypes;

  /// The session's model, when the harness says.
  final String? model;

  /// Whether the model reads images: true, false, or null when the harness
  /// or the provider does not say.
  final bool? vision;

  /// `model-without-vision`, `vision-unknown`, or null when known to work.
  final String? reason;

  bool get frames => images && vision != false;

  /// Whether a person should be warned that the model may not see the frame.
  bool get visionUnconfirmed => vision == null;

  String? get unavailableReason {
    if (!images) return 'harness-without-image-prompts';
    if (vision == false) return reason ?? 'model-without-vision';
    return null;
  }
}
