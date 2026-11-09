package app.orb.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.layout.Layout
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikepenz.markdown.compose.elements.MarkdownText
import org.intellij.markdown.ast.ASTNode
import org.intellij.markdown.flavours.gfm.GFMElementTypes
import org.intellij.markdown.flavours.gfm.GFMTokenTypes

private val MinCell = 64.dp
private val MaxCell = 200.dp

/**
 * GFM table whose columns are as wide as their content (64 to 200 dp) and that scrolls sideways when it is wider
 * than the screen. The library's own table uses one fixed width for every cell, which truncated "Documentos".
 */
@Composable
fun OrbTable(content: String, node: ASTNode) {
    val rows = remember(node) {
        node.children.filter { it.type == GFMElementTypes.HEADER || it.type == GFMElementTypes.ROW }
            .map { row -> (row.type == GFMElementTypes.HEADER) to row.children.filter { it.type == GFMTokenTypes.CELL } }
    }
    val cols = rows.maxOfOrNull { it.second.size } ?: return
    val body = TextStyle(color = OrbColors.Ink, fontSize = 14.sp, lineHeight = 19.sp)
    Box(Modifier.clip(RoundedCornerShape(12.dp)).background(OrbColors.Surface).horizontalScroll(rememberScrollState())) {
        Layout(
            content = {
                for ((header, cells) in rows) for (c in 0 until cols) {
                    Box(Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) {
                        cells.getOrNull(c)?.let {
                            MarkdownText(content, it, if (header) body.copy(fontWeight = FontWeight.Bold) else body)
                        }
                    }
                }
            },
        ) { measurables, _ ->
            val min = MinCell.roundToPx(); val max = MaxCell.roundToPx()
            val widths = IntArray(cols) { min }
            measurables.forEachIndexed { i, m ->
                val c = i % cols
                widths[c] = maxOf(widths[c], m.maxIntrinsicWidth(Int.MAX_VALUE).coerceIn(min, max))
            }
            val placeables = measurables.mapIndexed { i, m -> m.measure(androidx.compose.ui.unit.Constraints.fixedWidth(widths[i % cols])) }
            val rowH = IntArray(rows.size) { r -> (0 until cols).maxOf { placeables[r * cols + it].height } }
            layout(widths.sum(), rowH.sum()) {
                var y = 0
                for (r in rows.indices) {
                    var x = 0
                    for (c in 0 until cols) { placeables[r * cols + c].placeRelative(x, y); x += widths[c] }
                    y += rowH[r]
                }
            }
        }
    }
}
