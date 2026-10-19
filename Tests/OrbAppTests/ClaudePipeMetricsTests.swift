import Foundation
import Testing
@testable import Orb

struct ClaudePipeMetricsTests {
    @Test func lineHasOnlyNumbersAndEnums() throws {
        let metric = ClaudePipeMetric(
            timestamp: Date(timeIntervalSince1970: 0), conversation: ClaudePipeMetric.tag(of: "abc"), model: "sonnet", fresh: .noParked,
            messageCount: 7, characterCount: 1234,
            usage: TokenUsage(input: 3, output: 42, cacheRead: 100, cacheWrite: 16000, cacheWrite1h: 15000))
        let json = try #require(JSONValue.parse(metric.line))
        #expect(json["plan"]?.string == "fresh")
        #expect(json["reason"]?.string == "noParked")
        #expect(json["messages"]?.int == 7)
        #expect(json["chars"]?.int == 1234)
        #expect(json["cacheWrite1h"]?.int == 15000)
        #expect(json["ts"]?.string == "1970-01-01T00:00:00Z")
        #expect(json["conv"]?.string?.count == 8)
        #expect(!metric.line.contains("abc"))
    }

    @Test func resumeStepHasNoReasonAndUnknownCountsAreOmitted() throws {
        let metric = ClaudePipeMetric(timestamp: .now, conversation: nil, model: "m", fresh: nil, messageCount: 1, characterCount: 2,
                                      usage: TokenUsage(input: 1))
        let json = try #require(JSONValue.parse(metric.line))
        #expect(json["plan"]?.string == "resume")
        #expect(json["reason"] == nil)
        #expect(json["conv"] == nil)
        #expect(json["cacheRead"] == nil)
    }

    @Test func fileRotatesPastTheLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orb-metrics-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cache-metrics.jsonl")
        ClaudePipeMetricsLog.append("first\n", to: file, limit: 10)
        ClaudePipeMetricsLog.append("second\n", to: file, limit: 10)
        #expect(try String(contentsOf: file, encoding: .utf8) == "first\nsecond\n")
        ClaudePipeMetricsLog.append("third\n", to: file, limit: 10)
        #expect(try String(contentsOf: file, encoding: .utf8) == "third\n")
        #expect(try String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8) == "first\nsecond\n")
    }

    @Test func cacheTTLOnlyForRunsLessFrequentThanAnHour() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Schedule.daily(hour: 9, minute: 0).cacheTTL(after: now) == "5m")
        #expect(Schedule.weekly(weekday: 2, hour: 9, minute: 0).cacheTTL(after: now) == "5m")
        #expect(Schedule.everyHours(2).cacheTTL(after: now) == "5m")
        #expect(Schedule.once(now.addingTimeInterval(60)).cacheTTL(after: now) == "5m")
        #expect(Schedule.cron(expression: "0 9 * * *", timeZone: "UTC").cacheTTL(after: now) == "5m")
        #expect(Schedule.everyHours(1).cacheTTL(after: now) == nil)
        #expect(Schedule.everyMinutes(15).cacheTTL(after: now) == nil)
        #expect(Schedule.cron(expression: "*/30 * * * *", timeZone: "UTC").cacheTTL(after: now) == nil)
    }

    @Test func environmentAddsTheTTLOnlyWhenAsked() {
        let base = ["PATH": "/bin", "DISABLE_AUTO_COMPACT": "0"]
        let plain = ClaudeCodeClient.environment(base, cacheTTL: nil)
        #expect(plain["CLAUDE_CODE_PROMPT_CACHE_TTL"] == nil)
        #expect(plain["DISABLE_AUTO_COMPACT"] == "1")
        #expect(plain["PATH"] == "/bin")
        #expect(ClaudeCodeClient.environment(base, cacheTTL: "5m")["CLAUDE_CODE_PROMPT_CACHE_TTL"] == "5m")
    }
}
