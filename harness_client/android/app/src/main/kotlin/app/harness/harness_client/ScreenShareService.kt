package app.harness.harness_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * The foreground service Android requires around a MediaProjection.
 *
 * flutter_webrtc asks the person for the projection consent and captures the
 * display; it does not start this service.  The app starts it before asking
 * for the projection and stops it when the share ends, so the system shows a
 * visible capture state and a backgrounded app cannot keep capturing
 * unnoticed.  The service captures nothing itself.
 */
class ScreenShareService : Service() {
    companion object {
        const val CHANNEL_ID = "screen_share"
        const val NOTIFICATION_ID = 4217
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            // Android 14+ refuses a mediaProjection foreground service
            // until the person has granted the projection: startForeground
            // then throws SecurityException ("requires ...
            // [android:project_media]") from this very call.  Uncaught,
            // that is the whole app -- the service runs on the main
            // thread, so the process dies and the voice call with it, which
            // is what a device showed.  Nothing is capturing yet, so there
            // is nothing to keep: stop the service and let the capture path
            // say the screen is unavailable.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Screen share",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Status of a screen share"
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Screen share")
            .setContentText("This screen")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopForeground(true)
        super.onDestroy()
    }
}
