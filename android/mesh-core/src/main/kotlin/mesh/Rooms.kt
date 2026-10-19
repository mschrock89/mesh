package mesh

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

@Serializable
data class MeshRoom(
    val id: String,
    val name: String,
    val revision: Long
) {
    val isSanctuary: Boolean get() = id in sanctuaryIDs

    companion object {
        const val DEFAULT_ID = "sanctuary-1"
        val sanctuaries = listOf(
            MeshRoom("sanctuary-1", "Sanctuary 1", 1),
            MeshRoom("sanctuary-2", "Sanctuary 2", 1),
            MeshRoom("sanctuary-3", "Sanctuary 3", 1)
        )
        val sanctuaryIDs = sanctuaries.map { it.id }.toSet()

        fun cleaned(raw: String): String? {
            val collapsed = raw.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            if (collapsed.isEmpty()) return null
            return collapsed.take(40)
        }

        fun cleanedID(raw: String): String? {
            val id = raw.trim().lowercase()
            if (id.length !in 1..80) return null
            if (!id.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }) return null
            return id
        }

        fun revisionNow(): Long = System.currentTimeMillis()
    }
}

data class AnnouncedRoom(val id: String, val name: String, val revision: Long)

object RoomGate {
    fun same(remote: String, local: String): Boolean {
        val remoteID = MeshRoom.cleanedID(remote) ?: ""
        val localID = MeshRoom.cleanedID(local) ?: ""
        return localID.isNotEmpty() && remoteID == localID
    }
}

object RoomCatalogTXT {
    fun fields(selected: MeshRoom, rooms: List<MeshRoom>): Map<String, String> {
        val fields = linkedMapOf(
            "room" to selected.id,
            "roomRev" to selected.revision.toString()
        )
        if (selected.name.isNotEmpty()) fields["roomName"] = selected.name
        for ((index, room) in rooms.take(16).withIndex()) {
            fields["c$index"] = "${room.id}\t${room.name}\t${room.revision}"
        }
        return fields
    }

    fun announced(fields: Map<String, String>): List<AnnouncedRoom> {
        val found = mutableListOf<AnnouncedRoom>()
        val selectedID = MeshRoom.cleanedID(fields["room"] ?: "")
        val selectedName = MeshRoom.cleaned(fields["roomName"] ?: "")
        if (selectedID != null && selectedName != null) {
            found.add(AnnouncedRoom(selectedID, selectedName, fields["roomRev"]?.toLongOrNull() ?: 0))
        }
        for (index in 0 until 16) {
            val raw = fields["c$index"] ?: continue
            val parts = raw.split('\t')
            if (parts.size != 3) continue
            val id = MeshRoom.cleanedID(parts[0]) ?: continue
            val name = MeshRoom.cleaned(parts[1]) ?: continue
            val revision = parts[2].toLongOrNull() ?: continue
            found.add(AnnouncedRoom(id, name, revision))
        }
        return found
    }
}

interface BytesStore {
    fun read(key: String): ByteArray?
    fun write(key: String, data: ByteArray)
}

/** Rooms live on disk so the selected room is saved as soon as it changes. */
class RoomStore(
    private val prefs: BytesStore,
    private val file: File? = null
) {
    var rooms: MutableList<MeshRoom> = mutableListOf()
        private set
    var selectedID: String = MeshRoom.DEFAULT_ID
        private set
    var elsewhere: List<MeshRoom> = emptyList()
        private set
    private val suppressed = mutableSetOf<String>()
    private val json = Json { ignoreUnknownKeys = true }

    val selected: MeshRoom
        get() = rooms.firstOrNull { it.id == selectedID } ?: MeshRoom.sanctuaries[0]

    init {
        load()
        repair()
        save()
    }

    fun canDelete(id: String): Boolean = id !in MeshRoom.sanctuaryIDs && rooms.any { it.id == id }

    fun select(id: String): Boolean {
        if (rooms.none { it.id == id } || id == selectedID) return false
        selectedID = id
        save()
        return true
    }

    fun add(named: String): MeshRoom? {
        val name = MeshRoom.cleaned(named) ?: return null
        val room = MeshRoom(UUID.randomUUID().toString().lowercase(), name, MeshRoom.revisionNow())
        rooms.add(room)
        pinSanctuaries()
        save()
        return room
    }

    fun rename(id: String, to: String): Boolean {
        val index = rooms.indexOfFirst { it.id == id }
        if (index < 0) return false
        val name = MeshRoom.cleaned(to) ?: return false
        if (name == rooms[index].name) return false
        rooms[index] = rooms[index].copy(name = name, revision = MeshRoom.revisionNow())
        save()
        return true
    }

    fun delete(id: String): Boolean {
        val index = rooms.indexOfFirst { it.id == id }
        if (!canDelete(id) || index < 0) return false
        rooms.removeAt(index)
        suppressed.add(id)
        if (selectedID == id) selectedID = rooms.firstOrNull()?.id ?: MeshRoom.DEFAULT_ID
        save()
        return true
    }

    fun restore(id: String): Boolean {
        val room = elsewhere.firstOrNull { it.id == id } ?: return false
        suppressed.remove(id)
        if (rooms.none { it.id == id }) {
            rooms.add(room)
            pinSanctuaries()
        }
        elsewhere = elsewhere.filter { it.id != id }
        save()
        return true
    }

    fun merge(announced: List<AnnouncedRoom>): Boolean {
        val best = linkedMapOf<String, AnnouncedRoom>()
        for (item in announced) {
            val id = MeshRoom.cleanedID(item.id) ?: continue
            val name = MeshRoom.cleaned(item.name) ?: continue
            val clean = AnnouncedRoom(id, name, maxOf(item.revision, 0))
            val existing = best[id]
            if (existing != null && existing.revision >= clean.revision) continue
            best[id] = clean
        }

        var roomsChanged = false
        for (item in best.values) {
            val index = rooms.indexOfFirst { it.id == item.id }
            if (index >= 0) {
                if (item.revision <= rooms[index].revision) continue
                rooms[index] = rooms[index].copy(name = item.name, revision = item.revision)
                roomsChanged = true
            } else if (item.id !in suppressed) {
                rooms.add(MeshRoom(item.id, item.name, item.revision))
                roomsChanged = true
            }
        }
        if (roomsChanged) pinSanctuaries()

        val nextElsewhere = best.values
            .filter { item -> rooms.none { it.id == item.id } }
            .map { MeshRoom(it.id, it.name, it.revision) }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
        val elsewhereChanged = nextElsewhere != elsewhere
        elsewhere = nextElsewhere
        if (roomsChanged) save()
        return roomsChanged || elsewhereChanged
    }

    private fun load() {
        val data = when {
            file != null && file.exists() -> file.readBytes()
            else -> prefs.read(STORAGE_KEY)
        } ?: return
        val snapshot = try {
            json.decodeFromString(Snapshot.serializer(), data.decodeToString())
        } catch (_: Exception) {
            return
        }
        rooms = snapshot.rooms.toMutableList()
        selectedID = snapshot.selectedID
        suppressed.clear()
        suppressed.addAll(snapshot.suppressed)
    }

    private fun repair() {
        rooms = rooms.mapNotNull { room ->
            val id = MeshRoom.cleanedID(room.id) ?: return@mapNotNull null
            val name = MeshRoom.cleaned(room.name) ?: return@mapNotNull null
            MeshRoom(id, name, room.revision)
        }.toMutableList()
        val seen = mutableSetOf<String>()
        rooms = rooms.filter { seen.add(it.id) }.toMutableList()
        for (sanctuary in MeshRoom.sanctuaries) {
            if (rooms.none { it.id == sanctuary.id }) rooms.add(sanctuary)
        }
        pinSanctuaries()
        suppressed.removeAll(MeshRoom.sanctuaryIDs)
        if (rooms.none { it.id == selectedID }) selectedID = MeshRoom.DEFAULT_ID
    }

    private fun pinSanctuaries() {
        val builtIn = MeshRoom.sanctuaries.mapNotNull { sanctuary -> rooms.firstOrNull { it.id == sanctuary.id } }
        val custom = rooms.filter { it.id !in MeshRoom.sanctuaryIDs }
        rooms = (builtIn + custom).toMutableList()
    }

    private fun save() {
        val snapshot = Snapshot(rooms.toList(), selectedID, suppressed.sorted())
        val data = json.encodeToString(Snapshot.serializer(), snapshot).toByteArray(Charsets.UTF_8)
        prefs.write(STORAGE_KEY, data)
        val target = file ?: return
        target.parentFile?.mkdirs()
        target.writeBytes(data)
    }

    @Serializable
    private data class Snapshot(
        val rooms: List<MeshRoom>,
        val selectedID: String,
        val suppressed: List<String>
    )

    companion object {
        const val STORAGE_KEY = "mesh.rooms.v1"
    }
}
