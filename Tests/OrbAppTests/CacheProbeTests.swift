import Foundation
import Testing
@testable import Orb

/// The per-request cache diagnosis (`CacheProbe`): a stable fingerprint of each request's segments, so an
/// offline diff shows where the provider's cache stopped matching.
struct CacheProbeTests {
    @Test func theHashIsStableEnoughToCompareAcrossLaunches() {
        #expect(CacheProbe.hash("abc") == CacheProbe.hash("abc"))
        #expect(CacheProbe.hash("abc") != CacheProbe.hash("abd"))
        #expect(CacheProbe.hash("") != CacheProbe.hash(" "))
        // FNV-1a 64-bit of "abc": a fixed value, so lines written by different builds still compare.
        #expect(CacheProbe.hash("abc") == "e71fa2190541574b")
    }

    @Test func theFingerprintTagsEachSegmentWithoutItsText() {
        let body = JSONValue.object([
            "instructions": .string("sistema"),
            "tools": .array([.object(["name": .string("x")])]),
            "input": .array([
                .object(["role": .string("user"), "content": .string("oi")]),
                .object(["type": .string("function_call"), "call_id": .string("c1")]),
            ]),
        ])
        let fp = CacheProbe.fingerprint(of: body)
        #expect(fp["instr"]?.array?.count == 2) // chars + hash
        #expect(fp["tools"]?.array?.first?.int == 1)
        let items = fp["items"]?.array ?? []
        #expect(items.map { $0.array?.first?.string } == ["user", "function_call"])
        #expect(items.allSatisfy { $0.array?.count == 3 })
        // The same body fingerprints identically; one changed item changes only that item's hash.
        #expect(CacheProbe.fingerprint(of: body) == fp)
        let changed = JSONValue.object([
            "instructions": .string("sistema"),
            "tools": .array([.object(["name": .string("x")])]),
            "input": .array([.object(["role": .string("user"), "content": .string("oi!")]),
                             .object(["type": .string("function_call"), "call_id": .string("c1")])]),
        ])
        let other = CacheProbe.fingerprint(of: changed)
        #expect(other["items"]?.array?[0] != fp["items"]?.array?[0])
        #expect(other["items"]?.array?[1] == fp["items"]?.array?[1])
        #expect(other["instr"] == fp["instr"])
    }

    @Test func theToolListInsideAnInputItemIsFoundToo() {
        // ChatGPT's gateway carries `additional_tools` as the first input item instead of `tools`.
        let body = JSONValue.object([
            "input": .array([
                .object(["type": .string("additional_tools"), "tools": .array([.object(["name": .string("x")])])]),
                .object(["role": .string("user"), "content": .string("oi")]),
            ]),
        ])
        let fp = CacheProbe.fingerprint(of: body)
        #expect(fp["tools"]?.array?.first?.int == 1)
        #expect(fp["items"]?.array?.first?.array?.first?.string == "additional_tools")
    }

    @Test func theMonthFileNameFollowsTheUsageFiles() throws {
        let file = CacheProbe.file(in: URL(fileURLWithPath: "/tmp/uso"), at: try Date("2026-10-27T20:00:00Z", strategy: .iso8601),
                                   calendar: Calendar(identifier: .gregorian))
        #expect(file.lastPathComponent.hasPrefix("cache-probe-2026-") && file.pathExtension == "jsonl")
    }
}
