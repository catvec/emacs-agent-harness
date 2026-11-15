package app.harness.harness_client

import android.content.Intent
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Android host, including the headset play/pause bridge.
 *
 * A Bluetooth headset sends its single button to the active media session,
 * not to an activity's key handler.  While the Flutter voice screen is open
 * it asks this activity for a session; the session then forwards play and
 * pause to the screen's pause/resume control.  The session is released when
 * the screen closes, so the button behaves as usual everywhere else.  This
 * is best effort: some headsets send a call button instead, and an app that
 * does not hold audio focus may not be the session Android chooses.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var computerPlatformChannel: MethodChannel? = null
    private var computerControlChannel: MethodChannel? = null
    private var voiceAudio: MethodChannel? = null

    private var mediaSession: MediaSession? = null
    private var screenShareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.harness/voice_media_buttons",
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startMediaButtons()
                    result.success(null)
                }
                "stop" -> {
                    stopMediaButtons()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        val computerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ComputerPlatform.CHANNEL,
        )
        computerChannel.setMethodCallHandler { call, result ->
            ComputerPlatform.handle(this, call, result)
        }
        computerPlatformChannel = computerChannel
        val controlChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ComputerControl.CHANNEL,
        )
        controlChannel.setMethodCallHandler { call, result ->
            val metrics = resources.displayMetrics
            ComputerControl.handle(this, call, result, metrics)
        }
        computerControlChannel = controlChannel
        val screenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.harness/screen_share",
        )
        screenChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(startScreenShareService())
                "stop" -> {
                    stopScreenShareService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        screenShareChannel = screenChannel
        // The volume control the keys follow, and the audio state a call holds.
        voiceAudio = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VoiceAudioChannel.CHANNEL,
        )
        voiceAudio?.setMethodCallHandler(VoiceAudioChannel(this))
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (ComputerPlatform.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    /** Start the mediaProjection foreground service before getDisplayMedia. */
    private fun startScreenShareService(): Boolean {
        return try {
            val intent = Intent(this, ScreenShareService::class.java)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopScreenShareService() {
        try {
            stopService(Intent(this, ScreenShareService::class.java))
        } catch (_: Exception) {
            // Already gone.
        }
    }

    private fun startMediaButtons() {
        if (mediaSession != null) return
        val session = MediaSession(this, "HarnessVoice")
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = toggleVoice()
            override fun onPause() = toggleVoice()
            override fun onPlayFromMediaId(mediaId: String?, extras: Bundle?) =
                toggleVoice()
        })
        @Suppress("DEPRECATION")
        session.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
        )
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE,
                )
                .setState(
                    PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    1.0f,
                )
                .build(),
        )
        session.isActive = true
        mediaSession = session
    }

    private fun toggleVoice() {
        channel?.invokeMethod("toggle", null)
    }

    private fun stopMediaButtons() {
        val session = mediaSession ?: return
        mediaSession = null
        session.isActive = false
        session.release()
    }

    override fun onDestroy() {
        stopMediaButtons()
        channel?.setMethodCallHandler(null)
        channel = null
        computerPlatformChannel?.setMethodCallHandler(null)
        computerPlatformChannel = null
        computerControlChannel?.setMethodCallHandler(null)
        computerControlChannel = null
        voiceAudio?.setMethodCallHandler(null)
        voiceAudio = null
        screenShareChannel?.setMethodCallHandler(null)
        screenShareChannel = null
        super.onDestroy()
    }
}
