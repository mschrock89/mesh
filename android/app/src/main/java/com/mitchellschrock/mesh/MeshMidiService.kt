package com.mitchellschrock.mesh

import android.content.Intent
import android.media.midi.MidiDeviceService
import android.media.midi.MidiReceiver
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

/** Virtual MIDI device other apps open. Notes they send join the room, and notes from the room come back out. */
class MeshMidiService : MidiDeviceService() {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var echoBytes: ByteArray? = null
    @Volatile private var echoUntil = 0L
    private val input = object : MidiReceiver() {
        override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
            if (count <= 0) return
            val copy = msg.copyOfRange(offset, offset + count)
            val echo = echoBytes
            if (echo != null && System.nanoTime() < echoUntil && echo.contentEquals(copy)) return
            MeshHub.broadcast(copy)
            // The worship page listens on this device's output. Hand it the same notes.
            deliver(copy)
        }
    }

    override fun onCreate() {
        super.onCreate()
        MeshHub.attach(this)
        ContextCompat.startForegroundService(this, Intent(this, MeshService::class.java))
    }

    override fun onDestroy() {
        MeshHub.detach(this)
        super.onDestroy()
    }

    override fun onGetInputPortReceivers(): Array<MidiReceiver> = arrayOf(input)

    fun deliver(data: ByteArray) {
        if (data.isEmpty()) return
        val copy = data.copyOf()
        main.post {
            val receivers = outputPortReceivers ?: return@post
            echoUntil = Long.MAX_VALUE
            echoBytes = copy
            try {
                val timestamp = System.nanoTime()
                for (receiver in receivers) {
                    try {
                        receiver?.send(copy, 0, copy.size, timestamp)
                    } catch (_: Exception) {
                    }
                }
            } finally {
                echoUntil = System.nanoTime() + 5_000_000L
            }
        }
    }
}
