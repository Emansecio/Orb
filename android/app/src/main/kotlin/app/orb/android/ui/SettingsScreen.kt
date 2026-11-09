package app.orb.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun SettingsScreen(
    mac: String,
    host: String,
    keepAlive: Boolean,
    onKeepAlive: (Boolean) -> Unit,
    onUnpair: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirm by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize().background(OrbColors.Canvas).statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.padding(start = 4.dp, top = 4.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onBack, Modifier.size(48.dp)) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Voltar", tint = OrbColors.Ink) }
            Text("Ajustes", color = OrbColors.Ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        }
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Conectado a", color = OrbColors.Faint, fontSize = 12.sp)
            Text(mac.ifBlank { "Mac" }, color = OrbColors.Ink, fontSize = 17.sp)
            Text(host, color = OrbColors.Muted, fontSize = 13.sp)
        }
        Row(
            Modifier.fillMaxWidth().clickable { onKeepAlive(!keepAlive) }.padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).padding(end = 16.dp)) {
                Text("Manter conectado em segundo plano", color = OrbColors.Ink, fontSize = 16.sp)
                Text(
                    "Mostra um aviso fixo e permite receber notificações quando um Orb precisa de você ou responde.",
                    color = OrbColors.Muted, fontSize = 13.sp, lineHeight = 18.sp,
                )
            }
            Switch(
                keepAlive, onKeepAlive,
                colors = SwitchDefaults.colors(checkedTrackColor = OrbColors.Accent, checkedThumbColor = androidx.compose.ui.graphics.Color.White),
            )
        }
        TextAction("Desparear este celular", { confirm = true }, Modifier.padding(horizontal = 8.dp), color = OrbColors.Danger)
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Desparear este celular?") },
            text = { Text("Você precisará ler o QR code do Mac de novo para voltar a usar o app.") },
            confirmButton = { TextButton({ confirm = false; onUnpair() }) { Text("Desparear", color = OrbColors.Danger) } },
            dismissButton = { TextButton({ confirm = false }) { Text("Cancelar") } },
        )
    }
}
