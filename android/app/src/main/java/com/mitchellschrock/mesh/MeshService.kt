package com.mitchellschrock.mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Keeps the MIDI session alive while the screen is locked. */
class MeshService : Service() {
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL, "Mesh", NotificationManager.IMPORTANCE_LOW)
        channel.description = "Keeps MIDI connected while the screen is locked"
        manager.createNotificationChannel(channel)
        ServiceCompat.startForeground(
            this,
            NOTE_ID,
            notification("Sharing MIDI on this network"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        )
        MeshHub.onStatus = { detail ->
            manager.notify(NOTE_ID, notification(detail))
        }
        MeshHub.start(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (MeshHub.onStatus != null) MeshHub.onStatus = null
        super.onDestroy()
    }

    private fun notification(detail: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("Mesh")
            .setContentText(detail)
            .setSmallIcon(R.drawable.ic_stat_mesh)
            .setOngoing(true)
            .setContentIntent(open)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "mesh"
        private const val NOTE_ID = 1
    }
}
