package app.orb.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.BubbleChart
import androidx.compose.material.icons.outlined.Cable
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.orb.android.ApprovalInfo
import app.orb.android.Item
import app.orb.android.Row as ChatRow

private fun kindIcon(kind: String?): ImageVector = when (kind) {
    "browser" -> Icons.Outlined.Language
    "file" -> Icons.Outlined.Description
    "search" -> Icons.Outlined.Search
    "computer" -> Icons.Outlined.DesktopWindows
    "connector" -> Icons.Outlined.Cable
    "memory" -> Icons.Outlined.Memory
    "schedule" -> Icons.Outlined.Schedule
    "orbs" -> Icons.Outlined.BubbleChart
    "plan" -> Icons.Outlined.Checklist
    else -> Icons.Outlined.Terminal
}

@Composable
fun ToolsGroup(row: ChatRow.Tools) {
    // Saveable and keyed by the group's first id: stays open when actions are appended or the row scrolls away.
    var open by rememberSaveable(row.key) { mutableStateOf(false) }
    val items = row.items
    val running = items.any { it.tool?.state == "running" }
    val summary = if (items.size == 1) items[0].text.ifBlank { items[0].tool?.title.orEmpty() } else "Trabalhou · ${items.size} ações"
    val chevron by animateFloatAsState(if (open) 90f else 0f, tween(200), label = "chevron")
    Column(Modifier.fillMaxWidth().padding(start = 40.dp).animateContentSize(tween(200))) {
        Row(
            Modifier.clickable { open = !open }.defaultMinSize(minHeight = 40.dp)
                .semantics { contentDescription = if (open) "Recolher ações" else "Mostrar ações" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (running) CircularProgressIndicator(Modifier.size(14.dp), color = OrbColors.Muted, strokeWidth = 2.dp)
            else Icon(kindIcon(items.last().tool?.kind), null, tint = OrbColors.Muted, modifier = Modifier.size(16.dp))
            Text(summary, color = OrbColors.Muted, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, null, tint = OrbColors.Muted, modifier = Modifier.size(16.dp).rotate(chevron))
        }
        if (open) {
            Column(Modifier.padding(bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items.forEach { ToolDetail(it) }
            }
        }
    }
}

@Composable
private fun ToolDetail(item: Item) {
    val tool = item.tool
    val failed = tool?.state == "failed"
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(kindIcon(tool?.kind), null, tint = if (failed) OrbColors.Danger else OrbColors.Faint, modifier = Modifier.padding(top = 2.dp).size(16.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                tool?.title?.ifBlank { null } ?: item.text, color = if (failed) OrbColors.Danger else OrbColors.InkSecondary,
                fontSize = 14.sp, lineHeight = 19.sp,
            )
            tool?.detail?.takeIf { it.isNotBlank() }?.let {
                Text(
                    it, color = OrbColors.Muted, fontSize = 12.sp, lineHeight = 17.sp, fontFamily = FontFamily.Monospace, maxLines = 8,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().background(OrbColors.Raised, RoundedCornerShape(8.dp)).padding(8.dp),
                )
            }
        }
        when (tool?.state) {
            "running" -> CircularProgressIndicator(Modifier.padding(top = 2.dp).size(14.dp), color = OrbColors.Muted, strokeWidth = 2.dp)
            "failed" -> Text("Falhou", color = OrbColors.Danger, fontSize = 12.sp)
        }
    }
}

private fun decidedText(a: ApprovalInfo): String = when (a.decision) {
    "once" -> if (a.kind == "question") "Respondido" else "Permitido uma vez"
    "task" -> "Permitido nesta tarefa"
    "always" -> "Permitido sempre"
    "deny" -> if (a.kind == "question") "Pulado" else "Negado"
    "review" -> "Para revisar no Mac"
    else -> "Respondido"
}

@Composable
fun ApprovalRowContent(item: Item, submitted: Set<String>, actions: ChatActions, modifier: Modifier = Modifier) {
    val a = item.approval ?: return
    if (a.decision != null || item.id in submitted) {
        Text(
            if (a.decision != null) decidedText(a) else "Enviando…", color = OrbColors.Faint, fontSize = 12.sp,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        )
        return
    }
    Column(
        modifier.fillMaxWidth().background(OrbColors.Surface, RoundedCornerShape(16.dp))
            .border(1.dp, OrbColors.Line, RoundedCornerShape(16.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (a.dangerous) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.WarningAmber, null, tint = OrbColors.Warn, modifier = Modifier.size(16.dp))
                Text("Ação arriscada", color = OrbColors.Warn, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }
        val title = a.question?.text?.takeIf { a.kind == "question" && it.isNotBlank() } ?: a.title.ifBlank { item.text }
        Text(title, color = OrbColors.Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, lineHeight = 22.sp)
        a.command?.takeIf { it.isNotBlank() }?.let {
            Text(
                it, color = OrbColors.InkSecondary, fontSize = 13.sp, lineHeight = 19.sp, fontFamily = FontFamily.Monospace, maxLines = 12,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth().background(OrbColors.Raised, RoundedCornerShape(10.dp)).padding(12.dp),
            )
        }
        a.reason?.takeIf { it.isNotBlank() }?.let { Text(it, color = OrbColors.Muted, fontSize = 14.sp, lineHeight = 20.sp) }
        when (a.kind) {
            "permission" -> PermissionButtons(item.id, a, actions)
            "question" -> QuestionControls(item.id, a, actions)
            else -> {
                Text("Resolva no Mac", color = OrbColors.Faint, fontSize = 13.sp)
                Row {
                    TextAction("Recusar", { actions.onDecide(item.id, "deny", null, null) })
                }
            }
        }
    }
}

@Composable
private fun SmallField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    Box(
        modifier.fillMaxWidth().background(OrbColors.Raised, RoundedCornerShape(12.dp)).padding(horizontal = 12.dp, vertical = 12.dp),
    ) {
        if (value.isEmpty()) Text(placeholder, color = OrbColors.Hint, fontSize = 15.sp)
        BasicTextField(
            value, onChange, textStyle = TextStyle(color = OrbColors.Ink, fontSize = 15.sp, lineHeight = 20.sp),
            cursorBrush = SolidColor(OrbColors.Ink), modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun PermissionButtons(id: String, a: ApprovalInfo, actions: ChatActions) {
    var instead by rememberSaveable(id) { mutableStateOf(false) }
    var note by rememberSaveable(id) { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    // A dangerous action asks for fingerprint / device PIN right before the "allow" leaves the phone.
    fun allow(decision: String) {
        if (a.dangerous) actions.authenticate { actions.onDecide(id, decision, null, null) } else actions.onDecide(id, decision, null, null)
    }
    Row(
        Modifier.clickable { instead = !instead }.defaultMinSize(minHeight = 40.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = OrbColors.Link, modifier = Modifier.size(18.dp))
        Text("Dizer o que fazer em vez disso", color = OrbColors.Link, fontSize = 15.sp)
    }
    AnimatedVisibility(instead) {
        SmallField(note, { note = it }, "O que o Orb deve fazer em vez disso")
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextAction("Não permitir", { actions.onDecide(id, "deny", null, note.trim().takeIf { instead && it.isNotEmpty() }) })
        Spacer(Modifier.weight(1f))
        Row(
            Modifier.defaultMinSize(minHeight = 48.dp).background(Color.White, CircleShape),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.defaultMinSize(minHeight = 48.dp).clickable { allow("once") }
                    .padding(start = 22.dp, end = if (a.canAlways) 14.dp else 22.dp),
                contentAlignment = Alignment.Center,
            ) { Text("Permitir", color = OrbColors.OnPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium) }
            if (a.canAlways) {
                Box(Modifier.width(1.dp).height(22.dp).background(Color.Black.copy(alpha = 0.18f)))
                Box {
                    Box(
                        Modifier.size(width = 44.dp, height = 48.dp).clickable { menu = true }
                            .semantics { contentDescription = "Mais opções de permissão" },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Outlined.ExpandMore, null, tint = OrbColors.OnPrimary, modifier = Modifier.size(20.dp)) }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem({ Text("Só nesta tarefa") }, { menu = false; allow("task") })
                        DropdownMenuItem({ Text("Sempre permitir") }, { menu = false; allow("always") })
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QuestionControls(id: String, a: ApprovalInfo, actions: ChatActions) {
    val q = a.question
    val options = q?.options.orEmpty()
    val multiple = q?.multiple == true
    var picked by rememberSaveable(id) { mutableStateOf(listOf<String>()) }
    var text by rememberSaveable(id) { mutableStateOf("") }
    if (options.isNotEmpty()) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { opt ->
                val on = opt in picked
                Box(
                    Modifier.defaultMinSize(minHeight = 40.dp)
                        .background(if (on) Color.White else OrbColors.Raised, RoundedCornerShape(20.dp))
                        .clickable { picked = if (multiple) (if (on) picked - opt else picked + opt) else if (on) emptyList() else listOf(opt) }
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) { Text(opt, color = if (on) OrbColors.OnPrimary else OrbColors.Ink, fontSize = 14.sp) }
            }
        }
    }
    SmallField(text, { text = it }, if (options.isEmpty()) "Sua resposta" else "Ou escreva a resposta")
    val reply = text.trim().ifEmpty { picked.joinToString(", ") }
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextAction("Pular", { actions.onDecide(id, "deny", null, null) })
        Spacer(Modifier.weight(1f))
        PrimaryPill("Responder", { actions.onDecide(id, "once", reply, null) }, enabled = reply.isNotEmpty())
    }
}
