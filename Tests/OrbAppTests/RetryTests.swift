import Foundation
import Testing
@testable import Orb

struct RetryTests {
    private let overloaded = LLMError.http(status: 503, message: "busy")

    /// Runs `operation` failing with `errors` in turn, then succeeding; records sleeps and `onWait` calls.
    private func run(failing errors: [Error], maxAttempts: Int = 4, jitter: Double = 1)
        async -> (result: Result<String, Error>, attempts: Int, sleeps: [TimeInterval], waits: [Int]) {
        let attempts = Box<Int>(0)
        let sleeps = Box<[TimeInterval]>([])
        let waits = Box<[Int]>([])
        let result: Result<String, Error>
        do {
            let value = try await withRetries(
                maxAttempts: maxAttempts,
                sleep: { seconds in sleeps.update { $0.append(seconds) } },
                jitter: { jitter },
                onWait: { _, attempt, _ in waits.update { $0.append(attempt) } }
            ) { () -> String in
                let number = attempts.value
                attempts.update { $0 += 1 }
                if number < errors.count { throw errors[number] }
                return "ok"
            }
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        return (result, attempts.value, sleeps.value, waits.value)
    }

    @Test func succeedsWithoutWaitingWhenNothingFails() async {
        let outcome = await run(failing: [])
        #expect((try? outcome.result.get()) == "ok")
        #expect(outcome.attempts == 1)
        #expect(outcome.sleeps.isEmpty)
    }

    @Test func retriesWithExponentialBackoff() async {
        let outcome = await run(failing: [overloaded, overloaded, overloaded])
        #expect((try? outcome.result.get()) == "ok")
        #expect(outcome.attempts == 4)
        #expect(outcome.sleeps == [1, 2, 4])
        #expect(outcome.waits == [1, 2, 3])
    }

    @Test func givesUpAfterMaxAttemptsWithTheLastError() async {
        let outcome = await run(failing: Array(repeating: overloaded, count: 10))
        #expect(outcome.attempts == 4)
        #expect(outcome.sleeps.count == 3)
        guard case .failure(let error) = outcome.result else { Issue.record("should fail"); return }
        #expect(error as? LLMError == overloaded)
    }

    @Test func doesNotRetryPermanentErrors() async {
        let denied = LLMError.http(status: 401, message: "bad key")
        let outcome = await run(failing: [denied])
        #expect(outcome.attempts == 1)
        #expect(outcome.sleeps.isEmpty)
        guard case .failure(let error) = outcome.result else { Issue.record("should fail"); return }
        #expect(error as? LLMError == denied)

        let tooBig = await run(failing: [LLMError.contextExceeded("too long")])
        #expect(tooBig.attempts == 1)
        let other = await run(failing: [ToolError("nope")])
        #expect(other.attempts == 1)
    }

    @Test func jitterSpreadsTheBackoff() {
        #expect(Retry.delay(afterAttempt: 1, retryAfter: nil, jitter: 0) == 0.5)
        #expect(Retry.delay(afterAttempt: 1, retryAfter: nil, jitter: 1) == 1)
        #expect(Retry.delay(afterAttempt: 3, retryAfter: nil, jitter: 0.5) == 3)
    }

    @Test func backoffIsCappedAtThirtySeconds() {
        #expect(Retry.delay(afterAttempt: 10, retryAfter: nil, jitter: 1) == 30)
        #expect(Retry.delay(afterAttempt: 100, retryAfter: nil, jitter: 1) == 30)
    }

    @Test func honorsRetryAfterFromTheProvider() async {
        let limited = LLMError.http(status: 429, message: "slow", retryAfter: 9)
        let outcome = await run(failing: [limited, limited], jitter: 0)
        #expect(outcome.sleeps == [9, 9])
    }

    @Test func doesNotWaitForAQuotaResetOfMinutes() async {
        let quota = LLMError.http(status: 429, message: "daily quota", retryAfter: 3600)
        let outcome = await run(failing: [quota])
        #expect(outcome.attempts == 1)
        #expect(outcome.sleeps.isEmpty)
        #expect((try? outcome.result.get()) == nil)
    }

    @Test func retriesRawTransportErrorsToo() async {
        let outcome = await run(failing: [URLError(.networkConnectionLost)])
        #expect(outcome.attempts == 2)
        let cancelled = await run(failing: [URLError(.cancelled)])
        #expect(cancelled.attempts == 1)
    }

    @Test func cancellationInterruptsTheWait() async {
        let entered = Box<Bool>(false)
        let task = Task {
            try await withRetries(
                sleep: { seconds in
                    entered.value = true
                    try await Task.sleep(for: .seconds(60))
                }
            ) { () -> String in throw LLMError.http(status: 503, message: "busy") }
        }
        await waitUntil("the retry wait to begin") { entered.value }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCancelledTaskDoesNotStartAnotherAttempt() async {
        let attempts = Box<Int>(0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withRetries { () -> String in attempts.update { $0 += 1 }; return "ok" }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(attempts.value == 0)
    }
}

struct RetryStatusTests {
    @Test func theStatusNamesWhatWentWrong() {
        let status = { (error: Error) in Retry.waitStatus(seconds: 1.2, after: error) }
        #expect(status(LLMError.http(status: 503, message: "")) == "Provedor ocupado, tentando de novo em 2 s")
        #expect(status(LLMError.stream(type: "overloaded_error", message: "")) == "Provedor ocupado, tentando de novo em 2 s")
        #expect(status(LLMError.network(code: URLError.timedOut.rawValue, message: "")) == "Conexão caiu, tentando de novo em 2 s")
        #expect(status(URLError(.networkConnectionLost)) == "Conexão caiu, tentando de novo em 2 s")
        #expect(status(LLMError.http(status: 429, message: "slow")) == "Limite do provedor, tentando de novo em 2 s")
        #expect(status(LLMError.stream(type: "rate_limit_error", message: "")) == "Limite do provedor, tentando de novo em 2 s")
    }

    @Test func onWaitReceivesTheErrorThatCausedIt() async throws {
        let seen = Box<[LLMError]>([])
        let attempts = Box<Int>(0)
        _ = try await withRetries(sleep: { _ in }, onWait: { _, _, error in seen.update { $0.append(error as! LLMError) } }) { () -> Int in
            attempts.update { $0 += 1 }
            if attempts.value == 1 { throw LLMError.network(code: URLError.timedOut.rawValue, message: "t") }
            return 1
        }
        #expect(seen.value == [.network(code: URLError.timedOut.rawValue, message: "t")])
    }
}

struct LLMErrorTests {
    @Test func classifiesRetryableStatuses() {
        for status in [408, 409, 429, 500, 502, 503, 504, 529] {
            #expect(LLMError.http(status: status, message: "").isRetryable, "\(status)")
        }
        for status in [400, 401, 403, 404, 413, 422] {
            #expect(!LLMError.http(status: status, message: "").isRetryable, "\(status)")
        }
    }

    @Test func classifiesRetryableNetworkAndStreamErrors() {
        let codes: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet]
        for code in codes { #expect(LLMError.network(code: code.rawValue, message: "").isRetryable) }
        #expect(!LLMError.network(code: URLError.badURL.rawValue, message: "").isRetryable)
        #expect(LLMError.stream(type: "overloaded_error", message: "").isRetryable)
        #expect(LLMError.stream(type: "api_error", message: "").isRetryable)
        #expect(!LLMError.stream(type: "invalid_request_error", message: "").isRetryable)
        #expect(!LLMError.notConfigured.isRetryable)
        #expect(!LLMError.invalidResponse("x").isRetryable)
    }

    @Test func wrapsTransportErrorsButNotCancellation() {
        #expect(LLMError.wrapping(URLError(.timedOut)) as? LLMError != nil)
        #expect(LLMError.wrapping(URLError(.cancelled)) is URLError)
        #expect(LLMError.wrapping(CancellationError()) is CancellationError)
        #expect(LLMError.wrapping(ToolError("x")) is ToolError)
    }

    @Test func describesFailuresInPortugueseKeepingTheProviderDetail() {
        let describe = { (status: Int) in LLMError.http(status: status, message: "detalhe X").errorDescription ?? "" }
        #expect(describe(401).contains("Chave ou login inválido") && describe(401).contains("detalhe X"))
        #expect(describe(403).contains("Chave ou login inválido"))
        #expect(describe(429).contains("limite de uso") && describe(429).contains("detalhe X"))
        for status in [500, 502, 503, 529] {
            #expect(describe(status).contains("sobrecarregado") && describe(status).contains("detalhe X"))
        }
        #expect(describe(404) == "O provedor respondeu 404: detalhe X")
        #expect(LLMError.contextExceeded("detalhe X").errorDescription?.contains("grande demais") == true)
        #expect(LLMError.stream(type: "overloaded_error", message: "detalhe X").errorDescription?.contains("sobrecarregado") == true)
        #expect(LLMError.network(code: URLError.timedOut.rawValue, message: "detalhe X").errorDescription?.contains("detalhe X") == true)
    }

    @Test func recognizesContextOverflowMessages() {
        for message in ["This model's maximum context length is 8192 tokens", "prompt is too long: 250000 tokens > 200000",
                        "Input is too long for requested model", "Your input exceeds the context window of this model",
                        #"{"error":{"code":"context_length_exceeded"}}"#] {
            #expect(LLMError.isContextOverflow(message), "\(message)")
        }
        #expect(!LLMError.isContextOverflow("Incorrect API key"))
        #expect(!LLMError.isContextOverflow("Invalid tool schema"))
    }
}
