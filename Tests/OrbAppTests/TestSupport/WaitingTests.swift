import Foundation
import Testing

/// The polling helper the timing-sensitive tests rely on.
struct WaitingTests {
    @Test func returnsAtOnceWhenTheConditionAlreadyHolds() async {
        var calls = 0
        #expect(await waitUntil("nothing", timeout: .zero, poll: .seconds(30)) {
            calls += 1
            return true
        })
        #expect(calls == 1)
    }

    @Test func returnsAsSoonAsTheConditionStartsToHold() async {
        var calls = 0
        #expect(await waitUntil("the third look", poll: .milliseconds(1)) {
            calls += 1
            return calls == 3
        })
        #expect(calls == 3)
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

    @Test func cancellationDoesNotEvaluateTheCondition() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await waitUntil("already cancelled") {
                Issue.record("A cancelled wait must not evaluate its condition")
                return true
            }
        }
        #expect(await !waiting.value)
    }

    @Test(arguments: [false, true]) func cancellationDuringTheConditionIsNotReportedAsATimeout(satisfied: Bool) async {
        let waiting = Task {
            await waitUntil("cancelled by its condition", timeout: .zero) {
                withUnsafeCurrentTask { $0?.cancel() }
                return satisfied
            }
        }
        #expect(await !waiting.value)
    }

    @Test func aLongPollDoesNotExtendTheTimeout() async {
        await withKnownIssue("a condition that never holds must time out") {
            let began = ContinuousClock.now
            #expect(await !waitUntil("a long poll", timeout: .milliseconds(20), poll: .seconds(30)) { false })
            #expect(ContinuousClock.now - began < .seconds(10))
        } matching: { $0.description.contains("Timed out") }
    }
}
