import Foundation
import os

/// A piece of work that took longer than it was given (`withDeadline`). `what` names it for the model: "a captura da janela".
struct DeadlineExceeded: LocalizedError, Equatable {
    var seconds: TimeInterval
    var what: String

    var errorDescription: String? { "\(what.prefix(1).uppercased() + what.dropFirst()) passou de \(Int(seconds)) s e foi abandonada." }
}

/// Runs `operation` and gives up on it after `seconds`, or as soon as the calling task is cancelled (⌘.), even when the
/// operation itself ignores cancellation (a system framework that never answers): it is cancelled and left behind, and the
/// caller goes on. A task group would wait for it, which is the hang this is for. `seconds` nil: no time limit, only the
/// cancellation (`cancellably`).
func withDeadline<T: Sendable>(_ seconds: TimeInterval?, _ what: String,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, work: Task { race.finish(await Result { try await operation() }) }, timer: Task {
                guard let seconds else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { race.finish(.failure(DeadlineExceeded(seconds: seconds, what: what))) }
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// `operation`, given up on as soon as the calling task is cancelled: for waiting on work shared with others (an
/// unstructured task's `value` does not end when the one waiting is cancelled).
func cancellably<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withDeadline(nil, "", operation)
}

/// The first of the work, the timer and a cancellation to finish resumes the caller; the others are cancelled.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var outcome: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func start(_ continuation: CheckedContinuation<T, any Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        let finished = state.withLockUnchecked { state -> Result<T, any Error>? in
            state.tasks = [work, timer]
            guard let outcome = state.outcome else { state.continuation = continuation; return nil }
            return outcome
        }
        guard let finished else { return }
        work.cancel()
        timer.cancel()
        continuation.resume(with: finished) // cancelled before it began
    }

    func finish(_ result: Result<T, any Error>) {
        let taken = state.withLockUnchecked { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>])? in
            guard state.outcome == nil else { return nil }
            state.outcome = result
            defer { state.continuation = nil }
            return (state.continuation, state.tasks)
        }
        guard let (continuation, tasks) = taken else { return }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

private extension Result where Failure == any Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
