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
        case LLMError.stream(LLMError.stalledType, _): "Provedor sem resposta"
        case LLMError.network, is URLError: "Conexão caiu"
        case LLMError.http(429, _, _), LLMError.stream("rate_limit_error", _), LLMError.stream("rate_limit_exceeded", _): "Limite do provedor"
        default: "Provedor ocupado"
        }
        return "\(cause)\(waitMarker)\(Int(seconds.rounded(.up))) s"
    }

    private static let waitMarker = ", tentando de novo em "

    /// The two parts of a `waitStatus` (why, and how many seconds), so the working line can say it with a countdown.
    /// nil for any other status.
    static func parseWaitStatus(_ status: String) -> (cause: String, seconds: Int)? {
        guard let marker = status.range(of: waitMarker), status.hasSuffix(" s"),
              let seconds = Int(status[marker.upperBound...].dropLast(2)) else { return nil }
        return (String(status[..<marker.lowerBound]), seconds)
    }

    /// Tries in all for a passing failure.
    static let standardAttempts = 4
    /// Tries in all for a failure that already cost minutes of waiting (a provider that went quiet, a connection that
    /// timed out): one more is worth it, four would hold the turn for twenty minutes.
    static let slowFailureAttempts = 2
    /// Tries in all for a usage limit or an overloaded provider: a limit per minute frees itself within a minute, so the
    /// waits add up to about that (`rateLimitBackoff`) instead of giving up a long task after seconds.
    static let rateLimitAttempts = 5
    /// The waits before each new try after a usage limit that names no wait of its own (with jitter, see `delay`).
    static let rateLimitBackoff: [TimeInterval] = [5, 15, 30, 60]

    /// A usage limit (not about money: waiting does not pay the bill) or an overloaded provider.
    static func isRateLimit(_ error: Error) -> Bool {
        switch error {
        case LLMError.http(429, _, _), LLMError.http(529, _, _): return (error as? LLMError)?.isRetryable == true
        case LLMError.stream(let type, _): return ["rate_limit_error", "rate_limit_exceeded", "overloaded_error"].contains(type)
        default: return false
        }
    }

    /// How many tries in all `error` gets: by its kind, never more than `maxAttempts` when the caller sets it.
    static func attemptLimit(for error: Error, maxAttempts: Int? = nil) -> Int {
        let own: Int
        switch error {
        case LLMError.stream(LLMError.stalledType, _), LLMError.network(URLError.timedOut.rawValue, _):
            own = slowFailureAttempts
        case let error as URLError where error.code == .timedOut:
            own = slowFailureAttempts
        case _ where isRateLimit(error):
            own = rateLimitAttempts
        default:
            own = standardAttempts
        }
        return maxAttempts.map { min($0, own) } ?? own
    }

    /// Seconds to wait after `attempt` (1-based) failed: the provider's `Retry-After` when given, else exponential
    /// backoff with jitter, never above `maxBackoff`. nil when the provider asks for more than we will wait.
    /// `rateLimited`: the failure was a usage limit (`isRateLimit`), whose waits are `rateLimitBackoff`.
    static func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double, rateLimited: Bool = false) -> TimeInterval? {
        if let retryAfter {
            return retryAfter > maxServerDelay ? nil : max(0, retryAfter)
        }
        let backoff = rateLimited
            ? rateLimitBackoff[min(max(attempt, 1), rateLimitBackoff.count) - 1]
            : min(maxBackoff, baseDelay * pow(2, Double(max(attempt, 1) - 1)))
        // "Equal jitter": half fixed, half random, so parallel clients don't retry in lockstep.
        return backoff * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }
}

/// Runs `operation`, retrying retryable failures up to `maxAttempts` times in total (nil: as many as each kind of failure
/// gets, see `Retry.attemptLimit`). `onWait` is told how long
/// it will wait, which attempt (1-based) just failed and why, so the UI can say "tentando de novo". Cancellation
/// (also while waiting) ends it at once; a non-retryable error is thrown as it is. A provider that asks for a wait
/// longer than `Retry.maxServerDelay` (a quota, not a hiccup) is not retried: its error is thrown at once and its
/// description tells how long the provider asked to wait.
func withRetries<T>(
    maxAttempts: Int? = nil,
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
            guard attempt < Retry.attemptLimit(for: error, maxAttempts: maxAttempts), Retry.isRetryable(error),
                  let seconds = Retry.delay(afterAttempt: attempt, retryAfter: (error as? LLMError)?.retryAfter, jitter: jitter(),
                                            rateLimited: Retry.isRateLimit(error))
            else { throw error }
            onWait(seconds, attempt, error)
            try await sleep(seconds)
            attempt += 1
        }
    }
}
