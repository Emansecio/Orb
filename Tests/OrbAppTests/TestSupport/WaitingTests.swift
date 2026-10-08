import Foundation
import os
import Testing

/// The polling helper the timing-sensitive tests rely on.
struct WaitingTests {
    @Test func returnsAtOnceWhenTheConditionAlreadyHolds() async {
        let began = ContinuousClock.now
        #expect(await waitUntil("nothing", timeout: .seconds(30)) { true })
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func returnsAsSoonAsTheConditionStartsToHold() async {
        let ready = OSAllocatedUnfairLock(initialState: false)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            ready.withLock { $0 = true }
        }
        let began = ContinuousClock.now
        #expect(await waitUntil("the flag", timeout: .seconds(30)) { ready.withLock { $0 } })
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func anAsyncConditionCanReadAnActor() async {
        actor Counter {
            var value = 0
            func next() -> Int { value += 1; return value }
        }
        let counter = Counter()
        #expect(await waitUntil("the third look", timeout: .seconds(30)) { await counter.next() == 3 })
    }

    @Test func recordsAnIssueNamingWhatWasWaitedForOnTimeout() async {
        await withKnownIssue("a condition that never holds must fail the test") {
            let held = await waitUntil("a miracle", timeout: .milliseconds(60)) { false }
            #expect(!held)
        } matching: { issue in
            issue.description.contains("Timed out") && issue.description.contains("a miracle")
        }
    }

    @Test func aCancelledWaitEndsWithoutClaimingATimeout() async {
        // An Issue recorded inside the task would fail this test.
        let waiting = Task { await waitUntil("never", timeout: .seconds(30)) { false } }
        waiting.cancel()
        #expect(await !waiting.value)
    }

    @Test func aThrowingConditionEndsTheWait() async {
        struct Stop: Error {}
        await #expect(throws: Stop.self) {
            try await waitUntil("never") { throw Stop() }
        }
    }
}
