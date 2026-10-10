import Foundation
import Testing
@testable import Orb

/// The hover texts (`Tip`): they keep one style, the keys in them come from the shortcut catalog, and no button that is
/// only an icon is left without one. The last check reads the source files (a few milliseconds) instead of drawing the
/// views: a button added tomorrow without a tip fails here, not in someone's hand.
struct HoverTipsTests {
    // MARK: Style

    @Test func everyTipIsOneShortSentenceWithoutAFullStop() {
        for tip in Tip.all {
            #expect(!tip.isEmpty)
            #expect(tip.count <= 90, "longa demais (\(tip.count)): \(tip)")
            #expect(!tip.hasSuffix("."), "ponto final: \(tip)")
            #expect(tip == tip.trimmingCharacters(in: .whitespaces), "espaço na ponta: \(tip)")
            #expect(tip.first?.isUppercase == true, "começa em minúscula: \(tip)")
            #expect(!tip.contains("  "), "espaço duplo: \(tip)")
            #expect(!tip.contains("\n"), "mais de uma linha: \(tip)")
        }
    }

    @Test func noTwoTipsAreTheSameText() {
        // The same action is never explained twice; a text two controls share is one constant.
        let tips = Tip.all
        #expect(Set(tips).count == tips.count, "textos repetidos: \(Dictionary(grouping: tips, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    @Test func aKeyInATipComesFromTheShortcutCatalog() {
        // A fixed text never carries a key by hand: only the functions below do, reading it from AppShortcut.
        let keyGlyphs = CharacterSet(charactersIn: "⌘⌥⇧⌃↩")
        let fixed = Tip.all.filter { $0.rangeOfCharacter(from: keyGlyphs) != nil }
        let withKeys: [String] = [Tip.newBot(), Tip.settings(), Tip.conversations(), Tip.newConversation(), Tip.inspector(isShowing: true), Tip.inspector(isShowing: false),
                                  Tip.createOrbSheet(), Tip.findInConversation(), Tip.findNext(), Tip.findPrevious()]
        #expect(Set(fixed) == Set(withKeys))
        #expect(Tip.newBot().contains(AppShortcut.newBot.label))
        #expect(Tip.settings().contains(AppShortcut.settings.label))
        #expect(Tip.conversations().contains(AppShortcut.conversations.label))
        #expect(Tip.newConversation().contains(AppShortcut.newConversation.label))
        #expect(Tip.inspector(isShowing: true).contains(AppShortcut.toggleInspector.label))
        #expect(Tip.createOrbSheet().contains(AppShortcut.newBot.label))
        #expect(Tip.findInConversation().contains(AppShortcut.find.label))
        #expect(Tip.findNext().contains(AppShortcut.findNext.label))
        #expect(Tip.findPrevious().contains(AppShortcut.findPrevious.label))
    }

    @Test func theTipsThatFollowAStateFollowIt() {
        #expect(Tip.routineToggle(isOn: true) == "Pausa esta rotina")
        #expect(Tip.routineToggle(isOn: false) == "Ativa esta rotina")
        #expect(Tip.skillToggle(isOn: true) != Tip.skillToggle(isOn: false))
        #expect(Tip.importToggleSkill(isShowing: true) != Tip.importToggleSkill(isShowing: false))
        #expect(Tip.profile(callName: "Ana").contains("Ana"))
        #expect(Tip.profile(callName: nil) != Tip.profile(callName: "Ana"))
        #expect(Tip.useSkill(orb: "Atlas", slug: "resumir").contains("/resumir"))
        #expect(Tip.inspector(isShowing: true) != Tip.inspector(isShowing: false))
        #expect(Tip.toggleOutput(isExpanded: true) != Tip.toggleOutput(isExpanded: false))
        #expect(Tip.toggleRequest(isOpen: true) != Tip.toggleRequest(isOpen: false))
        #expect(Tip.expandMemory != Tip.collapseMemory)
        #expect(Tip.withoutFullStop("Só lê e pesquisa.") == "Só lê e pesquisa")
    }

    @Test func everyNoticeButtonAndPermissionRowActionHasATip() {
        let notices: [NoticeAction] = [.retry, .continueTurn, .openSettings, .newConversation, .compact, .openMemory, .reviewSkill]
        for action in notices {
            #expect(!action.help.isEmpty && action.help.count <= 90 && !action.help.hasSuffix("."), "\(action.help)")
        }
        // A new case has to be added here, or this fails to compile its exhaustive switch.
        for action in notices {
            switch action {
            case .retry, .continueTurn, .openSettings, .newConversation, .compact, .openMemory, .reviewSkill: break
            }
        }
        for action in [PermissionRowAction.ask, .openAppAndAsk(appName: "Notas"), .openSystemSettings] {
            #expect(Tip.permissionAction(action).count <= 90)
        }
    }

    // MARK: Icon-only buttons

    @Test func everyIconOnlyButtonHasAHoverTip() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Orb", directoryHint: .isDirectory)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found = 0
        var missing: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where Self.startsControl(line) {
                let block = Self.block(from: index, in: lines)
                guard Self.isIconOnly(block) else { continue }
                found += 1
                if !block.contains(".help(") && !block.contains(".iconTip(") {
                    missing.append("\(url.lastPathComponent):\(index + 1) \(line.trimmingCharacters(in: .whitespaces).prefix(70))")
                }
            }
        }
        #expect(found >= 15, "a varredura achou só \(found) botões de ícone: o padrão de busca quebrou?")
        #expect(missing.isEmpty, "botões só de ícone sem dica: \(missing)")
    }

    private static func startsControl(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("Button(") || text.hasPrefix("Button {") || text.hasPrefix("Menu {") || text.hasPrefix("Menu(")
    }

    /// The control and its modifiers: the lines under it that are indented more, or that continue it (`.modifier`, `}`).
    private static func block(from start: Int, in lines: [String]) -> String {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        let base = indent(lines[start])
        var block = [lines[start]]
        var next = start + 1
        while next < lines.count {
            let line = lines[next]
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            let deeper = indent(line) > base
            let continues = indent(line) == base && (text.hasPrefix(".") || text.hasPrefix("}") || text.hasPrefix(")"))
            guard deeper || continues else { break }
            block.append(line)
            next += 1
        }
        return block.joined(separator: "\n")
    }

    /// An icon and nothing to read: `.labelStyle(.iconOnly)`, or a label that is an `Image` with no `Text` or `Label` before the
    /// first modifier of the control.
    private static func isIconOnly(_ block: String) -> Bool {
        if block.contains(".labelStyle(.iconOnly)") { return true }
        var head = block
        for marker in ["\n        .buttonStyle", ".help(", ".buttonStyle(", ".menuStyle("] {
            if let range = head.range(of: marker) { head = String(head[..<range.lowerBound]) }
        }
        return head.contains("Image(systemName") && !head.contains("Text(") && !head.contains("Label(")
    }
}

/// Removing a provider sends its Orbs back to the default model (the provider's key itself is the Keychain's, not tested here).
struct RemovedProviderTests {
    @Test func theOrbsOfARemovedProviderGoBackToTheDefaultModel() {
        let openAI = Bot(name: "A", role: "", orb: OrbConfig(), model: "openai/gpt-x")
        let claude = Bot(name: "B", role: "", orb: OrbConfig(), model: "anthropic/claude-x")
        let fallback = Bot(name: "C", role: "", orb: OrbConfig())
        #expect(AppModel.bots(using: .openai, in: [openAI, claude, fallback]) == [openAI.id])
        #expect(AppModel.bots(using: .ollama, in: [openAI, claude, fallback]).isEmpty)
    }
}
