import SwiftUI

// The names and the keys of the app's commands, written once. The menus (`AppCommands`), the command palette, the
// sidebar's context menu, the "Atalhos do teclado" sheet and the tests all read them, so the same command is never
// called two things and two commands never share a key.

/// What each command is called wherever it appears.
enum CommandName {
    static let newBot = "Novo Orb…"
    static let goTo = "Ir para…"
    static let newConversation = "Nova conversa"
    static let writeMessage = "Escrever uma mensagem"
    static let conversations = "Conversas anteriores"
    static let stop = "Parar a resposta"
    static let openFolder = "Abrir pasta do Orb no Finder"
    static let toggleInspector = "Mostrar ou ocultar o painel do Orb"
    static let shortcuts = "Atalhos do teclado"
    static let previousBot = "Orb anterior"
    static let nextBot = "Próximo Orb"
    static let routines = "Rotinas"
    static let connectors = "Conectores"
    static let skills = "Skills"
    static let globalShortcut = "Abrir o painel da barra de menus com ⌃⌥Espaço"
    /// Shift-Return sends in a multi-line field on macOS; Option-Return is what breaks the line.
    static let newLineKeys = "⌥↩"
}

/// The keys the menus declare.
enum AppShortcut {
    static let newBot = KeyboardShortcut("n")
    static let newConversation = KeyboardShortcut("n", modifiers: [.command, .shift])
    static let toggleInspector = KeyboardShortcut("b", modifiers: [.command, .option])
    static let goTo = KeyboardShortcut("k")
    static let writeMessage = KeyboardShortcut("l")
    static let conversations = KeyboardShortcut("y")
    static let stop = KeyboardShortcut(".")
    static let openFolder = KeyboardShortcut("o", modifiers: [.command, .shift])
    static let previousBot = KeyboardShortcut(.upArrow, modifiers: .option)
    static let nextBot = KeyboardShortcut(.downArrow, modifiers: .option)
    static let routines = KeyboardShortcut("r", modifiers: [.command, .option])
    static let connectors = KeyboardShortcut("c", modifiers: [.command, .option])
    static let skills = KeyboardShortcut("k", modifiers: [.command, .option])

    /// ⌘1…⌘9: the Orb at that place in the sidebar.
    static func bot(at index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    /// Every key above, for the tests that check that none is used twice.
    static let all: [KeyboardShortcut] = [newBot, newConversation, toggleInspector, goTo, writeMessage, conversations, stop,
                                          openFolder, previousBot, nextBot, routines, connectors, skills]
        + (0..<9).map(bot(at:))
}

extension KeyboardShortcut {
    /// "⌥⌘B", "⇧⌘N", "⌥↑": the way the menus write it (⌃ ⌥ ⇧ ⌘, then the key).
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .return: text += "↩"
        case .space: text += "Espaço"
        case .escape: text += "esc"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}
