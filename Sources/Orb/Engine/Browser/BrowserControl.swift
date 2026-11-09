import Foundation
import os

/// Who drives each Orb's browser: the Orb, or the person who took it over in the live screen's window (docs/TELA-AO-VIVO.md, 7).
/// While the person has it, every browser tool of the Orb waits at its entrance (`BrowseSupport.session`), so the two never
/// click on the same page at once; the action already running finishes first. When the person hands it back, the tools that
/// waited do not act on refs of a page that may have changed: they tell the model to look again (`handedBack`).
final class BrowserControl: Sendable {
    /// What a tool that waited answers the model.
    static let handedBack = "The person took over your browser and has handed it back. The page may have changed: take a new browse_snapshot before acting."
    /// What a run nobody watches (a routine, the pulse) is told instead of waiting: the person may keep the browser for an hour.
    static let inUseByPerson = "The person is using your browser right now, and this run does not wait for it. Skip the web step and say so in your report."

    /// Whether a tool must not wait for the browser: the person has it and nobody watches this run, which would hang for as long as
    /// they browse.
    func refusesRun(_ botID: UUID, unattended: Bool) -> Bool { unattended && isHeld(botID) }

    private struct State {
        var held: Set<UUID> = []
        /// Orbs whose browser was handed back and no tool has noticed yet.
        var handedBack: Set<UUID> = []
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
            if state.held.remove(botID) != nil { state.handedBack.insert(botID) }
            return state.waiters.removeValue(forKey: botID).map { Array($0.values) } ?? []
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Whether the person took the browser and gave it back since a tool last asked; asking clears it. Covers the case where no tool
    /// was waiting while they had it: the page can have changed all the same.
    func consumeHandBack(_ botID: UUID) -> Bool { state.withLock { $0.handedBack.remove(botID) != nil } }

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
