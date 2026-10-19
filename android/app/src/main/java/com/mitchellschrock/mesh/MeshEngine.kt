package com.mitchellschrock.mesh

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import mesh.AnnouncedRoom
import mesh.DiscoveredPeer
import mesh.MeshRoom
import mesh.MidiSession
import mesh.PeerSnapshot
import mesh.UdpSocket

class MeshEngine(
    context: Context,
    private val localName: String,
    private val localUUID: String,
    private val listener: Listener
) {
    interface Listener {
        fun onPeers(peers: List<PeerSnapshot>)
        fun onRooms(rooms: List<AnnouncedRoom>)
        fun onReady(port: Int, error: String?)
        fun onMidi(data: ByteArray)
    }

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var control: UdpSocket? = null
    private var midiSocket: UdpSocket? = null
    private var session: MidiSession? = null
    private var discovery: MeshDiscovery? = null
    private var roomID = MeshRoom.DEFAULT_ID
    private var connectivity: ConnectivityManager.NetworkCallback? = null
    private var networkUp = true
    private var sawNetwork = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun start(room: MeshRoom, catalog: List<MeshRoom>) {
        roomID = room.id
        holdRadio()
        val pair = try {
            UdpSocket.bindPair()
        } catch (_: Exception) {
            listener.onReady(0, "Mesh couldn't open a network port.")
            return
        }
        control = pair.first
        midiSocket = pair.second
        val session = MidiSession(localName, localUUID, pair.first, pair.second, room.id)
        session.onMIDI = { data -> listener.onMidi(data) }
        session.onChange = { peers -> main.post { listener.onPeers(peers) } }
        session.start()
        this.session = session
        listener.onReady(pair.first.port, null)
        Log.i("Mesh", "Mesh ready · $localName · ${room.name} · port ${pair.first.port}")

        val discovery = MeshDiscovery(
            localUUID = localUUID,
            localPort = pair.first.port,
            localName = localName,
            onPeers = { peers -> session.updateDiscovered(peers) },
            onRooms = { rooms -> main.post { listener.onRooms(rooms) } }
        )
        discovery.start(room, catalog)
        this.discovery = discovery
        watchNetwork()
    }

    fun advertise(room: MeshRoom, catalog: List<MeshRoom>) {
        val changing = room.id != roomID
        roomID = room.id
        discovery?.update(room, catalog)
        if (!changing) return
        session?.setRoom(room.id)
        discovery?.setRoom(room.id)
    }

    fun reconnect() {
        session?.reconnect()
        discovery?.restart()
    }

    fun noteForeground() {
        discovery?.restart()
    }

    fun broadcast(data: ByteArray) {
        session?.broadcast(data)
    }

    fun stop() {
        connectivity?.let { callback ->
            val manager = appContext.getSystemService(ConnectivityManager::class.java)
            try {
                manager?.unregisterNetworkCallback(callback)
            } catch (_: Exception) {
            }
        }
        connectivity = null
        discovery?.stop()
        discovery = null
        session?.stop()
        session = null
        releaseRadio()
    }

    private fun watchNetwork() {
        val manager = appContext.getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (!sawNetwork) {
                    sawNetwork = true
                    networkUp = true
                    return
                }
                val wasDown = !networkUp
                networkUp = true
                if (wasDown) session?.resume()
                discovery?.restart()
            }

            override fun onLost(network: Network) {
                sawNetwork = true
                networkUp = false
                session?.suspend()
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback, main)
            connectivity = callback
        } catch (error: Exception) {
            Log.e("Mesh", "Network watch failed", error)
        }
    }

    private fun holdRadio() {
        val wifi = appContext.getSystemService(WifiManager::class.java)
        if (wifi != null && multicastLock == null) {
            multicastLock = wifi.createMulticastLock("mesh").apply {
                setReferenceCounted(false)
                acquire()
            }
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "mesh").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wakeLock == null) {
            val power = appContext.getSystemService(PowerManager::class.java)
            wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mesh:midi")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseRadio() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        wifiLock = null
        multicastLock = null
    }
}
