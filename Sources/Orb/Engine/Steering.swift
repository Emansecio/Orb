import Foundation
import os

/// Where a message sent during a turn goes: into the task in progress, or after it.
enum SteeringDelivery: String, Codable, Sendable {
    /// Handed to the model at its next step boundary, so the task changes course without being thrown away.
    case steer
    /// Waits for the task to end and then goes as the next request.
    case afterTask

    init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .steer) }

    var other: SteeringDelivery { self == .steer ? .afterTask : .steer }
}

/// A message the user sent while the Orb was still working on the previous one.
///
/// It waits in a `SteeringQueue` until the engine reaches a step boundary (the model has just seen its tools'
/// results and is about to be called again), and is handed to the model there as one more user message, so
/// "não, use a pasta X" changes course without throwing the work away. One sent with `.afterTask` stays in the
/// queue instead, until the turn ends.
struct SteeredMessage: Identifiable, Equatable, Sendable, Codable {
    var id = UUID()
    /// What the user typed; the transcript shows this once the message is delivered.
    var text: String
    /// Files attached to it (the model is told their paths) and pictures (shrunk and saved already).
    var files: [URL] = []
    var pictures: [ImageAttachment] = []
    /// What the model is sent: `text` with the attachment notes (and a skill's instructions when it starts with
    /// `/skill`). Built when the message is queued, for the engines that deliver it mid-turn.
    var prompt: String
    /// Into the running task, or after it. The default is the composer's ↩.
    var delivery = SteeringDelivery.steer

    /// What the transcript bubble lists: files by path, then pictures.
    var attachmentPaths: [String] { files.map(\.path) + pictures.map(\.path) }
}

extension SteeredMessage {
    private enum CodingKeys: String, CodingKey { case id, text, files, pictures, prompt, delivery }

    /// Tolerant: a message saved before the delivery mode existed is a `.steer` one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        text = try c.value(.text, default: "")
        files = try c.value(.files, default: [])
        pictures = try c.lossyArray(.pictures)
        prompt = try c.value(.prompt, default: "")
        delivery = try c.value(.delivery, default: .steer)
    }
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
    /// Something is waiting for the next step boundary (messages for after the task do not count).
    var hasSteering: Bool { pending.withLock { $0.contains { $0.delivery == .steer } } }
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

    /// The messages for the running task only, oldest first; those for after it stay. One lock hold, so a message
    /// whose mode is being changed is either taken whole or left whole.
    func drainSteering() -> [SteeredMessage] {
        pending.withLock { messages in
            let taken = messages.filter { $0.delivery == .steer }
            messages.removeAll { $0.delivery == .steer }
            return taken
        }
    }

    /// Changes where one message goes. False when it is not waiting anymore (already delivered or taken back).
    func setDelivery(_ id: UUID, to delivery: SteeringDelivery) -> Bool {
        pending.withLock { messages in
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
            messages[index].delivery = delivery
            return true
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
