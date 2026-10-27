package com.github.veneraworks.veneraplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class DownloadService : Service() {
    companion object {
        val state = DownloadSessionState()
        var instance: DownloadService? = null
            private set
        var onStopped: ((DownloadSessionState.Session, String) -> Unit)? = null
        private const val CHANNEL = "comic_downloads"
        private const val NOTIFICATION = 107
        private const val PAUSE = "com.github.veneraworks.veneraplus.PAUSE_DOWNLOAD"

        fun stopOwned(owner: String, id: Int, reason: String? = null) {
            val session = state.stop(owner, id) ?: return
            instance?.finish()
            if (reason != null) onStopped?.invoke(session, reason)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var served: DownloadSessionState.Session? = null
    private val watchdog = object : Runnable {
        override fun run() {
            val session = state.active
            if (session == null) {
                finish()
                return
            }
            if (SystemClock.elapsedRealtime() - session.lastHeartbeat > 90_000L) {
                stopOwned(session.owner, session.id, "heartbeat_timeout")
                return
            }
            renewWakeLock()
            handler.postDelayed(this, 30_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.download_channel), NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val session = state.active
        if (intent?.action == PAUSE) {
            val owner = intent.getStringExtra("owner")
            if (owner != null) stopOwned(owner, intent.getIntExtra("session", -1), "notification_pause")
            if (state.active == null) finish()
            return START_NOT_STICKY
        }
        try {
            served = session
            // Even a start cancelled before delivery must meet Android's
            // startForeground deadline. Always use the latest owned snapshot.
            ServiceCompat.startForeground(
                this, NOTIFICATION, notification(session),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
            if (session == null) {
                finish()
            } else {
                handler.removeCallbacks(watchdog)
                watchdog.run()
            }
        } catch (error: Exception) {
            Log.e("DownloadService", "Cannot enter foreground", error)
            if (session != null) stopOwned(session.owner, session.id, "foreground_error")
            else finish()
        }
        // Never restart an empty service or silently resume a user's queue.
        return START_NOT_STICKY
    }

    private fun notification(session: DownloadSessionState.Session?): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_download_notification)
            .setContentTitle("VeneraPlus")
            .setContentText(getString(if (session?.waiting == true) R.string.download_waiting else R.string.download_active))
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(1000, session?.progress ?: 0, session == null || session.progress == 0)
        if (session != null) {
            val pause = Intent(this, DownloadService::class.java)
                .setAction(PAUSE)
                .setData(Uri.parse("veneraplus://downloads/${session.owner}/${session.id}"))
                .putExtra("owner", session.owner)
                .putExtra("session", session.id)
            builder.addAction(
                0, getString(R.string.download_pause),
                PendingIntent.getService(this, 0, pause, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE),
            )
        }
        return builder.build()
    }

    fun refresh() {
        val session = state.active ?: return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(session))
    }

    private fun renewWakeLock() {
        val lock = wakeLock ?: (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VeneraPlus:downloads")
            .also { it.setReferenceCounted(false); wakeLock = it }
        if (lock.isHeld) lock.release()
        lock.acquire(120_000L)
    }

    private fun releaseResources() {
        handler.removeCallbacksAndMessages(null)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    private fun finish() {
        releaseResources()
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        val session = state.active
        if (session != null) stopOwned(session.owner, session.id, "system_timeout")
        else finish()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val session = state.active
        if (session != null) stopOwned(session.owner, session.id, "task_removed")
        else finish()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseResources()
        if (instance === this) {
            instance = null
            val session = state.active
            if (session != null && session === served) stopOwned(session.owner, session.id, "service_destroyed")
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
