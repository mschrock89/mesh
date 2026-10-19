package com.mitchellschrock.mesh

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import mesh.AnnouncedRoom
import mesh.BytesStore
import mesh.MeshRoom
import mesh.PeerSnapshot
import mesh.RoomStore
import java.io.File
import java.util.UUID

data class MeshUi(
    val localName: String = "",
    val localKind: String = "THIS TABLET",
    val port: Int = 0,
    val peers: List<PeerSnapshot> = emptyList(),
    val ready: Boolean = false,
    val statusText: String = "Starting",
    val detailText: String = "Opening the MIDI network",
    val errorText: String? = null,
    val rooms: List<MeshRoom> = emptyList(),
    val roomID: String = MeshRoom.DEFAULT_ID,
    val elsewhere: List<MeshRoom> = emptyList(),
    val connectedCount: Int = 0
)

object MeshHub {
    private val _ui = MutableStateFlow(MeshUi())
    val ui: StateFlow<MeshUi> = _ui

    private var engine: MeshEngine? = null
    private var rooms: RoomStore? = null
    private var started = false
    private var midi: MeshMidiService? = null
    var onStatus: ((String) -> Unit)? = null

    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        val prefs = app.getSharedPreferences("mesh", Context.MODE_PRIVATE)
        val uuid = prefs.getString("mesh.peerID", null) ?: UUID.randomUUID().toString().lowercase().also {
            prefs.edit().putString("mesh.peerID", it).apply()
        }
        val name = deviceName(app)
        val kind = if (app.resources.configuration.smallestScreenWidthDp >= 600) "THIS TABLET" else "THIS PHONE"
        val store = RoomStore(PreferenceBytes(prefs), File(app.filesDir, "Mesh/rooms.json"))
        rooms = store
        publish(localName = name, localKind = kind, rooms = store.rooms.toList(), roomID = store.selectedID, elsewhere = store.elsewhere)
        val engine = MeshEngine(app, name, uuid, object : MeshEngine.Listener {
            override fun onPeers(peers: List<PeerSnapshot>) = applyPeers(peers)
            override fun onRooms(announced: List<AnnouncedRoom>) = applyAdvertised(announced)
            override fun onReady(port: Int, error: String?) = applyReady(port, error)
            override fun onMidi(data: ByteArray) {
                midi?.deliver(data)
            }
        })
        this.engine = engine
        engine.start(store.selected, store.rooms.toList())
    }

    fun attach(service: MeshMidiService) {
        midi = service
    }

    fun detach(service: MeshMidiService) {
        if (midi === service) midi = null
    }

    fun broadcast(data: ByteArray) {
        engine?.broadcast(data)
    }

    fun noteForeground() {
        engine?.noteForeground()
    }

    fun reconnect() {
        engine?.reconnect()
    }

    fun selectRoom(id: String) {
        val store = rooms ?: return
        if (!store.select(id)) return
        syncRooms()
        advertise()
    }

    fun addRoom(name: String): Boolean {
        val store = rooms ?: return false
        if (store.add(name) == null) return false
        syncRooms()
        advertise()
        return true
    }

    fun renameRoom(id: String, name: String) {
        val store = rooms ?: return
        if (!store.rename(id, name)) return
        syncRooms()
        advertise()
    }

    fun deleteRoom(id: String) {
        val store = rooms ?: return
        if (!store.delete(id)) return
        syncRooms()
        advertise()
    }

    fun canDelete(id: String): Boolean = rooms?.canDelete(id) == true

    fun restoreRoom(id: String) {
        val store = rooms ?: return
        if (!store.restore(id)) return
        syncRooms()
        advertise()
    }

    private fun applyPeers(peers: List<PeerSnapshot>) {
        val connected = peers.count { it.isReachable }
        val current = _ui.value
        publish(
            peers = peers,
            connectedCount = connected,
            ready = current.ready,
            errorText = current.errorText
        )
    }

    private fun applyReady(port: Int, error: String?) {
        publish(port = port, ready = error == null, errorText = error)
    }

    private fun applyAdvertised(announced: List<AnnouncedRoom>) {
        val store = rooms ?: return
        val beforeRooms = store.rooms.toList()
        val beforeSelected = store.selected
        if (!store.merge(announced)) return
        syncRooms()
        if (store.rooms != beforeRooms || store.selected != beforeSelected) advertise()
    }

    private fun advertise() {
        val store = rooms ?: return
        engine?.advertise(store.selected, store.rooms.toList())
    }

    private fun syncRooms() {
        val store = rooms ?: return
        publish(rooms = store.rooms.toList(), roomID = store.selectedID, elsewhere = store.elsewhere)
    }

    private fun publish(
        localName: String = _ui.value.localName,
        localKind: String = _ui.value.localKind,
        port: Int = _ui.value.port,
        peers: List<PeerSnapshot> = _ui.value.peers,
        ready: Boolean = _ui.value.ready,
        errorText: String? = _ui.value.errorText,
        rooms: List<MeshRoom> = _ui.value.rooms,
        roomID: String = _ui.value.roomID,
        elsewhere: List<MeshRoom> = _ui.value.elsewhere,
        connectedCount: Int = peers.count { it.isReachable }
    ) {
        val roomName = rooms.firstOrNull { it.id == roomID }?.name ?: MeshRoom.sanctuaries[0].name
        val status: Pair<String, String> = when {
            errorText != null -> "Needs attention" to errorText
            !ready -> "Starting" to "Opening the MIDI network"
            connectedCount == 0 -> "Searching" to "Waiting for other devices in $roomName"
            connectedCount == 1 -> "Connected" to "1 device in $roomName"
            else -> "Connected" to "$connectedCount devices in $roomName"
        }
        _ui.value = MeshUi(
            localName = localName,
            localKind = localKind,
            port = port,
            peers = peers,
            ready = ready,
            statusText = status.first,
            detailText = status.second,
            errorText = errorText,
            rooms = rooms,
            roomID = roomID,
            elsewhere = elsewhere,
            connectedCount = connectedCount
        )
        onStatus?.invoke(status.second)
    }

    private fun deviceName(context: Context): String {
        val global = Settings.Global.getString(context.contentResolver, "device_name")?.trim().orEmpty()
        if (global.isNotEmpty() && global != "localhost") return global
        val bluetooth = Settings.Secure.getString(context.contentResolver, "bluetooth_name")?.trim().orEmpty()
        if (bluetooth.isNotEmpty()) return bluetooth
        val model = Build.MODEL?.trim().orEmpty()
        if (model.isNotEmpty()) return model
        return "This tablet"
    }
}

private class PreferenceBytes(private val prefs: SharedPreferences) : BytesStore {
    override fun read(key: String): ByteArray? = prefs.getString(key, null)?.toByteArray(Charsets.UTF_8)
    override fun write(key: String, data: ByteArray) {
        prefs.edit().putString(key, data.toString(Charsets.UTF_8)).apply()
    }
}
