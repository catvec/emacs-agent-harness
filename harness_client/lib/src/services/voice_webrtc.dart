import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../media/media_capture.dart';
import '../voice/voice_backend.dart';

/// A live WebRTC session: the microphone in, the provider's voice out, and a
/// JSON data channel for captions and delegation.
///
/// The offer is made here and the answer is fetched from [LiveVoiceConfig]
/// [endpoint].  Two shapes are spoken:
///
///  * OpenAI's Realtime calls (`https://api.openai.com/v1/realtime`), where
///    the SDP is posted to the call URL with an ephemeral key; an API key is
///    exchanged for one first, because a browser must not see it;
///  * a generic signaling endpoint, which receives `{type, sdp, model,
///    session, instructions}` as JSON and answers `{sdp}` (or the bare SDP).
///
/// Audio is never mixed in Dart: WebRTC's own echo cancellation keeps the
/// microphone open while the provider speaks, and the remote audio track is
/// played by the platform.
class WebRtcLiveConnection implements LiveVoiceConnection, LiveMediaConnection {
  WebRtcLiveConnection({
    http.Client? client,
    this.gatheringTimeout = const Duration(seconds: 4),
    this.answerTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _owned = client == null;

  static const iceServers = <Map<String, Object?>>[
    <String, Object?>{'urls': 'stun:stun.l.google.com:19302'},
  ];

  final http.Client _client;
  final bool _owned;
  final Duration gatheringTimeout;
  final Duration answerTimeout;

  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> _queued = <Map<String, Object?>>[];
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  MediaStream? _microphone;
  RTCVideoRenderer? _remote;
  bool _closed = false;
  bool _openAi = false;
  String? _ephemeral;
  RTCRtpTransceiver? _cameraTransceiver;
  RTCRtpTransceiver? _screenTransceiver;
  Map<String, Object?>? _answerMedia;
  MediaDelivery _delivery = const MediaDelivery.none(
    tracksReason: 'not-connected',
    framesReason: 'not-connected',
  );
  int _frameSequence = 0;

  @override
  MediaDelivery get mediaDelivery => _delivery;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> connect(LiveVoiceConfig config) async {
    final uri = Uri.tryParse(config.endpoint.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Live voice endpoint is not a URL.');
    }
    _openAi = uri.host.endsWith('openai.com') || uri.path.contains('/realtime');
    if (_openAi) {
      final images = _openAiTakesImages(config.model);
      _delivery = MediaDelivery(
        tracks: false,
        frames: images,
        tracksReason: 'realtime-api-carries-images-not-video-tracks',
        framesReason: images ? null : 'model-without-image-input',
        maxFps: 1,
      );
    }
    final peer = await createPeerConnection(<String, Object?>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });
    _peer = peer;
    peer.onConnectionState = _onConnectionState;
    peer.onTrack = _onTrack;

    final microphone = await navigator.mediaDevices.getUserMedia(
      <String, Object?>{
        'audio': <String, Object?>{
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'googEchoCancellation': true,
          'googAutoGainControl': true,
          'googNoiseSuppression': true,
          'googHighpassFilter': true,
        },
        'video': false,
      },
    );
    _microphone = microphone;
    for (final track in microphone.getAudioTracks()) {
      await peer.addTrack(track, microphone);
    }

    // Two sendonly video transceivers are offered to a generic harness
    // endpoint.  Whether either is accepted is the provider's answer, not
    // ours: a rejected m-line is reported as no video track, and no capture
    // is attached to it.  OpenAI's realtime call is not offered video
    // tracks; its image input is the data channel below.
    if (!_openAi) {
      _cameraTransceiver = await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
      );
      _screenTransceiver = await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
      );
    }

    final channel = await peer.createDataChannel(
      _openAi ? 'oai-events' : 'harness-voice',
      RTCDataChannelInit()..ordered = true,
    );
    _channel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) _flush();
      if (state == RTCDataChannelState.RTCDataChannelClosed && !_closed) {
        _messages.close();
      }
    };
    channel.onMessage = _onDataChannelMessage;

    final offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await _gatherIce(peer);
    final local = await peer.getLocalDescription();
    if (local == null || local.sdp == null || local.sdp!.isEmpty) {
      throw const FormatException('WebRTC made no offer.');
    }
    final answer = await _exchange(config, uri, local.sdp!);
    await peer.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    if (!_openAi) {
      final camera = await _accepted(_cameraTransceiver);
      final screen = await _accepted(_screenTransceiver);
      final tracks = camera || screen;
      final frames = _answerMedia?['frames'] == true;
      _delivery = MediaDelivery(
        tracks: tracks,
        frames: frames,
        tracksReason: tracks ? null : 'provider-without-video',
        framesReason: frames ? null : 'provider-without-frame-input',
        maxFps: frames ? 1 : 0,
      );
    }
  }

  bool _openAiTakesImages(String model) => openAiTakesImages(model);

  Future<bool> _accepted(RTCRtpTransceiver? transceiver) async {
    if (transceiver == null) return false;
    try {
      final direction = await transceiver.getCurrentDirection();
      return direction == TransceiverDirection.SendOnly ||
          direction == TransceiverDirection.SendRecv;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> attachVideo(CaptureSource source, Object track) async {
    if (track is! MediaStreamTrack) {
      throw const FormatException('Not a MediaStreamTrack.');
    }
    final transceiver = switch (source) {
      CaptureSource.camera => _cameraTransceiver,
      CaptureSource.screen => _screenTransceiver,
      CaptureSource.microphone => null,
    };
    if (transceiver == null) {
      throw const VoiceLiveException(
        'This provider carries no video track for that source.',
      );
    }
    if (!await _accepted(transceiver)) {
      throw VoiceLiveException('The provider did not accept ${source.label}.');
    }
    await transceiver.sender.replaceTrack(track);
  }

  @override
  Future<void> detachVideo(CaptureSource source) async {
    final transceiver = switch (source) {
      CaptureSource.camera => _cameraTransceiver,
      CaptureSource.screen => _screenTransceiver,
      CaptureSource.microphone => null,
    };
    try {
      await transceiver?.sender.replaceTrack(null);
    } catch (_) {
      // The peer may already be gone.
    }
  }

  @override
  Future<void> sendFrame(CapturedFrame frame) async {
    if (!_delivery.frames) {
      throw const VoiceLiveException('provider takes no frames');
    }
    // The data channel's own send queue is the only backpressure there is.
    // One frame is a base64 expansion of its PNG; when the channel is
    // already behind, drop this frame rather than grow a queue of them.
    int? buffered;
    try {
      buffered = _channel?.bufferedAmount;
    } catch (_) {
      // A platform that does not report it has no say here.
    }
    if (!liveFrameFitsBackpressure(buffered, frame.png.length * 4 ~/ 3 + 256)) {
      throw const VoiceLiveException('channel busy');
    }
    if (_openAi) {
      // The Realtime API takes an image as a content part.  No
      // `response.create` follows: the frame is context for the next
      // answer, not an automatic model turn.
      await send(openAiFrameMessage(frame));
      return;
    }
    await send(harnessFrameMessage(frame, ++_frameSequence));
  }

  Future<void> _gatherIce(RTCPeerConnection peer) async {
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final done = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !done.isCompleted) {
        done.complete();
      }
    };
    if (peer.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      done.complete();
    }
    await done.future.timeout(gatheringTimeout, onTimeout: () {});
  }

  Future<String> _exchange(
    LiveVoiceConfig config,
    Uri endpoint,
    String offer,
  ) async {
    if (_openAi) {
      final token = await _openAiToken(config, endpoint);
      final call = _callUri(endpoint, config.model);
      final response = await _client
          .post(
            call,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/sdp',
              'Accept': 'application/sdp',
            },
            body: offer,
          )
          .timeout(answerTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw VoiceLiveException(
          'The realtime call was refused.',
          status: response.statusCode,
          detail: response.body,
        );
      }
      final sdp = response.body.trim();
      if (sdp.isEmpty) {
        throw const VoiceLiveException('The realtime call sent no answer.');
      }
      return sdp;
    }
    final response = await _client
        .post(
          endpoint,
          headers: <String, String>{
            'Content-Type': 'application/json',
            if (config.token.trim().isNotEmpty)
              'Authorization': 'Bearer ${config.token.trim()}',
          },
          body: jsonEncode(<String, Object?>{
            'type': 'offer',
            'protocol': 1,
            'sdp': offer,
            'model': config.model,
            'session': config.sessionId,
            'title': config.sessionTitle,
            'cwd': config.cwd,
            'language': config.language,
            'instructions': config.instructions,
          }),
        )
        .timeout(answerTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VoiceLiveException(
        'The live endpoint was refused.',
        status: response.statusCode,
        detail: response.body,
      );
    }
    final body = response.body.trim();
    if (body.isEmpty) {
      throw const VoiceLiveException('The live endpoint sent no answer.');
    }
    final decoded = body.startsWith('{') ? jsonDecode(body) : null;
    if (decoded is Map) {
      final media = decoded['media'];
      if (media is Map) {
        _answerMedia = Map<String, Object?>.from(media);
      }
      final direct = decoded['sdp'];
      if (direct is String && direct.isNotEmpty) return direct;
      final answer = decoded['answer'];
      if (answer is Map && answer['sdp'] is String) {
        return answer['sdp'] as String;
      }
      final error = decoded['error'];
      if (error is String) throw VoiceLiveException(error);
    }
    return body;
  }

  Uri _callUri(Uri endpoint, String model) {
    var path = endpoint.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    if (!path.endsWith('/realtime')) {
      path = '$path/realtime';
    }
    final query = Map<String, String>.from(endpoint.queryParameters);
    if (model.trim().isNotEmpty && !query.containsKey('model')) {
      query['model'] = model.trim();
    }
    return endpoint.replace(path: path, queryParameters: query);
  }

  Future<String> _openAiToken(LiveVoiceConfig config, Uri endpoint) async {
    if (_ephemeral != null) return _ephemeral!;
    final token = config.token.trim();
    if (token.isEmpty) {
      throw const VoiceLiveException('A realtime token is required.');
    }
    if (token.startsWith('ek_') ||
        token.startsWith('eph_') ||
        token.startsWith('rt_')) {
      _ephemeral = token;
      return token;
    }
    // An API key is exchanged for an ephemeral one, so the key itself never
    // reaches the SDP call.  The two routes are the same secret in the two
    // shapes the Realtime API has had; the first that answers with a value
    // is the one this endpoint speaks.
    var basePath = endpoint.path;
    if (basePath.endsWith('/realtime')) {
      basePath = basePath.substring(0, basePath.length - '/realtime'.length);
    } else if (!basePath.contains('/v1')) {
      basePath = basePath.endsWith('/') ? '${basePath}v1' : '$basePath/v1';
    }
    final base = endpoint.replace(path: basePath, query: '');
    final body = jsonEncode(<String, Object?>{
      'model': config.model,
      if (config.voice.trim().isNotEmpty)
        'session': <String, Object?>{
          'type': 'realtime',
          'model': config.model,
          'audio': <String, Object?>{
            'output': <String, Object?>{'voice': config.voice.trim()},
          },
        },
    });
    for (final suffix in const [
      '/realtime/client_secrets',
      '/realtime/sessions',
    ]) {
      try {
        final response = await _client
            .post(
              Uri.parse('${base.toString()}$suffix'),
              headers: <String, String>{
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: body,
            )
            .timeout(answerTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) continue;
        final decoded = jsonDecode(response.body);
        final secret = decoded is Map
            ? decoded['value'] ??
                  (decoded['client_secret'] is Map
                      ? (decoded['client_secret'] as Map)['value']
                      : decoded['client_secret'])
            : null;
        if (secret is String && secret.isNotEmpty) {
          _ephemeral = secret;
          return secret;
        }
      } catch (_) {
        // Try the other route; the call itself reports a real failure.
      }
    }
    // Some gateways take the key itself.  Let the call say so rather than
    // refusing here.
    _ephemeral = token;
    return token;
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    if (_closed) return;
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _fail('The WebRTC connection failed.');
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      if (!_messages.isClosed) _messages.close();
    }
  }

  Future<void> _onTrack(RTCTrackEvent event) async {
    if (_closed || event.streams.isEmpty) return;
    final stream = event.streams.first;
    try {
      final renderer = _remote ??= RTCVideoRenderer();
      if (renderer.textureId == null) await renderer.initialize();
      renderer.srcObject = stream;
    } catch (_) {
      // The platform plays remote audio itself; a renderer is only needed
      // where the browser wants an element for it.
    }
  }

  void _onDataChannelMessage(RTCDataChannelMessage message) {
    if (_closed || message.isBinary) return;
    try {
      final decoded = jsonDecode(message.text);
      if (decoded is Map) _messages.add(Map<String, Object?>.from(decoded));
    } catch (_) {
      // A provider that says something that is not JSON is not speaking the
      // protocol; it is not a reason to end the audio.
    }
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    if (_closed) return;
    final channel = _channel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      _queued.add(message);
      return;
    }
    await channel.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  void _flush() {
    final channel = _channel;
    if (channel == null || _queued.isEmpty) return;
    final queued = List<Map<String, Object?>>.from(_queued);
    _queued.clear();
    for (final message in queued) {
      unawaited(
        channel
            .send(RTCDataChannelMessage(jsonEncode(message)))
            .catchError(
              (Object error) => _fail('The live data channel failed.'),
            ),
      );
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    final stream = _microphone;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setRemoteAudioEnabled(bool enabled) async {
    if (_closed) return;
    final renderer = _remote;
    if (renderer != null) {
      try {
        renderer.muted = !enabled;
        return;
      } catch (_) {
        // The native renderer cannot mute a remote track.
      }
    }
    final peer = _peer;
    if (peer == null) return;
    try {
      final receivers = await peer.getReceivers();
      for (final receiver in receivers) {
        final track = receiver.track;
        if (track != null && track.kind == 'audio') {
          track.enabled = enabled;
        }
      }
    } catch (_) {
      // A connection that is gone has no audio to silence.
    }
  }

  void _fail(String message) {
    if (!_closed && !_messages.isClosed) {
      _messages.add(<String, Object?>{'type': 'error', 'message': message});
    }
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _queued.clear();
    try {
      await _channel?.close();
    } catch (_) {}
    _channel = null;
    final microphone = _microphone;
    _microphone = null;
    if (microphone != null) {
      for (final track in microphone.getAudioTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await microphone.dispose();
      } catch (_) {}
    }
    try {
      await _remote?.dispose();
    } catch (_) {}
    _remote = null;
    try {
      await _peer?.close();
      await _peer?.dispose();
    } catch (_) {}
    _peer = null;
    if (!_messages.isClosed) await _messages.close();
    if (_owned) _client.close();
  }
}

/// The live connection could not be made, or the endpoint refused it.
class VoiceLiveException implements Exception {
  const VoiceLiveException(this.message, {this.status, this.detail});
  final String message;
  final int? status;
  final String? detail;

  @override
  String toString() {
    final line = detail?.trim().split('\n').first.trim() ?? '';
    final suffix = status == null ? '' : ' ($status)';
    return line.isEmpty ? '$message$suffix' : '$message$suffix · $line';
  }
}

/// The most the live data channel's send queue may hold before a frame is
/// dropped.  WebRTC's SCTP data channel buffers on the sending side; a frame
/// that would push it past this is a frame the far end is not keeping up
/// with.  Two mebibytes hold several bounded 180 KiB PNGs after base64
/// (about 240 KiB each), so the queue can absorb a burst without growing
/// without limit.
const int liveFrameBackpressureBytes = 2 * 1024 * 1024;

/// Whether one frame fits in the data channel's send queue.
bool liveFrameFitsBackpressure(int? bufferedAmount, int frameBytes) =>
    (bufferedAmount ?? 0) + frameBytes <= liveFrameBackpressureBytes;

/// Whether a Realtime model documents image input.  GPT-Live-1 documents
/// image and video as unsupported, so it is not one of these.
bool openAiTakesImages(String model) {
  final name = model.trim().toLowerCase();
  return name.startsWith('gpt-realtime') || name.startsWith('gpt-4o-realtime');
}

/// The Realtime API's one image content part.  No `response.create` follows:
/// a frame is context for the next answer, not an automatic model turn.
Map<String, Object?> openAiFrameMessage(CapturedFrame frame) => {
  'type': 'conversation.item.create',
  'item': {
    'type': 'message',
    'role': 'user',
    'content': [
      {
        'type': 'input_image',
        'image_url': 'data:${frame.mimeType};base64,${base64Encode(frame.png)}',
      },
    ],
  },
};

/// The generic harness endpoint's frame message: a documented JSON data
/// channel object.  A server that has not negotiated frames never sees one.
Map<String, Object?> harnessFrameMessage(CapturedFrame frame, int sequence) => {
  'type': 'frame',
  'protocol': 1,
  'source': frame.source.name,
  'mimeType': frame.mimeType,
  'data': base64Encode(frame.png),
  'width': frame.width,
  'height': frame.height,
  'capturedAt': frame.capturedAt.toUtc().toIso8601String(),
  'sequence': sequence,
};
