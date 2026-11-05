import Foundation
import os

/// Who drives each Orb's browser: the Orb, or the person who took it over in the live screen's window (docs/TELA-AO-VIVO.md, 7).
/// While the person has it, every browser tool of the Orb waits at its entrance (`BrowseSupport.session`), so the two never
/// click on the same page at once; the action already running finishes first. When the person hands it back, the tools that
/// waited do not act on refs of a page that may have changed: they tell the model to look again (`handedBack`).
final class BrowserControl: Sendable {
    /// What a tool that waited answers the model.
    static let handedBack = "The person took over your browser and has handed it back. The page may have changed: take a new browse_snapshot before acting."

    private struct State {
        var held: Set<UUID> = []
        var waiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func isHeld(_ botID: UUID) -> Bool { state.withLock { $0.held.contains(botID) } }

    /// How many tools of this Orb wait for the browser now.
    func waitingCount(_ botID: UUID) -> Int { state.withLock { $0.waiters[botID]?.count ?? 0 } }

    /// The person took this Orb's browser.
    func take(_ botID: UUID) {
        state.withLock { _ = $0.held.insert(botID) }
    }

    /// The person handed it back (or closed the window): every tool waiting for it goes on.
    func giveBack(_ botID: UUID) {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held.remove(botID)
            return state.waiters.removeValue(forKey: botID).map { Array($0.values) } ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Waits while the person has this Orb's browser; true when it waited. Cancelling the task (Parar) ends the wait at once.
    func waitWhileHeld(_ botID: UUID) async -> Bool {
        guard isHeld(botID) else { return false }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Handed back, or cancelled, between the check above and here: nothing to wait for.
                let goesOn = state.withLock { state -> Bool in
                    guard state.held.contains(botID), !Task.isCancelled else { return true }
                    state.waiters[botID, default: [:]][id] = continuation
                    return false
                }
                if goesOn { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { $0.waiters[botID]?.removeValue(forKey: id) }
            continuation?.resume()
        }
        return true
    }
}
