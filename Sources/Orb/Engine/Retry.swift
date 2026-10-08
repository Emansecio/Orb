import Foundation

// Retrying transient provider failures (rate limits, overload, dropped connections) with backoff.

enum Retry {
    /// Backoff before the first retry; doubles each time.
    static let baseDelay: TimeInterval = 1
    /// Longest backoff we choose ourselves.
    static let maxBackoff: TimeInterval = 30
    /// Longest wait we accept when the provider names one: a longer `Retry-After` is a quota, not a hiccup.
    static let maxServerDelay: TimeInterval = 120

    /// Whether a failure is worth retrying: retryable `LLMError`s, and raw transport errors that did not get wrapped.
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? LLMError { return error.isRetryable }
        if let error = error as? URLError { return LLMError.retryableNetworkCodes.contains(error.code) }
        return false
    }

    /// What the status line says while waiting `seconds` to try again: a dropped connection and a rate limit are not
    /// "busy", and blaming the provider for the user's Wi-Fi sends them looking in the wrong place.
    static func waitStatus(seconds: TimeInterval, after error: Error) -> String {
        let cause = switch error {
        case LLMError.network, is URLError: "Conexão caiu"
        case LLMError.http(429, _, _), LLMError.stream("rate_limit_error", _), LLMError.stream("rate_limit_exceeded", _): "Limite do provedor"
        default: "Provedor ocupado"
        }
        return "\(cause), tentando de novo em \(Int(seconds.rounded(.up))) s"
    }

    /// Seconds to wait after `attempt` (1-based) failed: the provider's `Retry-After` when given, else exponential
    /// backoff with jitter, never above `maxBackoff`. nil when the provider asks for more than we will wait.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double) -> TimeInterval? {
        if let retryAfter {
            return retryAfter > maxServerDelay ? nil : max(0, retryAfter)
        }
        let backoff = min(maxBackoff, baseDelay * pow(2, Double(max(attempt, 1) - 1)))
        // "Equal jitter": half fixed, half random, so parallel clients don't retry in lockstep.
        return backoff * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }
}

/// Runs `operation`, retrying retryable failures up to `maxAttempts` times in total. `onWait` is told how long
/// it will wait, which attempt (1-based) just failed and why, so the UI can say "tentando de novo". Cancellation
/// (also while waiting) ends it at once; a non-retryable error is thrown as it is. A provider that asks for a wait
/// longer than `Retry.maxServerDelay` (a quota, not a hiccup) is not retried: its error is thrown at once and its
/// description tells how long the provider asked to wait.
func withRetries<T>(
    maxAttempts: Int = 4,
    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    jitter: () -> Double = { Double.random(in: 0...1) },
    onWait: (_ seconds: TimeInterval, _ attempt: Int, _ error: Error) -> Void = { _, _, _ in },
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch {
            guard attempt < maxAttempts, Retry.isRetryable(error),
                  let seconds = Retry.delay(afterAttempt: attempt, retryAfter: (error as? LLMError)?.retryAfter, jitter: jitter())
            else { throw error }
            onWait(seconds, attempt, error)
            try await sleep(seconds)
            attempt += 1
        }
    }
}
