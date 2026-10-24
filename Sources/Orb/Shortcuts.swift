import SwiftUI

// The names and the keys of the app's commands, written once. The menus (`AppCommands`), the command palette, the
// sidebar's context menu, the views that declare a key of their own, the "Atalhos do teclado" sheet, Ajustes → Geral and
// the tests all read them, so the same command is never called two things and two commands never share a key.
//
// `AppShortcut` holds the keys, `ShortcutCatalog` is the one list of what each key does: the sheet and Ajustes draw it
// whole, and the palette reads the key of each of its actions from it (`ShortcutCatalog.keys(for:)`). A new shortcut
// goes into the catalog, and the tests fail if a key is declared anywhere without being listed.

/// What each command is called wherever it appears.
enum CommandName {
    static let newBot = "Novo Orb…"
    static let newChat = "Nova conversa"
    static let quit = "Encerrar Orb"
    static let newGroup = "Novo grupo…"
    static let newCategory = "Nova categoria…"
    static let importOrb = "Importar de outro assistente…"
    static let goTo = "Ir para…"
    static let writeMessage = "Escrever uma mensagem"
    static let findInConversation = "Buscar na conversa"
    static let stop = "Parar a resposta"
    static let sendToBackground = "Mandar o comando para segundo plano"
    static let openFolder = "Abrir pasta do Orb no Finder"
    static let toggleInspector = "Mostrar ou ocultar o painel do Orb"
    static let shortcuts = "Atalhos do teclado"
    static let previousBot = "Orb anterior"
    static let nextBot = "Próximo Orb"
    static let routines = "Rotinas"
    static let connectors = "Conectores"
    static let skills = "Skills"
    static let globalShortcut = "Abrir o painel da barra de menus com ⌃⌥Espaço"
    /// ⇧↩ breaks the line in the app's message fields (the field itself only knows ⌥↩; `NewLineKey` in ComposerView makes
    /// ⇧↩ do the same instead of sending).
    static let newLineKeys = "⇧↩"
}

/// The keys the menus declare.
enum AppShortcut {
    static let newBot = KeyboardShortcut("n")
    /// ⇧⌘N: a new conversation of the Orb on show (`AppModel.newChat`).
    static let newChat = KeyboardShortcut("n", modifiers: [.command, .shift])
    /// ⌥⌘G: a new group of Orbs (sheet "Novo grupo").
    static let newGroup = KeyboardShortcut("g", modifiers: [.command, .option])
    static let toggleInspector = KeyboardShortcut("b", modifiers: [.command, .option])
    static let goTo = KeyboardShortcut("k")
    static let writeMessage = KeyboardShortcut("l")
    static let stop = KeyboardShortcut(".")
    /// ⌘B: the command the Orb waits for goes on in the background (the "Segundo plano" button of the working line).
    static let sendToBackground = KeyboardShortcut("b")
    static let openFolder = KeyboardShortcut("o", modifiers: [.command, .shift])
    static let previousBot = KeyboardShortcut(.upArrow, modifiers: .option)
    static let nextBot = KeyboardShortcut(.downArrow, modifiers: .option)
    static let routines = KeyboardShortcut("r", modifiers: [.command, .option])
    static let connectors = KeyboardShortcut("c", modifiers: [.command, .option])
    static let skills = KeyboardShortcut("k", modifiers: [.command, .option])
    /// ⌘/: the "Atalhos do teclado" sheet (the Ajuda menu's item).
    static let shortcuts = KeyboardShortcut("/")

    /// ⌘1…⌘9: the Orb at that place in the sidebar.
    static func bot(at index: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
    }

    // Keys that belong to a view, not to the menus (the menu bar would show them greyed out or steal them from a field).

    /// ⌘↩ in the composer while the Orb works: stop and send what is written now. (The same key allows an approval card,
    /// compacts in the context panel and saves the Orb's instructions: each only exists while its view is on screen.)
    static let commandReturn = KeyboardShortcut(.return, modifiers: .command)
    static let chooseModel = KeyboardShortcut("m", modifiers: [.command, .shift])
    /// ⌘Z while the "esqueceu isso" toast is up (a field with something to undo keeps its own).
    static let undoForget = KeyboardShortcut("z", modifiers: .command)
    /// ⌘F in a chat (the find bar) and in Skills and Conectores (the catalog's search).
    static let find = KeyboardShortcut("f", modifiers: .command)
    /// ⌘G and ⇧⌘G while the find bar of a chat is open: the next and the previous result.
    static let findNext = KeyboardShortcut("g", modifiers: .command)
    static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
    /// ⌘, is the system's own Ajustes item; listed here so it is written like the others.
    static let settings = KeyboardShortcut(",")

    /// The keys of views and of the system's Ajustes item, which `all` (the menus' keys) leaves out because they may
    /// share a key with a command of another view or with the system.
    static let contextual: [KeyboardShortcut] = [commandReturn, chooseModel, undoForget, find, findNext, findPrevious, settings]

    /// Every key above, for the tests that check that none is used twice.
    static let all: [KeyboardShortcut] = [newBot, newChat, newGroup, toggleInspector, goTo, writeMessage, stop, sendToBackground,
                                          openFolder, previousBot, nextBot, routines, connectors, skills, shortcuts]
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

// MARK: - The catalog

/// A command a key answers to, so the places that show a key (the palette) ask the catalog for it by command.
enum ShortcutCommand: String, CaseIterable, Sendable {
    case newBot, newGroup, goTo, toggleInspector, settings, shortcuts
    case newChat, writeMessage, stop, sendToBackground, openFolder, send, newLine, queueAfterTask, stopAndSend, chooseModel, cancelEdit
    case goToBot, previousBot, nextBot, routines, connectors, skills
    case allowApproval, denyApproval
    case compactOrSave, undoForget, find, findNext, findPrevious
    case menuBarPanel
}

struct ShortcutItem: Identifiable, Equatable {
    var command: ShortcutCommand
    var keys: String
    var title: String
    /// The title when it is drawn inside Ajustes → Geral itself, for a title that would otherwise point at the screen
    /// the person is already on.
    var titleInGeneral: String? = nil
    var id: String { command.rawValue }
}

extension ShortcutItem {
    init(_ command: ShortcutCommand, _ shortcut: KeyboardShortcut, _ title: String) { self.init(command: command, keys: shortcut.label, title: title) }

    /// A title as the lists draw it: what the key does, and the condition in parentheses at its end as a gray line under
    /// it ("Parar e enviar agora" over "Orb trabalhando e algo escrito…"), not one long line. The catalog keeps one string.
    static func lines(_ title: String) -> (main: String, note: String?) {
        guard title.hasSuffix(")"), let open = title.range(of: " (") else { return (title, nil) }
        let note = title[open.upperBound...].dropLast()
        guard !note.isEmpty else { return (title, nil) }
        return (String(title[..<open.lowerBound]), note.prefix(1).uppercased() + note.dropFirst())
    }
}

struct ShortcutGroup: Identifiable, Equatable {
    var title: String
    var items: [ShortcutItem]
    var id: String { title }
}

/// Every shortcut the app answers, in one place: the "Atalhos do teclado" sheet and Ajustes → Geral draw it, the palette
/// takes the keys of its actions from it, and the tests check that it lists every key the app declares and that no
/// two actions of one group share a key. (⌘↩ and esc are the keys several views answer to, each only while it is on
/// screen: they appear once per place, never twice in one group.)
enum ShortcutCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Geral", items: [
            ShortcutItem(.newBot, AppShortcut.newBot, CommandName.newBot),
            ShortcutItem(.newGroup, AppShortcut.newGroup, CommandName.newGroup),
            ShortcutItem(.goTo, AppShortcut.goTo, "Ir para… (Orbs, páginas e ações)"),
            ShortcutItem(.toggleInspector, AppShortcut.toggleInspector, CommandName.toggleInspector),
            ShortcutItem(.settings, AppShortcut.settings, "Ajustes"),
            ShortcutItem(.shortcuts, AppShortcut.shortcuts, CommandName.shortcuts),
        ]),
        ShortcutGroup(title: "Conversa", items: [
            ShortcutItem(.newChat, AppShortcut.newChat, CommandName.newChat + " com o Orb aberto"),
            ShortcutItem(.writeMessage, AppShortcut.writeMessage, CommandName.writeMessage),
            ShortcutItem(.stop, AppShortcut.stop, CommandName.stop),
            ShortcutItem(.sendToBackground, AppShortcut.sendToBackground, CommandName.sendToBackground + " (enquanto o Orb espera um comando do Terminal)"),
            ShortcutItem(.openFolder, AppShortcut.openFolder, CommandName.openFolder),
            ShortcutItem(command: .send, keys: "↩", title: "Enviar a mensagem (com o Orb trabalhando, direciona a tarefa)"),
            ShortcutItem(command: .queueAfterTask, keys: "⇥", title: "Pôr na fila para depois da tarefa (Orb trabalhando e algo escrito)"),
            ShortcutItem(command: .newLine, keys: CommandName.newLineKeys, title: "Nova linha na mensagem"),
            ShortcutItem(.stopAndSend, AppShortcut.commandReturn, "Parar e enviar agora (Orb trabalhando e algo escrito, fora da edição de uma mensagem e sem pedido aberto)"),
            ShortcutItem(.chooseModel, AppShortcut.chooseModel, "Escolher o modelo do Orb"),
            ShortcutItem(command: .cancelEdit, keys: "esc", title: "Cancelar a edição de uma mensagem (com o cursor no campo; a lista de skills aberta fecha primeiro; o campo volta como estava)"),
            ShortcutItem(.find, AppShortcut.find, CommandName.findInConversation + " (em Skills e Conectores, busca no catálogo)"),
            ShortcutItem(.findNext, AppShortcut.findNext, "Próximo resultado da busca na conversa (também ↩ e ↓ no campo de busca; esc fecha)"),
            ShortcutItem(.findPrevious, AppShortcut.findPrevious, "Resultado anterior da busca na conversa (também ⇧↩ e ↑ no campo de busca)"),
        ]),
        ShortcutGroup(title: "Navegar", items: [
            ShortcutItem(command: .goToBot, keys: "\(AppShortcut.bot(at: 0).label) – \(AppShortcut.bot(at: 8).label)", title: "Ir para o Orb de mesmo número"),
            ShortcutItem(.previousBot, AppShortcut.previousBot, CommandName.previousBot),
            ShortcutItem(.nextBot, AppShortcut.nextBot, CommandName.nextBot),
            ShortcutItem(.routines, AppShortcut.routines, CommandName.routines),
            ShortcutItem(.connectors, AppShortcut.connectors, CommandName.connectors),
            ShortcutItem(.skills, AppShortcut.skills, CommandName.skills),
        ]),
        ShortcutGroup(title: "Pedidos de permissão", items: [
            ShortcutItem(command: .allowApproval, keys: AppShortcut.commandReturn.label, title: "Permitir (pedido aberto e campo de mensagem vazio)"),
            ShortcutItem(command: .denyApproval, keys: "esc", title: "Não permitir (com o campo de mensagem vazio)"),
        ]),
        ShortcutGroup(title: "Em painéis e avisos", items: [
            ShortcutItem(command: .compactOrSave, keys: AppShortcut.commandReturn.label, title: "Compactar agora (painel de contexto) ou salvar (editor “Como o Orb funciona”)"),
            ShortcutItem(.undoForget, AppShortcut.undoForget, "Desfazer “Esquecer” da memória (enquanto o aviso está na tela)"),
        ]),
        ShortcutGroup(title: "De qualquer lugar do Mac", items: [
            ShortcutItem(command: .menuBarPanel, keys: "⌃⌥Espaço", title: "Abrir o painel da barra de menus do Orb (opcional, em Ajustes → Geral)",
                         titleInGeneral: "Abrir o painel da barra de menus do Orb (opcional, ligue na seção acima)"),
        ]),
    ]

    static var items: [ShortcutItem] { groups.flatMap(\.items) }

    /// The keys of a command, as the catalog writes them.
    static func keys(for command: ShortcutCommand) -> String {
        items.first { $0.command == command }?.keys ?? ""
    }
}
