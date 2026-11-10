import Foundation
import os
import Testing
@testable import Orb

// The motion that exists only for someone watching the live screen (docs/TELA-AO-VIVO.md, 4): the click waits for the cursor,
// scrolling goes in steps, and with nobody looking (or the setting off) the tools are exactly what they were.

struct LiveMotionStepsTests {
    @Test func theStepsAlwaysAddUpToTheExactPixelsAsked() {
        for pixels in [1, 49, 50, 99, 100, 101, 250, 333, 600, 777, 1_234, 5_000, 10_000] {
            let steps = LiveMotion.scrollSteps(pixels)
            #expect(steps.reduce(0, +) == pixels, "\(pixels) px")
            #expect(steps.allSatisfy { $0 > 0 })
        }
    }

    @Test func aShortScrollIsOneStepAndALongOneIsSeveralThatEaseInAndOut() {
        #expect(LiveMotion.scrollSteps(40) == [40])
        #expect(LiveMotion.scrollSteps(99) == [99])
        let steps = LiveMotion.scrollSteps(600)
        #expect(steps.count == 7, "no more than seven, about a quarter of a second in all")
        #expect(steps.first! < steps[steps.count / 2] && steps.last! < steps[steps.count / 2], "slow at both ends, fast in the middle")
    }
}

struct LiveMotionToolTests {
    private func listen(_ setup: FakeBrowserSetup) -> OSAllocatedUnfairLock<[LivePointer]> {
        let heard = OSAllocatedUnfairLock<[LivePointer]>(initialState: [])
        setup.hub.setPointerHandler { _, pointer in heard.withLock { $0.append(pointer) } }
        return heard
    }

    private func run(_ setup: FakeBrowserSetup, _ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: setup.context())
    }

    @Test func withNobodyWatchingNothingWaitsAndNoCommandIsAdded() async throws {
        let setup = FakeBrowserSetup(motion: true)
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        _ = try await run(setup, BrowseClickTool(), ["ref": .string("e1")])
        _ = try await run(setup, BrowseScrollTool(), ["amount": .number(600)])
        #expect(setup.pauses.withLock { $0.isEmpty })
        #expect(setup.driver.calls.filter { $0 == "box e1" || $0.contains("steps") }.isEmpty)
        #expect(setup.driver.calls.contains("scroll down 600"))
    }

    @Test func aClickWaitsForTheCursorToArriveAndOnlyThenActs() async throws {
        let setup = FakeBrowserSetup(motion: true)
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        let heard = listen(setup)
        _ = try await run(setup, BrowseClickTool(), ["ref": .string("e1")])
        #expect(heard.withLock { $0.count } == 1)
        #expect(setup.pauses.withLock { $0 } == [LiveMotion.travel])
    }

    @Test func stoppingDuringTheWaitMeansTheActionNeverHappens() async throws {
        let setup = FakeBrowserSetup(motion: true)
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        _ = listen(setup)
        setup.cancelsPauses.withLock { $0 = true }
        await #expect(throws: CancellationError.self) { _ = try await run(setup, BrowseClickTool(), ["ref": .string("e1")]) }
        #expect(!setup.driver.calls.contains("click e1"), "the click is after the wait, so Parar ends it first")
    }

    @Test func withMotionOffTheCursorStillMovesButNothingWaits() async throws {
        let setup = FakeBrowserSetup(motion: false)
        setup.driver.state.withLock { $0.boxes["e1"] = CGRect(x: 1, y: 2, width: 3, height: 4) }
        let heard = listen(setup)
        _ = try await run(setup, BrowseClickTool(), ["ref": .string("e1")])
        _ = try await run(setup, BrowseScrollTool(), ["amount": .number(600)])
        #expect(heard.withLock { $0.count } == 1)
        #expect(setup.pauses.withLock { $0.isEmpty })
        #expect(setup.driver.calls.contains("scroll down 600") && !setup.driver.calls.contains { $0.contains("steps") })
    }

    @Test func aWatchedScrollGoesInStepsThatAddUpToTheSamePixels() async throws {
        let setup = FakeBrowserSetup(motion: true)
        _ = listen(setup)
        let text = try await run(setup, BrowseScrollTool(), ["amount": .number(900), "direction": .string("up")])
        let call = try #require(setup.driver.calls.first { $0.hasPrefix("scroll up steps ") })
        let steps = call.dropFirst("scroll up steps ".count).split(separator: ",").compactMap { Int($0) }
        #expect(steps.count > 1 && steps.reduce(0, +) == 900)
        #expect(text.contains("Scrolled up 900 px."))
    }

    @Test func aShortWatchedScrollStaysOneScroll() async throws {
        let setup = FakeBrowserSetup(motion: true)
        _ = listen(setup)
        _ = try await run(setup, BrowseScrollTool(), ["amount": .number(40)])
        #expect(setup.driver.calls.contains("scroll down 40"))
    }
}
