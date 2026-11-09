package app.orb.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.orb.android.Bot

@Composable
fun PairingScreen(
    notice: String?,
    error: String?,
    onScan: () -> Unit,
    onLink: (String) -> Unit,
    modifier: Modifier = Modifier,
    startWithLink: Boolean = false,
) {
    var pasting by rememberSaveable { mutableStateOf(startWithLink) }
    var link by rememberSaveable { mutableStateOf("") }
    Column(
        modifier.fillMaxSize().background(OrbColors.Canvas).statusBarsPadding().navigationBarsPadding().imePadding()
            .verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Spacer(Modifier.height(24.dp))
        OrbAvatar(Bot(id = "welcome", name = "Orb", color = "#5B5BF0"), null, 112.dp)
        Spacer(Modifier.height(28.dp))
        Text("Seus Orbs no celular", color = OrbColors.Ink, fontSize = 26.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Text(
            "Pareie este celular com o Orb do seu Mac para acompanhar o trabalho e responder pedidos de qualquer lugar. " +
                "No Mac, abra Ajustes → Celular e mostre o QR code.",
            color = OrbColors.Muted, fontSize = 15.sp, lineHeight = 22.sp, textAlign = TextAlign.Center,
        )
        if (notice != null) {
            Spacer(Modifier.height(16.dp))
            Text(
                notice, color = OrbColors.Warn, fontSize = 14.sp, lineHeight = 20.sp, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().background(OrbColors.Surface, RoundedCornerShape(12.dp)).padding(12.dp),
            )
        }
        Spacer(Modifier.height(28.dp))
        PrimaryPill("Ler QR code", onScan, Modifier.fillMaxWidth())
        Spacer(Modifier.height(4.dp))
        TextAction("Colar link", { pasting = !pasting }, Modifier.fillMaxWidth())
        AnimatedVisibility(pasting) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.fillMaxWidth().background(OrbColors.Surface, RoundedCornerShape(14.dp)).padding(14.dp)) {
                    if (link.isEmpty()) Text("orb://parear?host=…", color = OrbColors.Hint, fontSize = 15.sp)
                    BasicTextField(
                        link, { link = it },
                        textStyle = TextStyle(color = OrbColors.Ink, fontSize = 15.sp, lineHeight = 20.sp),
                        cursorBrush = SolidColor(OrbColors.Ink),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                PrimaryPill("Parear", { onLink(link) }, Modifier.fillMaxWidth(), enabled = link.isNotBlank())
            }
        }
        if (error != null) {
            Spacer(Modifier.height(12.dp))
            Text(error, color = OrbColors.Danger, fontSize = 14.sp, textAlign = TextAlign.Center)
        }
    }
}
