import Foundation
import Testing
@testable import Orb

/// The shortcut hints of the approval and question cards, the VoiceOver line of a failed tool, and which Orb's side
/// work a chat presents.
@Suite("Dicas das permissões e acessibilidade") struct ApprovalHintsTests {
    @Test func theKeyIsOnlyPromisedWhereItAnswersTheCard() {
        #expect(ApprovalHints.accessibilityHint("Esc", showsKeys: true) == "Atalho: Esc")
        #expect(ApprovalHints.accessibilityHint("Esc", showsKeys: false) == "")
        #expect(ApprovalHints.help("Recusa o pedido", key: "Esc", showsKeys: true) == "Recusa o pedido (Esc)")
        #expect(ApprovalHints.help("Recusa o pedido", key: "Esc", showsKeys: false) == "Recusa o pedido")
    }

    @Test func theRecordOfAnAnsweredCardSaysWhatTheClickDoesInItsState() {
        #expect(ApprovalHints.toggleRequest(isOpen: false) == "Mostra o pedido")
        #expect(ApprovalHints.toggleRequest(isOpen: true) == "Esconde o pedido")
    }

    @Test func aFailedToolLineDoesNotSayItFailedTwice() {
        #expect(TranscriptSpeech.tool(title: "Falhou", detail: "swift build", state: .failed) == "Falhou swift build")
        #expect(TranscriptSpeech.tool(title: "Falhou ao ler", detail: "a.txt", state: .failed) == "Falhou ao ler a.txt")
        #expect(TranscriptSpeech.tool(title: "Rodou", detail: "ls", state: .failed) == "Rodou ls, falhou")
        #expect(TranscriptSpeech.tool(title: "Falhou", detail: "ls", state: .done) == "Falhou ls")
    }

    @Test func aChatPresentsOnlyTheSideWorkOfItsOwnOrb() {
        let mine = UUID(), other = UUID()
        let target = SideWorkTarget(botID: mine, requestID: UUID())
        #expect(SideWorkTarget.shown(target, for: mine) == target)
        #expect(SideWorkTarget.shown(target, for: other) == nil)
        #expect(SideWorkTarget.shown(nil, for: mine) == nil)
    }
}
