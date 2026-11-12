import Foundation
import Testing
@testable import Orb

@Suite struct ConversationExportTests {
    @Test func theFileReadsAsTheChatDoesWithoutWhatTheActionsReturned() throws {
        var failed = ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "npm test\necho fim", state: .failed)
        failed.output = "SEGREDO DA SAÍDA"
        let items = [
            TranscriptItem(.greeting("Oi! Sou o Atlas.")),
            TranscriptItem(.user(text: "Publica o site", attachments: ["/Users/ana/notas finais.pdf"])),
            TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "./deploy.sh --prod", state: .done))),
            TranscriptItem(.tool(failed)),
            TranscriptItem(.bot(text: "Publicado.\n\n| a | b |\n|---|---|\n| 1 | 2 |", isStreaming: false)),
            TranscriptItem(.notice("Conversa compactada.")),
            TranscriptItem(.bot(text: "   ", isStreaming: false)),
        ]
        let text = try #require(ConversationExport.markdown(items, orb: "Atlas", person: "Ana"))
        #expect(text.hasPrefix("# Conversa com Atlas\n\nExportada em "))
        #expect(text.contains("**Atlas** · ") && text.contains("Oi! Sou o Atlas."))
        #expect(text.contains("Publica o site\n- Anexo: notas finais.pdf"))
        #expect(text.contains("- Rodando no Terminal `./deploy.sh --prod`\n- Rodando no Terminal `npm test` (falhou)"))
        #expect(text.contains("| 1 | 2 |") && text.contains("> Conversa compactada."))
        #expect(!text.contains("SEGREDO") && !text.contains("echo fim") && !text.contains("/Users/ana"))
        #expect(text.components(separatedBy: "**Atlas** · ").count == 3, "an empty reply is not a turn")
    }

    @Test func aConversationWithNothingSaidHasNoFile() {
        #expect(ConversationExport.markdown([], orb: "Atlas", person: "Ana") == nil)
        #expect(ConversationExport.markdown([TranscriptItem(.notice("oi"))], orb: "Atlas", person: "Ana") == nil)
    }

    @Test func theFileNameIsSafeInAnyFolder() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let name = ConversationExport.fileName(orb: "A/B: C", now: day)
        #expect(name.hasPrefix("Conversa com A B  C ") && name.hasSuffix(".md") && !name.contains("/") && !name.contains(":"))
        #expect(ConversationExport.fileName(orb: " ", now: day).hasPrefix("Conversa com Orb "))
    }
}
