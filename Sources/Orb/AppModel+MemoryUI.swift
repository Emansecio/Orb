import Foundation
import SwiftUI
import Observation

/// A memory page as it was just before the user chose "Esquecer": its file and, if the page had been compacted,
/// the archived full text. Holding the text for a few seconds is what lets "Desfazer" put it back.
struct ForgottenMemory: Equatable, Sendable {
    var path: String
    var title: String
    var text: String
    var archivedText: String?
    /// The page's earlier versions (`MemoryBank.versionsFolder`), by file name.
    var versions: [String: String] = [:]

    static func isForgettable(_ path: String) -> Bool { MemoryBank.isForgettable(path) }

    /// Reads the page (and its archive and versions) from the Orb's memory folder; nil when it is not there or not forgettable.
    static func capture(_ path: String, title: String, in directory: URL) -> ForgottenMemory? {
        guard isForgettable(path),
              let text = try? String(contentsOf: directory.appending(path: path), encoding: .utf8) else { return nil }
        let archived = try? String(contentsOf: directory.appending(path: "_arquivo/" + path), encoding: .utf8)
        let folder = directory.appending(path: MemoryBank.versionsFolder(of: path))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let versions = Dictionary(uniqueKeysWithValues: names.compactMap { name in
            (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)).map { (name, $0) }
        })
        return ForgottenMemory(path: path, title: title, text: text, archivedText: archived, versions: versions)
    }

    /// Writes the page back, unless something already sits at its path. Returns whether it did.
    @discardableResult
    func restore(in directory: URL) -> Bool {
        guard Self.isForgettable(path) else { return false }
        let url = directory.appending(path: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            if let archivedText {
                let archive = directory.appending(path: "_arquivo/" + path)
                try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(archivedText.utf8).write(to: archive, options: .atomic)
            }
            let folder = directory.appending(path: MemoryBank.versionsFolder(of: path))
            for (name, text) in versions {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }
}

extension AppModel {
    /// Forgets a memory page and hands back what is needed to bring it back. The panel shows "Desfazer" for a few
    /// seconds with it; nothing else is kept. Nil, with a notice, when the page could not be read first (there would be
    /// no way back) or its file stayed.
    func forgetMemoryUndoably(_ item: MemorySnapshot.Item, of botID: UUID) async -> ForgottenMemory? {
        let bank = memory.bank(for: botID)
        let directory = bank.directory
        let path = item.path, title = item.title
        let forgotten = await Task.detached { ForgottenMemory.capture(path, title: title, in: directory) }.value
        guard let forgotten, await bank.forget(path) else {
            addNotice(StoreNotice(message: Self.couldNotForget(title)))
            await refreshMemory(botID)
            return nil
        }
        await refreshMemory(botID)
        return forgotten
    }

    static func couldNotForget(_ title: String) -> String {
        "Não consegui esquecer “\(MemoryText.clip(title, 60))”: o arquivo continua na memória (confira as permissões da pasta)."
    }

    /// Puts a forgotten page back (the index picks the file up again) and refreshes the panel.
    func restoreMemory(_ forgotten: ForgottenMemory, of botID: UUID) async {
        guard bot(botID) != nil else { return } // the Orb was deleted meanwhile: its memory folder may be gone
        await restoreForgotten(forgotten, in: memory.bank(for: botID))
        await refreshMemory(botID)
    }

    /// The write-back of a forgotten page, off the main thread, and the index picking it up. When the page cannot go back
    /// (something sits at its path, or the folder does not take it), the chat of notices says so instead of the undo doing nothing.
    func restoreForgotten(_ forgotten: ForgottenMemory, in bank: MemoryBank) async {
        let directory = bank.directory
        let restored = await Task.detached { forgotten.restore(in: directory) }.value
        await bank.reconcile()
        if !restored { addNotice(StoreNotice(message: Self.couldNotRestore(forgotten.title))) }
    }

    static func couldNotRestore(_ title: String) -> String {
        "Não consegui desfazer: “\(MemoryText.clip(title, 60))” não voltou para a memória (já existe uma página nesse lugar ou a pasta não aceitou)."
    }
}

/// The "Esqueceu isso. Desfazer" toast of the memory screens: one pending undo at a time, gone after a few seconds.
/// The countdown waits while the pointer or the keyboard focus is on the toast.
@MainActor
@Observable
final class MemoryUndo {
    struct Entry: Equatable {
        var botID: UUID
        var forgotten: ForgottenMemory
    }

    /// What can hold the toast open.
    enum Hold: Hashable { case hover, focus }

    static let lifetime: Duration = .seconds(10)

    private(set) var entry: Entry?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var holds: Set<Hold> = []
    @ObservationIgnored private let lifetime: Duration

    init(lifetime: Duration = MemoryUndo.lifetime) { self.lifetime = lifetime }

    func forget(_ item: MemorySnapshot.Item, of botID: UUID, in model: AppModel) {
        Task {
            guard let forgotten = await model.forgetMemoryUndoably(item, of: botID) else { return }
            show(Entry(botID: botID, forgotten: forgotten))
            // Nothing on screen tells VoiceOver that the row went away or that there is a way back.
            let name = model.liveBot(botID)?.look.name ?? "O Orb"
            AccessibilityNotification.Announcement("\(name) esqueceu isso. Para desfazer, ⌘Z.").post()
        }
    }

    func show(_ entry: Entry) {
        self.entry = entry
        startCountdown()
    }

    /// Pauses the countdown while `reason` holds (the pointer over the toast, focus on its button); it starts again
    /// from the full time when the last hold ends.
    func hold(_ reason: Hold, _ isHeld: Bool) {
        if isHeld { holds.insert(reason) } else { holds.remove(reason) }
        if holds.isEmpty { if entry != nil { startCountdown() } } else { expiry?.cancel(); expiry = nil }
    }

    /// The toast that held the countdown left the screen (its sheet closed under the pointer, or its button lost focus
    /// with it) without saying the hold ended: let go, so it does not wait for a pointer that is gone.
    func releaseHolds() {
        guard !holds.isEmpty else { return }
        holds = []
        if entry != nil { startCountdown() }
    }

    func undo(in model: AppModel) {
        guard let entry else { return }
        dismiss()
        Task { await model.restoreMemory(entry.forgotten, of: entry.botID) }
    }

    func dismiss() {
        expiry?.cancel()
        expiry = nil
        holds = []
        entry = nil
    }

    private func startCountdown() {
        expiry?.cancel()
        guard holds.isEmpty else { expiry = nil; return }
        expiry = Task { [weak self, lifetime] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}
