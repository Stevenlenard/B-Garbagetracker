package com.example.garbage_tracking_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel

/**
 * Keeps the app process in the foreground while a collection trip is active, so Android never freezes it or throttles
 * its location updates when the driver opens another app (Messenger, calls), locks the phone, or swipes the app away.
 * The service also reads GPS itself and passes the fixes to Dart ("gt/location"); publishing and the heartbeat stay in
 * Dart (the cached engine of MainActivity).
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
            stopLocationUpdates()
            releaseWakeLock()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }
        // Never take the app down: if Android refuses the foreground start, the service ends quietly and the GPS
        // stream keeps its own service (the earlier behaviour).
        try {
            val notification = buildNotification(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        startLocationUpdates()
        running = true
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        stopLocationUpdates()
        releaseWakeLock()
        super.onDestroy()
    }

    // GPS is read here, by the service itself, and passed to Dart through the "gt/location" event channel. The
    // location plugin of the app stops its updates when the screen (activity) goes away, e.g. when the app is swiped
    // away from recent apps; these updates belong to the service and keep coming as long as the trip service runs.
    private var locationManager: LocationManager? = null
    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val m = HashMap<String, Any>()
            m["latitude"] = location.latitude
            m["longitude"] = location.longitude
            m["accuracy"] = if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0
            m["altitude"] = if (location.hasAltitude()) location.altitude else 0.0
            m["speed"] = if (location.hasSpeed()) location.speed.toDouble() else 0.0
            m["heading"] = if (location.hasBearing()) location.bearing.toDouble() else 0.0
            m["time"] = location.time
            m["mocked"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) location.isMock else @Suppress("DEPRECATION") location.isFromMockProvider
            try {
                sink?.success(m)
            } catch (_: Exception) {
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private fun startLocationUpdates() {
        if (locationManager != null) return
        val fine = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED) return
        try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, listener, Looper.getMainLooper())
            locationManager = lm
        } catch (_: Exception) {
            locationManager = null // the location plugin of the app still delivers fixes while the app is on screen
        }
    }

    private fun stopLocationUpdates() {
        try {
            locationManager?.removeUpdates(listener)
        } catch (_: Exception) {
        }
        locationManager = null
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GarbageTracker:trip").apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L) // never longer than the 12-hour driver session
            }
        } catch (_: Exception) {
            wakeLock = null // the foreground service alone still keeps the app running
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
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

        /** Receiver of the fixes in Dart ("gt/location"), set while Dart listens. */
        @Volatile
        var sink: EventChannel.EventSink? = null

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
                .setSmallIcon(android.R.drawable.ic_menu_mylocation) // a valid status-bar icon on every phone (the adaptive app icon is not)
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
                    .setSmallIcon(android.R.drawable.ic_menu_mylocation) // a valid status-bar icon on every phone (the adaptive app icon is not)
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

        /**
         * Must be called while the app is on screen, and only with location permission. Started with startService (the
         * app is in the foreground): the service then promotes itself with startForeground, and if Android refuses that,
         * the service simply ends. startForegroundService would make Android kill the whole app in that case.
         */
        fun start(context: Context): Boolean {
            val fine = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION)
            if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) return false
            return try {
                context.startService(Intent(context, TrackingService::class.java).setAction(ACTION_START))
                true
            } catch (_: Exception) {
                false
            }
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
