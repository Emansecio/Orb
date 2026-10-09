import SwiftUI
import AppKit

// What the menu commands, the command palette, the sidebar's context menu and the menu bar icon ask of the app.
// Kept apart from AppModel.swift: small helpers that only use what the model already exposes.

/// What a command asks of an Orb's chat: the cursor in the composer (⌘L), the list of earlier conversations (⌘Y,
/// the sidebar's menu) or the appearance editor (the sidebar's "Personalizar…").
///
/// It is a request waiting in the model, not a notification: the chat of an Orb that was not open does not exist yet
/// when the command runs, so a notification would be sent before anyone listens. The chat takes it in `onAppear` (it
/// has just been created) and in `onChange` (it was already open).
struct PendingChatRequest: Equatable {
    enum Kind: Equatable { case focusComposer, showConversations, editLook, showTab(InspectorTab) }
    let kind: Kind
    let botID: UUID
}

/// "Memória de Atlas guardada · Mostrar no Finder": what the sidebar says for a few seconds after an Orb was
/// deleted with its memory kept. It says "Guardando…" until the memory has moved (the last stretch of a long
/// conversation is written first), and then points at the folder it went to.
struct KeptMemoryNotice: Identifiable, Equatable {
    let id = UUID()
    let botName: String
    let date: Date
    /// False while the memory is still being moved.
    var isKept = false
    /// Where it went; nil while it is being moved, or if that did not work out.
    var folder: URL?
    var message: String { isKept ? "Memória de \(botName) guardada" : "Guardando a memória de \(botName)…" }
}

/// What the menu bar icon says: nothing going on, an Orb working, or Orbs waiting for a permission.
enum MenuBarState: Equatable {
    case idle
    case working(Int)
    case waiting(Int)

    /// A question outranks work: the icon must call you when an Orb is stopped on one.
    static func resolve(waiting: Int, working: Int) -> MenuBarState {
        if waiting > 0 { return .waiting(waiting) }
        if working > 0 { return .working(working) }
        return .idle
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Orb"
        case .working(let count): count == 1 ? "Orb: 1 Orb trabalhando" : "Orb: \(count) Orbs trabalhando"
        case .waiting(let count): count == 1 ? "Orb: 1 Orb precisa da sua permissão" : "Orb: \(count) Orbs precisam da sua permissão"
        }
    }

    var hasBadge: Bool {
        if case .waiting = self { true } else { false }
    }
}

extension AppModel {
    /// The open Orb's id. Reads the selection only, so a menu that asks for it is not rebuilt when any Orb changes
    /// (`selectedBot` reads the whole list of Orbs).
    var selectedBotID: UUID? {
        if case .bot(let id) = selection { id } else { nil }
    }

    /// The Orb the commands act on: the open one, or the first when a workspace page is open.
    var commandBotID: UUID? { selectedBotID ?? botIDs.first }

    /// Sheets of the editors (identity, memory, routine, skill, connector, appearance…) that are open.
    var openSheets: Int { openSheetTokens.count }

    func sheetDidOpen(_ token: UUID) { openSheetTokens.insert(token) }
    func sheetDidClose(_ token: UUID) { openSheetTokens.remove(token) }

    /// A sheet of the app is open: the commands that would open another one, or swap the screen behind it (and take
    /// the sheet's draft along), wait.
    var hasOpenSheet: Bool {
        showNewBot || showCommandPalette || showShortcuts || deletingBotID != nil || openSheets > 0
    }

    /// Opens the Orb's chat (a command on the routines page, or on another Orb, still has to land somewhere) and
    /// leaves the request for it.
    func request(_ kind: PendingChatRequest.Kind, of botID: UUID) {
        if selectedBotID != botID { selection = .bot(botID) }
        pendingChatRequest = PendingChatRequest(kind: kind, botID: botID)
    }

    /// The chat of `botID` takes the request, if that is what is waiting. True once.
    func takeChatRequest(_ kind: PendingChatRequest.Kind, of botID: UUID) -> Bool {
        guard pendingChatRequest == PendingChatRequest(kind: kind, botID: botID) else { return false }
        pendingChatRequest = nil
        return true
    }

    /// The panel of `botID` takes a request to open on a tab, if one is waiting.
    func takeTabRequest(of botID: UUID) -> InspectorTab? {
        InspectorTab.allCases.first { takeChatRequest(.showTab($0), of: botID) }
    }

    /// "Gerenciar" in the permissions chip: the panel opens on "Pasta e acessos", where the grants (Liberações) are.
    func showPermissions(of botID: UUID) {
        setInspector(true)
        request(.showTab(.folder), of: botID)
    }

    /// ⌘L: the cursor goes to the composer, from the sidebar, the panel or another page.
    func focusComposer() {
        if let id = commandBotID { request(.focusComposer, of: id) }
    }

    /// ⌘Y: the list of earlier conversations of the open Orb (or of the given one, from the sidebar's menu).
    func showConversations(of botID: UUID? = nil) {
        if let id = botID ?? commandBotID { request(.showConversations, of: id) }
    }

    /// ⌘.: stops the open Orb's answer.
    func stopCurrent() {
        if let id = selectedBotID, isWorking(id) { stop(id) }
    }

    var canStopCurrent: Bool { selectedBotID.map { isWorking($0) } ?? false }

    /// ⇧⌘O: the Orb's folder in the Finder.
    func openFolder(of botID: UUID) {
        guard let bot = bot(botID) else { return }
        OrbFolder.showInFinder(bot.workingURL)
    }

    /// Opens the Orb with its panel and the appearance editor on top.
    func showLookEditor(of botID: UUID) {
        setInspector(true)
        request(.editLook, of: botID)
    }

    /// Orb number `index` (0-based) in the sidebar's order, as ⌘1…⌘9 pick it.
    func botID(atShortcut index: Int) -> UUID? {
        botIDs.indices.contains(index) ? botIDs[index] : nil
    }

    // MARK: Deleting an Orb

    /// Asks to delete the Orb (the sheet in `SystemSheets`).
    func askToDelete(_ botID: UUID) { deletingBotID = botID }

    /// Deletes the Orb the sheet is about. With the memory kept, the sidebar says where it went.
    func confirmDelete(_ botID: UUID, keepMemory: Bool) {
        let name = bot(botID)?.name ?? "Orb"
        // Only an Orb with something to keep has a folder to point at (one that never remembered anything and has
        // not talked has none, and "guardada" would be a lie).
        let hasMemory = FileManager.default.fileExists(atPath: memory.directory(for: botID).path)
            || !(sessions[botID]?.conversation?.items.isEmpty ?? true)
        deletingBotID = nil
        let keeping = deleteBot(botID, keepMemory: keepMemory)
        guard let keeping, hasMemory else {
            keptMemoryNotice = nil
            return
        }
        let notice = KeptMemoryNotice(botName: name, date: .now)
        keptMemoryNotice = notice
        Task {
            let folder = await keeping.value
            guard keptMemoryNotice?.id == notice.id else { return } // closed, or another Orb was deleted meanwhile
            keptMemoryNotice?.folder = folder
            keptMemoryNotice?.isKept = true
        }
    }

    func dismissKeptMemoryNotice() { keptMemoryNotice = nil }

    /// Shows the memory the notice is about: the folder it went to, or, when that is not known, what
    /// `revealKeptMemory(named:)` can find.
    func revealKeptMemory(_ notice: KeptMemoryNotice) {
        guard let folder = notice.folder else { return revealKeptMemory(named: notice.botName) }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Shows the memory kept for `name` in the Finder: its own folder when it can be found (the newest one with
    /// that name), otherwise the folder of kept memories.
    func revealKeptMemory(named name: String) {
        let kept = KeptMemories.folder(in: memory.root)
        let match = Self.newestKeptFolder(named: name, in: kept)
        if let match {
            NSWorkspace.shared.activateFileViewerSelecting([match])
        } else if FileManager.default.fileExists(atPath: kept.path) {
            NSWorkspace.shared.open(kept)
        } else {
            NSWorkspace.shared.open(memory.root)
        }
    }

    /// The folder `MemoryLibrary.keep` made for an Orb called `name` (`<name> – <date>`), newest first.
    nonisolated static func newestKeptFolder(named name: String, in directory: URL) -> URL? {
        let prefix = KeptMemories.namePrefix(for: name)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.max().map { directory.appending(path: $0) }
    }

    // MARK: Menu bar

    /// The icon's state. Reads only the lists of working and waiting Orbs, which change when an Orb starts or stops
    /// working, not with every status line.
    var menuBarState: MenuBarState {
        MenuBarState.resolve(waiting: waitingIDs.count, working: workingIDs.count)
    }
}
