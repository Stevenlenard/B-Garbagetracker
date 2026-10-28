package com.example.garbage_tracking_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the app process in the foreground while a collection trip is active, so Android never freezes it or throttles
 * its location updates when the driver opens another app (Messenger, calls) or locks the phone. GPS fixes, publishing
 * and the heartbeat stay in Dart (the cached engine of MainActivity); this service only holds the process.
 *
 * Started and stopped by the driver dashboard ("startTrackingService" / "stopTrackingService" on the "gt/app" channel)
 * for the lifetime of a trip, independent of the GPS stream: re-arming the stream no longer drops the foreground state.
 */
class TrackingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // Restarted by the system after the process was killed: the trip is no longer tracked. Tell the driver
            // instead of pretending (a background start cannot become a foreground service again).
            notifyInterrupted(this)
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent.action == ACTION_STOP) {
            releaseWakeLock()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireWakeLock()
        running = true
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GarbageTracker:trip").apply {
            setReferenceCounted(false)
            acquire(12 * 60 * 60 * 1000L) // never longer than the 12-hour driver session
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    companion object {
        const val ACTION_START = "gt.tracking.START"
        const val ACTION_STOP = "gt.tracking.STOP"
        private const val CHANNEL_ID = "gt_trip_tracking"
        private const val NOTIFICATION_ID = 7301
        private const val INTERRUPTED_ID = 7302

        @Volatile
        var running = false
            private set

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Trip tracking", NotificationManager.IMPORTANCE_LOW))
                }
            }
        }

        private fun openApp(context: Context): PendingIntent {
            val i = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(context, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun buildNotification(context: Context): Notification {
            ensureChannel(context)
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle("Garbage Truck Tracker")
                .setContentText("Trip in progress: sharing this truck's live location.")
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(openApp(context))
                .build()
        }

        fun notifyInterrupted(context: Context) {
            try {
                ensureChannel(context)
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle("Trip tracking stopped")
                    .setContentText("The phone closed the app. Tap to open it and continue the trip.")
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setAutoCancel(true)
                    .setContentIntent(openApp(context))
                    .build()
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(INTERRUPTED_ID, n)
            } catch (_: Exception) {
            }
        }

        /** Must be called while the app is on screen (Android does not allow starting it from the background). */
        fun start(context: Context): Boolean = try {
            ContextCompat.startForegroundService(context, Intent(context, TrackingService::class.java).setAction(ACTION_START))
            true
        } catch (_: Exception) {
            false
        }

        fun stop(context: Context) {
            if (!running) return
            try {
                context.startService(Intent(context, TrackingService::class.java).setAction(ACTION_STOP))
            } catch (_: Exception) {
                context.stopService(Intent(context, TrackingService::class.java))
            }
        }
    }
}
