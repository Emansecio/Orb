import Foundation

/// How a call that is expected to fail ends: its error's description, or "" when it does not throw.
/// Runs on the caller's actor, so a closure that touches the caller's state needs no `Sendable`.
func failureMessage<Result>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Result) async -> String {
    do { _ = try await body(); return "" } catch { return error.localizedDescription }
}
