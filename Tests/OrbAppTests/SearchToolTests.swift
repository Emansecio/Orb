import Foundation
import Testing
@testable import Orb

/// grep, glob and the glob matcher behind them.
final class SearchToolTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await workspace.run(tool, arguments)
    }

    private func lines(_ output: String) -> [String] { output.split(separator: "\n").map(String.init) }

    // MARK: grep

    @Test func grepFindsMatchesAsPathLineText() async throws {
        try workspace.write("a.swift", "import Foundation\nlet needle = 1\nlet other = 2\n")
        try workspace.write("sub/b.swift", "// needle again\n")
        let output = try await run(GrepTool(), ["pattern": .string("needle")])
        #expect(lines(output) == ["a.swift:2: let needle = 1", "sub/b.swift:1: // needle again"])
    }

    @Test func grepAndGlobSeeSymlinkedFiles() async throws {
        try workspace.write("real/zshrc.txt", "export NEEDLE=1\n")
        try workspace.write("dots/.keep", "")
        try workspace.link("dots/linked.zshrc", to: "../real/zshrc.txt")
        try workspace.link("dots/folder-link", to: "../real")
        let found = try await run(GlobTool(), ["pattern": .string("*.zshrc")])
        #expect(lines(found) == ["dots/linked.zshrc"])
        let hits = try await run(GrepTool(), ["pattern": .string("NEEDLE"), "path": .string("dots")])
        #expect(lines(hits) == ["dots/linked.zshrc:1: export NEEDLE=1"])
    }

    @Test func grepGivesUpOnARunawayPatternInsteadOfHanging() async throws {
        try workspace.write("minified.js", String(repeating: "a", count: 60) + "b\n")
        let start = ContinuousClock.now
        let output = try await GrepTool(timeBudget: .milliseconds(400)).run(
            .object(["pattern": .string("(a+)+$")]), context: workspace.context)
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(output.contains("parou antes de varrer tudo"))
    }

    @Test func grepUsesRegexAndCaseOption() async throws {
        try workspace.write("a.txt", "Error: 404\nerror: 500\nfine\n")
        let sensitive = try await run(GrepTool(), ["pattern": .string(#"^Error: \d+"#)])
        #expect(lines(sensitive) == ["a.txt:1: Error: 404"])
        let insensitive = try await run(GrepTool(), ["pattern": .string("error"), "case_insensitive": .string("true")])
        #expect(lines(insensitive).count == 2)
        #expect(try await run(GrepTool(), ["pattern": .string("nothing here")]).contains("Nenhum resultado"))
    }

    @Test func grepRejectsBadPatternsAndModes() async throws {
        await #expect(throws: ToolError.self) { try await run(GrepTool(), ["pattern": .string("(unclosed")]) }
        await #expect(throws: ToolError.self) { try await run(GrepTool(), ["pattern": .string("x"), "mode": .string("lines")]) }
        await #expect(throws: ToolError.self) { try await run(GrepTool(), ["pattern": .string("x"), "path": .string("missing")]) }
        await #expect(throws: ToolError.self) { try await run(GrepTool(), ["pattern": .string("x"), "include": .string("[z-a]")]) }
    }

    @Test func grepSkipsIgnoredFoldersAndBinaryFiles() async throws {
        for folder in [".git", "node_modules", ".build", "DerivedData", "Pods", ".venv"] {
            try workspace.write("\(folder)/hit.txt", "needle\n")
        }
        try workspace.write("blob.dat", Data("needle".utf8) + Data([0, 1, 2, 3]))
        try workspace.write("real.txt", "needle\n")
        let output = try await run(GrepTool(), ["pattern": .string("needle")])
        #expect(lines(output) == ["real.txt:1: needle"])

        // Searching inside an ignored folder on purpose still works.
        let inside = try await run(GrepTool(), ["pattern": .string("needle"), "path": .string("node_modules")])
        #expect(inside.contains("hit.txt:1: needle"))
    }

    @Test func grepReadsNonUTF8Files() async throws {
        try workspace.write("latin.txt", try #require("coração\n".data(using: .windowsCP1252)))
        try workspace.write("u16.txt", Data([0xFF, 0xFE]) + (try #require("coração\n".data(using: .utf16LittleEndian))))
        let output = try await run(GrepTool(), ["pattern": .string("coração"), "mode": .string("files")])
        #expect(Set(lines(output)) == ["latin.txt", "u16.txt"])
    }

    @Test func grepIncludeGlobFiltersFiles() async throws {
        try workspace.write("a.swift", "needle\n")
        try workspace.write("a.md", "needle\n")
        try workspace.write("src/deep/c.swift", "needle\n")
        try workspace.write("src/deep/c.txt", "needle\n")
        #expect(Set(lines(try await run(GrepTool(), ["pattern": .string("needle"), "include": .string("*.swift"), "mode": .string("files")])))
                == ["a.swift", "src/deep/c.swift"])
        #expect(lines(try await run(GrepTool(), ["pattern": .string("needle"), "include": .string("src/**/*.txt"), "mode": .string("files")]))
                == ["src/deep/c.txt"])
    }

    @Test func grepCountAndFilesModes() async throws {
        try workspace.write("a.txt", "x\nx\nx\n")
        try workspace.write("b.txt", "x\ny\n")
        let count = try await run(GrepTool(), ["pattern": .string("x"), "mode": .string("count")])
        #expect(lines(count) == ["a.txt: 3", "b.txt: 1", "Total: 4 linhas em 2 arquivos."])
        let files = try await run(GrepTool(), ["pattern": .string("x"), "mode": .string("files")])
        #expect(lines(files) == ["a.txt", "b.txt"])
    }

    @Test func grepContextLinesUseDashSeparators() async throws {
        try workspace.write("a.txt", "1\n2\nhit\n4\n5\n6\n7\nhit\n9\n")
        let output = try await run(GrepTool(), ["pattern": .string("hit"), "context": .string("1")])
        #expect(lines(output) == ["a.txt-2- 2", "a.txt:3: hit", "a.txt-4- 4", "--", "a.txt-7- 7", "a.txt:8: hit", "a.txt-9- 9"])
        // Overlapping context windows do not repeat lines.
        try workspace.write("b.txt", "hit\nhit\nz\n")
        let merged = try await run(GrepTool(), ["pattern": .string("hit"), "context": .number(1), "path": .string("b.txt")])
        #expect(lines(merged) == ["b.txt:1: hit", "b.txt:2: hit", "b.txt-3- z"])
    }

    @Test func grepTruncatesResultsWithANote() async throws {
        try workspace.write("many.txt", (1...50).map { "hit \($0)" }.joined(separator: "\n") + "\n")
        try workspace.write("zlast.txt", "hit\n")
        let output = try await run(GrepTool(), ["pattern": .string("hit"), "max_results": .string("10")])
        let all = lines(output)
        #expect(all.count == 11)
        #expect(all.last?.contains("resultados truncados em 10") == true)
        #expect(all.first == "many.txt:1: hit 1")

        let exact = try await run(GrepTool(), ["pattern": .string("hit 1$"), "max_results": .number(1)])
        #expect(!exact.contains("truncados"), "exactly as many matches as the limit is not truncation")
    }

    @Test func grepClipsLongLines() async throws {
        try workspace.write("long.txt", String(repeating: "a", count: 1_000) + "needle" + String(repeating: "b", count: 1_000) + "\n")
        try workspace.write("start.txt", "needle" + String(repeating: "c", count: 1_000) + "\n")
        let output = lines(try await run(GrepTool(), ["pattern": .string("needle")]))
        let long = try #require(output.first { $0.hasPrefix("long.txt") })
        #expect(long.contains("needle"), "a match far into the line stays visible")
        #expect(long.count < 330)
        let start = try #require(output.first { $0.hasPrefix("start.txt") })
        #expect(start.hasSuffix("…") && start.count < 330)
    }

    @Test func grepSearchesASingleFileAndSymlinkedRoots() async throws {
        try workspace.write("one.txt", "needle\n")
        try workspace.write("two.txt", "needle\n")
        #expect(lines(try await run(GrepTool(), ["pattern": .string("needle"), "path": .string("one.txt")])) == ["one.txt:1: needle"])
        try workspace.link("linked", to: "one.txt")
        #expect(try await run(GrepTool(), ["pattern": .string("needle"), "path": .string("linked")]).contains("needle"))
        try FileManager.default.createDirectory(at: workspace.url("proj"), withIntermediateDirectories: true)
        try workspace.write("proj/inner.txt", "needle\n")
        try workspace.link("projlink", to: "proj")
        #expect(lines(try await run(GrepTool(), ["pattern": .string("needle"), "path": .string("projlink")])) == ["projlink/inner.txt:1: needle"])
    }

    @Test func grepIsSafeAndNeedsTheTerminalCapability() {
        for tool in [GrepTool() as any AgentTool, GlobTool()] {
            #expect(tool.risk(.object([:])) == .safe)
            #expect(tool.capability == .terminal)
        }
    }

    // MARK: glob

    @Test func globFindsFilesNewestFirst() async throws {
        let old = try workspace.write("old.md", "")
        let new = try workspace.write("docs/new.md", "")
        let mid = try workspace.write("docs/deep/mid.md", "")
        try workspace.write("ignored.txt", "")
        try workspace.write("node_modules/pkg/skip.md", "")
        for (url, seconds) in [(old, 1_000_000_000.0), (mid, 1_100_000_000.0), (new, 1_200_000_000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
        }
        let output = try await run(GlobTool(), ["pattern": .string("**/*.md")])
        #expect(lines(output) == ["docs/new.md", "docs/deep/mid.md", "old.md"])
        #expect(lines(try await run(GlobTool(), ["pattern": .string("docs/**/*.md")])) == ["docs/new.md", "docs/deep/mid.md"])
        #expect(lines(try await run(GlobTool(), ["pattern": .string("*.md"), "path": .string("docs")])) == ["docs/new.md", "docs/deep/mid.md"])
    }

    @Test func globCapsResultsAndReportsNoMatches() async throws {
        for index in 1...5 { try workspace.write("f\(index).txt", "") }
        let capped = lines(try await run(GlobTool(), ["pattern": .string("*.txt"), "max_results": .string("2")]))
        #expect(capped.count == 3)
        #expect(capped.last?.contains("mais 3 arquivos") == true)
        #expect(try await run(GlobTool(), ["pattern": .string("*.zzz")]).contains("Nenhum arquivo"))
        await #expect(throws: ToolError.self) { try await run(GlobTool(), ["pattern": .string("*"), "path": .string("nope")]) }
    }

    @Test func globPatternSyntax() throws {
        func matches(_ glob: String, _ path: String) throws -> Bool { try GlobPattern(glob).matches(relativePath: path) }
        #expect(try matches("*.swift", "a.swift"))
        #expect(try matches("*.swift", "deep/er/a.swift"), "no slash: matches the name at any depth")
        #expect(try !matches("src/*.swift", "src/deep/a.swift"))
        #expect(try matches("src/**/*.swift", "src/deep/er/a.swift"))
        #expect(try matches("src/**/*.swift", "src/a.swift"), "** may match no folder")
        #expect(try matches("**/a.swift", "a.swift"))
        #expect(try matches("*.{png,jpg}", "x.JPG"), "case-insensitive alternatives")
        #expect(try !matches("*.{png,jpg}", "x.gif"))
        #expect(try matches("file?.txt", "file1.txt"))
        #expect(try !matches("file?.txt", "file12.txt"))
        #expect(try matches("[ab]*.md", "b1.md"))
        #expect(try !matches("[!ab]*.md", "b1.md"))
        #expect(try matches("a.b", "a.b"))
        #expect(try !matches("a.b", "axb"), "dots are literal")
        #expect(try matches("./src/*.md", "src/x.md"))
        #expect(try GlobPattern("*.md").matches(name: "notes.md"))
    }
}
