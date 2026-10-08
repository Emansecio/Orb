import Foundation
import os

/// A message the user sent while the Orb was still working on the previous one.
///
/// It waits in a `SteeringQueue` until the engine reaches a step boundary (the model has just seen its tools'
/// results and is about to be called again), and is handed to the model there as one more user message, so
/// "não, use a pasta X" changes course without throwing the work away.
struct SteeredMessage: Identifiable, Equatable, Sendable {
    var id = UUID()
    /// What the user typed; the transcript shows this once the message is delivered.
    var text: String
    /// Files attached to it (the model is told their paths) and pictures (shrunk and saved already).
    var files: [URL] = []
    var pictures: [ImageAttachment] = []
    /// What the model is sent: `text` with the attachment notes (and a skill's instructions when it starts with
    /// `/skill`). Built when the message is queued, for the engines that deliver it mid-turn.
    var prompt: String

    /// What the transcript bubble lists: files by path, then pictures.
    var attachmentPaths: [String] { files.map(\.path) + pictures.map(\.path) }
}

/// The messages waiting to be delivered to one Orb's running turn.
///
/// A small lock-protected box shared by the app (which adds to it and takes from it when the user changes their
/// mind) and the engine (which drains it between steps), because they live on different executors. Delivery order
/// is the order of sending.
final class SteeringQueue: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [SteeredMessage]())

    init() {}

    var isEmpty: Bool { pending.withLock { $0.isEmpty } }
    var messages: [SteeredMessage] { pending.withLock { $0 } }

    func push(_ message: SteeredMessage) {
        pending.withLock { $0.append(message) }
    }

    /// Everything waiting, oldest first; the queue is empty afterwards.
    func drain() -> [SteeredMessage] {
        pending.withLock { messages in
            defer { messages.removeAll() }
            return messages
        }
    }

    /// Takes one message back out (the user removed it). nil when it was already delivered.
    func remove(_ id: UUID) -> SteeredMessage? {
        pending.withLock { messages in
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
            return messages.remove(at: index)
        }
    }
}
