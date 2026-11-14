package app.harness.harness_client

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The volume control the hardware keys follow, and the audio state a voice
 * call holds while it plays.
 *
 * Android decides what the volume keys adjust by the stream of the audio that
 * is playing, and the framework forces the *call* stream whenever the audio
 * mode is a communication one (`AudioService.getActiveStreamType`).  A voice
 * conversation that plays through a call-like configuration therefore ignores
 * media volume entirely: the slider moves, the keys move, and the audible
 * level does not change.  The Dart side names one output for both voice
 * backends (see `AndroidVoiceOutput`); this class is what makes the activity
 * agree with it:
 *
 *  * `volumeControlStream` is set to the stream that output maps to, so the
 *    keys adjust it even when nothing is playing at that instant;
 *  * the mode, the focus and the focus's own audio attributes are held while
 *    the call is open, so the platform does not fall back to a call-like mode
 *    of its own;
 *  * `describe` answers what the platform is actually doing -- mode, focus,
 *    the stream the keys control, its volume, and the route -- so a device
 *    check can read it from `adb logcat` instead of guessing from the code.
 *
 * Every call answers rather than throwing: a phone whose OEM refuses one of
 * them must still speak.
 */
class VoiceAudioChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "app.harness/voice_audio"
        const val TAG = "HarnessVoiceAudio"

        /** The `AudioAttributes` usage a voice conversation asks for. */
        private fun usageOf(name: String?): Int = when (name) {
            "assistant" -> AudioAttributes.USAGE_ASSISTANT
            "navigation" -> AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
            else -> AudioAttributes.USAGE_MEDIA
        }

        private fun contentTypeOf(name: String?): Int = when (name) {
            "music" -> AudioAttributes.CONTENT_TYPE_MUSIC
            else -> AudioAttributes.CONTENT_TYPE_SPEECH
        }

        /** The legacy stream a usage maps to, as `AudioAttributes` maps it. */
        private fun streamOf(name: String?): Int = when (name) {
            "voiceCall" -> AudioManager.STREAM_VOICE_CALL
            else -> AudioManager.STREAM_MUSIC
        }

        private fun modeOf(name: String?): Int = when (name) {
            "inCommunication" -> AudioManager.MODE_IN_COMMUNICATION
            else -> AudioManager.MODE_NORMAL
        }

        private fun focusModeOf(name: String?): Int = when (name) {
            "gainTransient" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            else -> AudioManager.AUDIOFOCUS_GAIN
        }
    }

    private val audioManager: AudioManager =
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var focusRequest: AudioFocusRequest? = null
    private var previousMode: Int? = null
    private var previousVolumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val output = call.argument<Map<String, Any?>>("output") ?: emptyMap()
        when (call.method) {
            "begin" -> result.success(begin(output))
            "end" -> result.success(end(output))
            "describe" -> result.success(describe(output))
            else -> result.notImplemented()
        }
    }

    /** Claim the keys, and hold the mode and focus the output asks for. */
    private fun begin(output: Map<String, Any?>): Map<String, Any?> {
        val stream = streamOf(output["streamType"] as? String)
        previousVolumeControlStream = activity.volumeControlStream
        activity.volumeControlStream = stream
        val mode = modeOf(output["mode"] as? String)
        if (previousMode == null) previousMode = audioManager.mode
        requestFocus(output)
        try {
            audioManager.mode = mode
        } catch (error: Exception) {
            Log.w(TAG, "mode refused: ${error.message}")
        }
        Log.i(TAG, "begin ${describeNow(stream)}")
        return describe(output)
    }

    /** Give the keys, the mode and the focus back. */
    private fun end(output: Map<String, Any?>): Map<String, Any?> {
        activity.volumeControlStream = previousVolumeControlStream
        val mode = previousMode
        previousMode = null
        if (mode != null) {
            try {
                audioManager.mode = mode
            } catch (error: Exception) {
                Log.w(TAG, "mode restore refused: ${error.message}")
            }
        }
        abandonFocus()
        Log.i(TAG, "end ${describeNow(streamOf(output["streamType"] as? String))}")
        return describe(output)
    }

    private fun requestFocus(output: Map<String, Any?>) {
        abandonFocus()
        val focus = focusModeOf(output["focus"] as? String)
        val attributes = AudioAttributes.Builder()
            .setUsage(usageOf(output["usage"] as? String))
            .setContentType(contentTypeOf(output["contentType"] as? String))
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(focus)
                    .setAudioAttributes(attributes)
                    .setOnAudioFocusChangeListener { change ->
                        Log.i(TAG, "focus change $change")
                    }
                    .build()
                focusRequest = request
                val answer = audioManager.requestAudioFocus(request)
                Log.i(TAG, "focus request $answer")
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    streamOf(output["streamType"] as? String),
                    focus,
                )
            }
        } catch (error: Exception) {
            Log.w(TAG, "focus refused: ${error.message}")
        }
    }

    private fun abandonFocus() {
        val request = focusRequest
        focusRequest = null
        if (request == null) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioManager.abandonAudioFocusRequest(request)
            }
        } catch (error: Exception) {
            Log.w(TAG, "focus abandon refused: ${error.message}")
        }
    }

    /**
     * What the platform is doing now: the mode, the stream the keys control,
     * that stream's volume and maximum, the route and the focus.  It is the
     * record a device check reads from `adb logcat`, and what the Dart side
     * logs when a call starts.
     */
    private fun describe(output: Map<String, Any?>): Map<String, Any?> =
        describeNow(streamOf(output["streamType"] as? String))


    private fun describeNow(stream: Int): Map<String, Any?> {
        // What the platform is actually playing, and with which attributes:
        // the definitive answer to "is the reply on the stream the keys
        // adjust", which the app's own settings cannot prove on their own.
        val playing = activePlayback()
        return mapOf(
            "mode" to audioManager.mode,
            "volumeControlStream" to activity.volumeControlStream,
            "stream" to stream,
            "volume" to audioManager.getStreamVolume(stream),
            "maxVolume" to audioManager.getStreamMaxVolume(stream),
            "mediaVolume" to audioManager.getStreamVolume(AudioManager.STREAM_MUSIC),
            "mediaMaxVolume" to audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "musicActive" to audioManager.isMusicActive,
            "speakerphoneOn" to audioManager.isSpeakerphoneOn,
            "bluetoothScoOn" to audioManager.isBluetoothScoOn,
            "hasFocus" to (focusRequest != null),
            "routes" to outputRoutes(),
            "playingCount" to playing.size,
            "playing" to playing.joinToString(";"),
        )
    }

    /** Every output device the platform would route to, named. */
    private fun outputRoutes(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return "unknown"
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .joinToString(",") { deviceName(it.type) }
    }

    /**
     * The players the platform reports as active, each as
     * `usage=/contentType=/stream=/volume=`.  The stream is what
     * `AudioAttributes.toVolumeStreamType` maps the usage to, which is the
     * volume control that player follows.
     */
    private fun activePlayback(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
        return try {
            // The public call answers only the players that are active now.
            audioManager.getActivePlaybackConfigurations()
                .map { configuration ->
                    val attributes = configuration.audioAttributes
                    val playerStream = volumeStreamOf(attributes)
                    "usage=${attributes.usage}/${usageName(attributes.usage)}" +
                        "/contentType=${attributes.contentType}" +
                        "/stream=$playerStream/volume=${audioManager.getStreamVolume(playerStream)}"
                }
        } catch (error: Exception) {
            Log.w(TAG, "playback configurations refused: ${error.message}")
            emptyList()
        }
    }

    /**
     * The legacy stream `AudioAttributes.toVolumeStreamType` picks for a usage.
     * It is not public API, so the mappings this app can produce are named and
     * anything else says so instead of guessing.
     */
    private fun volumeStreamOf(attributes: AudioAttributes): Int = when (attributes.usage) {
        AudioAttributes.USAGE_MEDIA,
        AudioAttributes.USAGE_ASSISTANT,
        AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE,
        -> AudioManager.STREAM_MUSIC

        AudioAttributes.USAGE_VOICE_COMMUNICATION,
        AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING,
        -> AudioManager.STREAM_VOICE_CALL

        else -> AudioManager.USE_DEFAULT_STREAM_TYPE
    }

    private fun usageName(usage: Int): String = when (usage) {
        AudioAttributes.USAGE_MEDIA -> "media"
        AudioAttributes.USAGE_ASSISTANT -> "assistant"
        AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE -> "navigation"
        AudioAttributes.USAGE_VOICE_COMMUNICATION -> "voiceCommunication"
        AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING -> "voiceSignalling"
        else -> "other"
    }

    private fun deviceName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired-headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired-headphones"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth-a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth-sco"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth-le-headset"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb-headset"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing-aid"
        else -> "device-$type"
    }
}
