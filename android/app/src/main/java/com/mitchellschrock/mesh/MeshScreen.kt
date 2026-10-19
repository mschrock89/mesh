package com.mitchellschrock.mesh

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mesh.MeshRoom
import mesh.PeerSnapshot

private val Background = Color(0xFF121416)
private val Card = Color(0xFF1C1E21)
private val Blue = Color(0xFF35B0E5)
private val BlueDark = Color(0xFF27749D)
private val Teal = Color(0xFF008DB3)
private val Yellow = Color(0xFFFFB838)
private val Muted = Color.White.copy(alpha = 0.68f)
private val Faint = Color.White.copy(alpha = 0.42f)
private val Border = Color(0xFF333333)
private val Danger = Color(0xFFDB4747)
private val Shape = RoundedCornerShape(8.dp)

@Composable
fun MeshScreen(ui: MeshUi) {
    var editing by remember { mutableStateOf(false) }
    var newRoom by remember { mutableStateOf("") }
    val drafts = remember { mutableStateMapOf<String, String>() }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Background),
        contentAlignment = Alignment.TopCenter
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 480.dp)
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .background(Brush.horizontalGradient(listOf(Blue, Teal)))
            )
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Header(ui)
                StatusCard(ui)
                RoomCard(
                    ui = ui,
                    editing = editing,
                    drafts = drafts,
                    newRoom = newRoom,
                    onNewRoom = { newRoom = it },
                    onToggleEdit = {
                        if (editing) commitDrafts(drafts)
                        editing = !editing
                    },
                    onSelect = { id ->
                        commitDrafts(drafts)
                        MeshHub.selectRoom(id)
                    },
                    onCommit = { id ->
                        drafts.remove(id)?.let { MeshHub.renameRoom(id, it) }
                    },
                    onDraft = { id, value -> drafts[id] = value },
                    onRemove = { id ->
                        drafts.remove(id)
                        MeshHub.deleteRoom(id)
                    },
                    onAdd = {
                        if (MeshHub.addRoom(newRoom)) newRoom = ""
                    },
                    onRestore = { MeshHub.restoreRoom(it) }
                )
                PeerCard(ui)
                Footer()
            }
        }
    }
}

@Composable
private fun Header(ui: MeshUi) {
    val live = ui.connectedCount > 0 && ui.errorText == null
    Row(verticalAlignment = Alignment.CenterVertically) {
        MeshMark()
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            TextLine("Mesh", 22, FontWeight.SemiBold, Color.White)
            TextLine("NETWORK MIDI", 10, FontWeight.Medium, Blue, spacing = 1.6)
        }
        TextLine(
            ui.statusText.uppercase(),
            10,
            FontWeight.Medium,
            if (live) Yellow else Blue,
            spacing = 0.8,
            modifier = Modifier
                .clip(CircleShape)
                .background((if (live) Yellow else Blue).copy(alpha = 0.16f))
                .padding(horizontal = 8.dp, vertical = 4.dp)
        )
    }
}

@Composable
private fun StatusCard(ui: MeshUi) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TextLine(ui.detailText, 14, FontWeight.Normal, Color.White)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                TextLine(ui.localKind, 10, FontWeight.Medium, Faint, spacing = 1.2)
                TextLine(ui.localName.ifEmpty { "This tablet" }, 14, FontWeight.Medium, Color.White)
            }
            if (ui.port > 0) TextLine("Port ${ui.port}", 12, FontWeight.Normal, Muted)
        }
        ui.errorText?.let { TextLine(it, 12, FontWeight.Normal, Danger) }
    }
}

@Composable
private fun RoomCard(
    ui: MeshUi,
    editing: Boolean,
    drafts: Map<String, String>,
    newRoom: String,
    onNewRoom: (String) -> Unit,
    onToggleEdit: () -> Unit,
    onSelect: (String) -> Unit,
    onCommit: (String) -> Unit,
    onDraft: (String, String) -> Unit,
    onRemove: (String) -> Unit,
    onAdd: () -> Unit,
    onRestore: (String) -> Unit
) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextLine("ROOM", 10, FontWeight.Medium, Faint, spacing = 1.2)
        for (room in ui.rooms) {
            RoomChoice(
                room = room,
                selected = room.id == ui.roomID,
                editing = editing,
                draft = drafts[room.id] ?: room.name,
                canRemove = MeshHub.canDelete(room.id),
                onSelect = { onSelect(room.id) },
                onDraft = { onDraft(room.id, it) },
                onCommit = { onCommit(room.id) },
                onRemove = { onRemove(room.id) }
            )
        }
        TextLine(
            "Devices in different rooms never share MIDI.",
            12,
            FontWeight.Normal,
            Muted
        )
        if (editing) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Field(
                    value = newRoom,
                    onValue = onNewRoom,
                    placeholder = "New room",
                    onDone = onAdd,
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(8.dp))
                TextLine(
                    "Add",
                    13,
                    FontWeight.Normal,
                    Yellow,
                    modifier = Modifier.clickable(onClick = onAdd).padding(8.dp)
                )
            }
            if (ui.elsewhere.isNotEmpty()) {
                TextLine("ALSO ON THE NETWORK", 10, FontWeight.Medium, Faint, spacing = 1.2)
                for (room in ui.elsewhere) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextLine(room.name, 13, FontWeight.Normal, Muted, modifier = Modifier.weight(1f))
                        TextLine(
                            "Add",
                            13,
                            FontWeight.Normal,
                            Blue,
                            modifier = Modifier.clickable { onRestore(room.id) }.padding(8.dp)
                        )
                    }
                }
            }
        }
        TextLine(
            if (editing) "Done" else "Edit rooms",
            13,
            FontWeight.Normal,
            Blue,
            modifier = Modifier.clickable(onClick = onToggleEdit)
        )
    }
}

@Composable
private fun RoomChoice(
    room: MeshRoom,
    selected: Boolean,
    editing: Boolean,
    draft: String,
    canRemove: Boolean,
    onSelect: () -> Unit,
    onDraft: (String) -> Unit,
    onCommit: () -> Unit,
    onRemove: () -> Unit
) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 5.dp)) {
        Row(
            modifier = Modifier
                .weight(1f)
                .clickable(onClick = onSelect),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(14.dp)
                    .border(1.5.dp, if (selected) Yellow else Color.White.copy(alpha = 0.35f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                if (selected) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(Yellow))
                }
            }
            Spacer(Modifier.width(10.dp))
            if (!editing) {
                TextLine(room.name, 14, FontWeight.Medium, Color.White)
            }
        }
        if (editing) {
            Field(draft, onDraft, "Room name", onCommit, Modifier.weight(1f))
            if (canRemove) {
                Spacer(Modifier.width(8.dp))
                TextLine("Remove", 12, FontWeight.Normal, Muted, modifier = Modifier.clickable(onClick = onRemove))
            }
        }
    }
}

@Composable
private fun PeerCard(ui: MeshUi) {
    val roomName = ui.rooms.firstOrNull { it.id == ui.roomID }?.name ?: "this room"
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextLine("IN THIS ROOM", 10, FontWeight.Medium, Faint, spacing = 1.2)
        if (ui.peers.isEmpty()) {
            TextLine(
                "Other devices in $roomName will show up here and stay connected.",
                13,
                FontWeight.Normal,
                Muted,
                modifier = Modifier.padding(vertical = 6.dp)
            )
        } else {
            ui.peers.forEachIndexed { index, peer ->
                PeerRow(peer)
                if (index != ui.peers.lastIndex) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Border))
                }
            }
        }
    }
}

@Composable
private fun PeerRow(peer: PeerSnapshot) {
    val live = peer.status == PeerSnapshot.Status.Connected || peer.status == PeerSnapshot.Status.Bridged
    val color = when (peer.status) {
        PeerSnapshot.Status.Connected, PeerSnapshot.Status.Bridged -> Yellow
        PeerSnapshot.Status.Connecting -> Blue
        PeerSnapshot.Status.Waiting -> Color.White.copy(alpha = 0.35f)
    }
    val label = when (peer.status) {
        PeerSnapshot.Status.Connected, PeerSnapshot.Status.Bridged -> "Connected"
        PeerSnapshot.Status.Connecting -> "Connecting"
        PeerSnapshot.Status.Waiting -> "Waiting"
    }
    Row(Modifier.padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            TextLine(peer.name, 14, FontWeight.Medium, Color.White)
            if (peer.status == PeerSnapshot.Status.Bridged && !peer.via.isNullOrEmpty()) {
                TextLine("Through ${peer.via}", 11, FontWeight.Normal, Muted)
            }
        }
        TextLine(label, 12, FontWeight.Normal, if (live) Yellow else Muted)
    }
}

@Composable
private fun Footer() {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(Shape)
                .background(Brush.linearGradient(listOf(Blue, BlueDark)))
                .clickable { MeshHub.reconnect() }
                .padding(vertical = 8.dp),
            contentAlignment = Alignment.Center
        ) {
            TextLine("Reconnect", 13, FontWeight.SemiBold, Color.White)
        }
        TextLine(
            "Mesh stays in the room while the screen is locked. Other apps open it as a MIDI device named Mesh.",
            12,
            FontWeight.Normal,
            Muted
        )
    }
}

@Composable
private fun MeshMark() {
    Canvas(Modifier.size(36.dp, 28.dp)) {
        val points = listOf(
            Offset(size.width * 0.18f, size.height * 0.72f),
            Offset(size.width * 0.52f, size.height * 0.22f),
            Offset(size.width * 0.84f, size.height * 0.64f)
        )
        val width = 1.6.dp.toPx()
        drawLine(Blue, points[0], points[1], strokeWidth = width)
        drawLine(Blue, points[1], points[2], strokeWidth = width)
        drawLine(Blue, points[0], points[2], strokeWidth = width)
        points.forEachIndexed { index, point ->
            drawCircle(if (index == 1) Yellow else Blue, radius = 3.5.dp.toPx(), center = point)
        }
    }
}

@Composable
private fun Field(
    value: String,
    onValue: (String) -> Unit,
    placeholder: String,
    onDone: () -> Unit,
    modifier: Modifier = Modifier
) {
    BasicTextField(
        value = value,
        onValueChange = onValue,
        singleLine = true,
        textStyle = TextStyle(color = Color.White, fontSize = 14.sp, fontFamily = FontFamily.SansSerif),
        cursorBrush = SolidColor(Blue),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Background)
            .border(1.dp, Border, RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp, vertical = 6.dp),
        decorationBox = { inner ->
            Box(Modifier.fillMaxWidth()) {
                if (value.isEmpty()) TextLine(placeholder, 14, FontWeight.Normal, Faint)
                inner()
            }
        }
    )
}

@Composable
private fun TextLine(
    text: String,
    size: Int,
    weight: FontWeight,
    color: Color,
    spacing: Double = 0.0,
    modifier: Modifier = Modifier
) {
    androidx.compose.foundation.text.BasicText(
        text = text,
        modifier = modifier,
        style = TextStyle(
            color = color,
            fontSize = size.sp,
            fontWeight = weight,
            fontFamily = FontFamily.SansSerif,
            letterSpacing = spacing.sp,
            lineHeight = (size + 4).sp
        ),
        maxLines = 3,
        overflow = TextOverflow.Ellipsis
    )
}

private fun commitDrafts(drafts: MutableMap<String, String>) {
    val pending = drafts.toMap()
    drafts.clear()
    for ((id, name) in pending) MeshHub.renameRoom(id, name)
}

private fun Modifier.card(): Modifier = this
    .fillMaxWidth()
    .clip(Shape)
    .background(Card)
    .border(1.dp, Border, Shape)
    .padding(12.dp)
