import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:harness_client/src/media/media_capture.dart';
import 'package:harness_client/src/media/media_capture_webrtc.dart';

class _Recorder {
  final List<String> events = [];

  void add(String event) => events.add(event);
}

/// A screen capture whose consent the test answers.
class _ScriptedScreen implements ScreenCaptureSource {
  _ScriptedScreen(this.recorder);

  final _Recorder recorder;

  @override
  Future<MediaStream> request(Map<String, Object?> constraints) async {
    // The consent is answered and the request then fails, as a person
    // refusing the projection does.  What this test is about is what the
    // capture path did before the stream existed.
    recorder.add('consent');
    throw Exception('the projection was refused');
  }
}

class _ScriptedForeground implements ScreenShareForegroundSeam {
  _ScriptedForeground(this.recorder);

  final _Recorder recorder;

  @override
  Future<bool> start() async {
    recorder.add('foreground-start');
    return true;
  }

  @override
  Future<void> stop() async {
    recorder.add('foreground-stop');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a refused projection starts no foreground service', () async {
    final recorder = _Recorder();
    final platform = WebRtcMediaCapturePlatform(
      foreground: _ScriptedForeground(recorder),
      screen: _ScriptedScreen(recorder),
    );

    await expectLater(
      platform.startVisual(CaptureSource.screen,
          width: 640, height: 360, fps: 15),
      throwsA(anything),
    );

    // The projection is asked for first, and a request that does not
    // yield a stream starts no mediaProjection foreground service:
    // Android 14+ kills the app when one runs before the grant.
    expect(recorder.events.first, 'consent');
    expect(recorder.events, isNot(contains('foreground-start')));
  });
}
