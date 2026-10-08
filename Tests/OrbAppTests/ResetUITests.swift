import AppKit
import Foundation
import Testing
@testable import Orb

/// The words and the keys of "Redefinir o Orb", of the "Memórias guardadas" row and of the new-Orb sheet's
/// "Começar de" menu.
@Suite(.serialized) @MainActor final class ResetUITests {
    // MARK: Ajustes

    @Test func theKeptMemoriesRowSaysHowManyAndThatANewOrbCanStartFromOne() {
        #expect(GeneralSettings.keptMemoriesDetail(count: 0) == "Nenhuma ainda")
        #expect(GeneralSettings.keptMemoriesDetail(count: 1) == "1 guardada · um Orb novo pode começar dela")
        #expect(GeneralSettings.keptMemoriesDetail(count: 2) == "2 guardadas · um Orb novo pode começar de uma delas")
    }

    @Test func theSnapshotScenesExist() {
        #expect(SettingsSnapshots.view("settings-reset", firstBotID: nil) != nil)
        #expect(SettingsSnapshots.view("settings-general", firstBotID: nil) != nil)
    }

    // MARK: The alert

    @Test func theAlertSaysWhatWillHappenByTheChoice() {
        #expect(ResetConfirmation.message(for: ResetOptions(memories: .keep, leavesProviders: false), relaunches: true)
            == "As memórias vão para Memórias guardadas.")
        #expect(ResetConfirmation.message(for: ResetOptions(memories: .erase, leavesProviders: false), relaunches: true)
            == "Tudo será apagado, inclusive as memórias. Não dá para desfazer.")
        let both = ResetConfirmation.message(for: ResetOptions(memories: .erase, leavesProviders: true), relaunches: true)
        #expect(both.hasPrefix("Tudo será apagado, inclusive as memórias. Não dá para desfazer.") && both.contains("chaves e os logins"))
        // Out of an installed app there is nothing to open again: it says it only closes.
        #expect(ResetConfirmation.message(for: ResetOptions(), relaunches: false).contains("só vai fechar"))
    }

    /// Presses a key in the alert's panel and says which button took it.
    private func pressed(_ characters: String, keyCode: UInt16, in alert: NSAlert) -> String? {
        final class Probe: NSObject {
            var hit: String?
            @objc func press(_ sender: NSButton) { hit = sender.title }
        }
        let probe = Probe()
        for button in alert.buttons {
            button.target = probe
            button.action = #selector(Probe.press(_:))
        }
        let window = alert.window
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        _ = window.performKeyEquivalent(with: event)
        return probe.hit
    }

    @Test func theAlertsDestructiveButtonNeverTakesReturnAndEscapeCancels() {
        let alert = ResetConfirmation.makeAlert(for: ResetOptions(), relaunches: true)
        #expect(alert.messageText == "Redefinir o Orb agora?")
        #expect(alert.buttons.map(\.title) == ["Cancelar", "Redefinir e reabrir"])
        #expect(alert.buttons[1].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
        #expect(pressed("\r", keyCode: 36, in: alert) == nil) // Return presses no button
        #expect(pressed("\u{1b}", keyCode: 53, in: ResetConfirmation.makeAlert(for: ResetOptions(), relaunches: true)) == "Cancelar")
    }

    // MARK: Começar de

    @Test func choosingAMemoryFillsTheNameTheRoleAndTheLook() {
        let look = OrbConfig(color: "rosa", eyes: "ovais", hair: "coque")
        let memory = KeptMemory(id: "Atlas – 2026-10-08 12.30", url: URL(fileURLWithPath: "/tmp/x"), name: "Atlas", date: .now, pageCount: 12,
                                profile: KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: look))
        var name = "", role = "", orb = OrbConfig(color: "indigo")
        memory.fill(name: &name, role: &role, orb: &orb)
        #expect(name == "Atlas" && role == "Cuida da agenda" && orb == look)
        #expect(memory.startingNote == "Nome, papel e aparência vieram da memória. Dá para mudar.")
    }

    @Test func aMemoryWithoutAProfileOnlyGivesTheName() {
        let memory = KeptMemory(id: "Velho – 2026-01-02 03.04", url: URL(fileURLWithPath: "/tmp/y"), name: "Velho", date: .now, pageCount: 1,
                                profile: nil)
        var name = "", role = "Papel digitado", orb = OrbConfig(color: "sol")
        memory.fill(name: &name, role: &role, orb: &orb)
        #expect(name == "Velho" && role == "Papel digitado" && orb == OrbConfig(color: "sol"))
        #expect(memory.startingNote == "O nome veio da memória. Dá para mudar.")
        #expect(memory.menuTitle.hasSuffix(" · 1 lembrança"))
    }

    @Test func goingBackToNoMemoryTakesBackWhatItGaveButKeepsWhatWasTyped() {
        let look = OrbConfig(color: "rosa", eyes: "ovais", hair: "coque")
        let memory = KeptMemory(id: "Nina – 2026-10-08 12.30", url: URL(fileURLWithPath: "/tmp/z"), name: "Nina", date: .now, pageCount: 3,
                                profile: KeptProfile(name: "Nina", role: "Estuda comigo", orb: look))
        let before = StartSnapshot(name: "Ana", role: "", orb: OrbConfig(color: "indigo"))
        var name = before.name, role = before.role, orb = before.orb
        memory.fill(name: &name, role: &role, orb: &orb)
        role = "Estuda e revisa comigo" // the person edited the role after choosing
        memory.unfill(name: &name, role: &role, orb: &orb, before: before)
        #expect(name == "Ana" && orb == OrbConfig(color: "indigo")) // as they were
        #expect(role == "Estuda e revisa comigo") // what was typed stays
    }
}
