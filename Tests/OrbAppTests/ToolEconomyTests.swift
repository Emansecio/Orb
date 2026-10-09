import Foundation
import Testing
@testable import Orb

/// What the tools cost the model: how long their specs are, which ones are offered, and how much one call returns.
struct ToolSpecEconomyTests {
    private func specChars(_ tools: [any AgentTool]) -> Int {
        tools.reduce(0) { total, tool in
            total + tool.spec.description.count + tool.spec.parameters.jsonString.count
        }
    }

    /// The same measure (description + schema, in characters, of `ToolBox.all`) taken on commit 43a00a7, before the
    /// pass that shortened the descriptions: 22,382. It is history, not a figure the code can reproduce.
    /// The specs measured 14,497 after the pass, and 14,994 with the skills in `remember` and `recall` (measured again after
    /// bringing in the on-demand connectors, the profile and the schedule); the ceiling leaves room for a sentence or two.
    private static let specCharsCeiling = 15_000

    @Test func theToolSpecsStayWellUnderTheirOldSize() {
        let now = specChars(ToolBox.all)
        // Every character is billed (or cached) in every request of every turn: this is a ceiling to keep, not a goal.
        #expect(now <= Self.specCharsCeiling, "\(now) characters")
    }

    @Test func noDescriptionIsEmptyAndNoSchemaCarriesAnEmptyRequiredList() {
        for tool in ToolBox.all {
            #expect(!tool.spec.description.isEmpty, "\(tool.spec.name)")
            #expect(tool.spec.parameters["required"]?.array?.isEmpty != true, "\(tool.spec.name)")
            #expect(tool.spec.parameters["type"] == .string("object"), "\(tool.spec.name)")
        }
        #expect(JSONValue.schema([:])["required"] == nil)
        #expect(JSONValue.schema(["a": .property("string")], required: ["a"])["required"] == .array([.string("a")]))
    }

    /// The guidance the shorter descriptions must still give: limits, safety notes and when to use the tool.
    @Test func theDescriptionsKeepTheirLimitsAndAdvice() throws {
        let needles: [String: [String]] = [
            "run_command": ["cd, export", "cwd", "120", "600", "20 KB", "background: true", "job_output", "job_list", "job_stop", "stdin"],
            "read_file": ["offset", "limit", "pages", "PDF", "OCR", "not file content", "never include"],
            "write_file": ["append", "edit_file", "UTF-8"],
            "edit_file": ["old_text", "replace_all", "unique", "Read the file first", "line-number prefix", "write_file"],
            "list_directory": ["depth", "pattern", "limit", "500", "modification date"],
            "search_files": ["Spotlight", "proves nothing", "glob", "grep"],
            "grep": ["regex", "path:line", "max_results", "include", "glob", "5 MB"],
            "glob": ["**", "newest first", "max_results", "1000", "grep"],
            "web_fetch": ["12,000", "24,000", "offset", "save_to", "PDF"],
            "open": ["web_fetch", "read_file", "app"],
            "applescript": ["osascript", "javascript", "300", "Automation permission", "dedicated tool"],
            "shortcuts_run": ["exact name", "300", "run only ones that match"],
            "app_quit": ["force", "unsaved", "confirm", "Orb"],
            "trash": ["50", "rm", "Refuses"],
            "screenshot": ["OCR", "Screen Recording", "window"],
            "browser_tab": ["logged-in", "web_fetch", "Permitir JavaScript de Eventos da Apple"],
            "ui_read": ["Accessibility", "400 lines", "passwords", "w1.3.2", "valid for this reading only"],
            "ui_act": ["ui_read", "interface mudou", "always asks the user first", "pick_menu", "Accessibility"],
            "remember": ["long-term memory", "near-duplicates", "tipo skill", "SKILL.md", "skill"],
            "recall": ["long-term memory", "before asking", "/name"],
            "clipboard_write": ["replacing"], "notify": ["not for ordinary replies"], "processes": ["app_quit"],
        ]
        for (name, words) in needles {
            let tool = try #require(ToolBox.all.first { $0.spec.name == name }, "\(name)")
            let text = tool.spec.description + " " + tool.spec.parameters.jsonString
            for word in words { #expect(text.contains(word), "\(name): \(word)") }
        }
    }

    @Test func theLimitsTheDescriptionsStateAreTheOnesInTheCode() {
        #expect(RunCommandTool.defaultTimeout == 120 && RunCommandTool.maxTimeout == 600)
        #expect(ListDirectoryTool.defaultEntries == 200 && ListDirectoryTool.maxEntries == 500)
        #expect(WebFetchTool.defaultCharacters == 12_000 && WebFetchTool.maxCharacters == 24_000)
        #expect(DocumentReader.maxCharacters == 24_000)
        #expect(GrepTool.lineLimit == 300)
    }

    // MARK: A page always fits under the cap

    @Test func aPageOfAPagingToolFitsUnderTheCapWithRoomForItsNotes() {
        // ToolOutputCap keeps the start and end of anything above its limit and loses the middle: the tools that tell
        // the model how to continue must stay below it, with room for their header and note.
        #expect(ToolOutputBudget.pageCharacters + 3_000 <= ToolOutputCap.limit)
        #expect(ToolOutputBudget.webPageDefault <= ToolOutputBudget.pageCharacters)
    }

    @Test func fitKeepsWholeLinesWithinTheBudgetAndCountsTheRest() {
        let lines = (0..<10).map { _ in String(repeating: "x", count: 9) } // 10 characters each with the newline
        let fitted = ToolOutputBudget.fit(lines, budget: 35)
        #expect(fitted.kept.count == 3 && fitted.omitted == 7)
        #expect(ToolOutputBudget.fit(lines, budget: 1_000).omitted == 0)
        // A first line above the budget is still returned: the result is never empty.
        let huge = ToolOutputBudget.fit([String(repeating: "y", count: 500), "z"], budget: 100)
        #expect(huge.kept.count == 1 && huge.omitted == 1)
        #expect(ToolOutputBudget.fit([], budget: 10).kept.isEmpty)
    }

    // MARK: Which tools are offered

    private let everything: Set<Capability> = [.terminal, .browser, .computerUse]

    @Test func theInterfaceToolsAreHeldBackWithoutAccessibility() {
        let held = ToolBox.offered(for: everything, accessibilityGranted: false).map(\.spec.name)
        let given = ToolBox.offered(for: everything, accessibilityGranted: true).map(\.spec.name)
        #expect(!held.contains("ui_read") && !held.contains("ui_act"))
        #expect(given.contains("ui_read") && given.contains("ui_act"))
        #expect(held == given.filter { !ToolBox.accessibilityToolNames.contains($0) })
        #expect(held.contains("applescript") && held.contains("screenshot") && held.contains("read_file"))
    }

    @Test func withoutAppsDoMacThereIsNothingToHoldBack() {
        let terminalOnly = ToolBox.offered(for: [.terminal], accessibilityGranted: false)
        #expect(terminalOnly.map(\.spec.name) == ToolBox.offered(for: [.terminal], accessibilityGranted: true).map(\.spec.name))
        #expect(!terminalOnly.contains { $0.capability == .computerUse })
        // The tools that need no capability (memory, scheduling, open, notify) are always there.
        let none = ToolBox.offered(for: [], accessibilityGranted: true).map(\.spec.name)
        let always: Set = ["open", "notify", "remember", "recall", "schedule"]
        #expect(Set(none) == always && none.count == always.count)
    }

    @Test func holdingTheToolsBackSavesTheirWholeSpec() {
        let held = specChars(ToolBox.offered(for: everything, accessibilityGranted: false))
        let given = specChars(ToolBox.offered(for: everything, accessibilityGranted: true))
        #expect(given - held > 1_500)
    }

    @Test func theNoteTellsWhereToAllowItAndWhatToUseMeanwhile() {
        let note = ToolBox.accessibilityUnavailableNote
        #expect(note.contains("ui_read") && note.contains("ui_act") && note.contains("Acessibilidade"))
        #expect(note.contains("AppleScript"))
    }
}

// MARK: - The turn offers what the permission allows

private actor SeenTools {
    private(set) var lists: [[String]] = []
    private(set) var systems: [String] = []
    func record(_ tools: [ToolSpec], _ messages: [ChatMessage]) {
        lists.append(tools.map(\.name))
        systems.append(messages.first { $0.role == .system }?.content ?? "")
    }
}

private struct RecordingLLM: LLMClient {
    let seen: SeenTools
    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await seen.record(tools, messages)
                continuation.yield(.text("ok"))
                continuation.yield(.finished(.done, nil))
                continuation.finish()
            }
        }
    }
}

@MainActor
struct AccessibilityGatingTests {
    private func sendOnce(capabilities: Set<Capability>, trusted: Bool) async throws -> (tools: [String], system: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.bots[0].capabilities = capabilities
        model.bots[0].workingDirectory = root.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seen = SeenTools()
        model.clientOverride = { RecordingLLM(seen: seen) }
        model.accessibilityProbe = { trusted }
        let bot = model.bots[0]
        #expect(model.send("oi", to: bot.id))
        await waitUntil("the model to be called") { await seen.lists.count >= 1 }
        await waitUntil("the turn to end") { !model.isWorking(bot.id) }
        return (await seen.lists[0], await seen.systems[0])
    }

    @Test func withoutAccessibilityTheOrbIsNotOfferedTheInterfaceToolsAndIsToldWhy() async throws {
        let (tools, system) = try await sendOnce(capabilities: [.terminal, .computerUse], trusted: false)
        #expect(!tools.contains("ui_read") && !tools.contains("ui_act"))
        #expect(tools.contains("applescript") && tools.contains("read_file"))
        #expect(system.hasSuffix(ToolBox.accessibilityUnavailableNote))
    }

    @Test func withAccessibilityItGetsThemAndTheSystemPromptIsUntouched() async throws {
        let (tools, system) = try await sendOnce(capabilities: [.terminal, .computerUse], trusted: true)
        #expect(tools.contains("ui_read") && tools.contains("ui_act"))
        #expect(!system.contains(ToolBox.accessibilityUnavailableNote))
    }

    @Test func anOrbWithoutAppsDoMacNeedsNoNoteAtAll() async throws {
        let (tools, system) = try await sendOnce(capabilities: [.terminal], trusted: false)
        #expect(!tools.contains("ui_read") && !tools.contains("applescript"))
        #expect(!system.contains(ToolBox.accessibilityUnavailableNote))
    }
}

// MARK: - Listings, searches and pages

final class ToolOutputSizeTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await workspace.run(tool, arguments)
    }

    private func lines(_ output: String) -> [String] { output.split(separator: "\n").map(String.init) }

    // MARK: read_file

    @Test func aBigFileComesInPagesThatNeverLoseTheirMiddle() async throws {
        // About 46,000 characters: more than a page, less than the old 50,000 that the cap cut in the middle.
        let text = (1...520).map { "linha \($0) " + String(repeating: "m", count: 70) }.joined(separator: "\n") + "\n"
        try workspace.write("Mid.swift", text)
        var offset = 1
        var seen = 0
        var pages = 0
        while offset <= 520 {
            let page = try await run(ReadFileTool(), ["path": .string("Mid.swift"), "offset": .number(Double(offset))])
            #expect(page.count < ToolOutputCap.limit)
            // The cap would leave this output alone, so every line it names is really there.
            #expect(ToolOutputCap.apply(page, botID: UUID(), callID: "x") == page)
            let numbers = lines(page).compactMap { Int($0.prefix(6).trimmingCharacters(in: .whitespaces)) }
            #expect(numbers.first == offset)
            seen += numbers.count
            pages += 1
            if let next = page.range(of: #"continue com offset=(\d+)\]$"#, options: .regularExpression) {
                offset = Int(page[next].drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 521
            } else {
                offset = 521
            }
        }
        #expect(seen == 520 && pages == 2)
    }

    @Test func theNoteSaysWhichLinesCameAndHowToContinue() async throws {
        let line = String(repeating: "q", count: 900)
        try workspace.write("wide.txt", (1...100).map { _ in line }.joined(separator: "\n") + "\n")
        let page = try await run(ReadFileTool(), ["path": .string("wide.txt")])
        let shown = lines(page).filter { $0.contains("\tq") }.count
        #expect(page.hasSuffix("[linhas 1–\(shown) de 100; continue com offset=\(shown + 1)]"))
        // The last page has no note.
        let tail = try await run(ReadFileTool(), ["path": .string("wide.txt"), "offset": .number(95)])
        #expect(!tail.contains("continue com offset"))
    }

    @Test func aPDFPageAlsoStaysUnderTheCap() async throws {
        let big = (1...30).map { "Página \($0): " + String(repeating: "pdf ", count: 20) }
        let data = try Fixtures.pdf(pages: big)
        try workspace.write("many.pdf", data)
        let output = try await run(ReadFileTool(), ["path": .string("many.pdf")])
        #expect(output.count < ToolOutputCap.limit)
    }

    // MARK: list_directory

    @Test func aTreeListingLeavesTheDatesOutAndKeepsTheSizes() async throws {
        try workspace.write("mod/sub/File.txt", String(repeating: "a", count: 700))
        try workspace.write("top.txt", "x")
        let tree = try await run(ListDirectoryTool(), ["depth": .number(3)])
        let treeLines = lines(tree)
        #expect(treeLines.contains { $0.hasPrefix("mod/sub/File.txt  (") && $0.hasSuffix(")") })
        // No timestamp anywhere in a recursive listing: a date is "yyyy-mm-dd hh:mm".
        #expect(tree.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#, options: .regularExpression) == nil)
        #expect(treeLines.contains("mod/"))
        #expect(tree.contains("700 bytes") || tree.contains("KB") || tree.contains("byte"))

        // One level keeps both.
        let flat = try await run(ListDirectoryTool(), [:])
        #expect(flat.range(of: #"top\.txt  \(.*\d{4}-\d{2}-\d{2} \d{2}:\d{2}\)"#, options: .regularExpression) != nil)
        #expect(flat.range(of: #"mod/  \(\d{4}-\d{2}-\d{2} \d{2}:\d{2}\)"#, options: .regularExpression) != nil)
    }

    @Test func aListingStopsAtTheLimitAndSaysHowToSeeMore() async throws {
        for index in 0..<250 { try workspace.write("f\(String(format: "%03d", index)).txt", "") }
        let first = try await run(ListDirectoryTool(), [:])
        // The folder's own path, 200 entries, the note.
        #expect(lines(first).count == 1 + ListDirectoryTool.defaultEntries + 1)
        #expect(first.contains("mais 50 itens") && first.contains("limit"))

        let more = try await run(ListDirectoryTool(), ["limit": .number(500)])
        #expect(lines(more).count == 1 + 250)
        #expect(!more.contains("mais"))

        let few = try await run(ListDirectoryTool(), ["limit": .string("5")])
        #expect(lines(few).count == 1 + 5 + 1)
        #expect(few.contains("mais 245 itens"))
        // The limit is clamped to what the tool allows.
        let huge = try await run(ListDirectoryTool(), ["limit": .number(1e9)])
        #expect(lines(huge).count == 1 + 250)
    }

    @Test func aListingOfLongPathsStaysUnderTheBudget() async throws {
        let folder = String(repeating: "d", count: 90)
        for index in 0..<300 { try workspace.write("\(folder)/\(String(repeating: "n", count: 90))\(index).txt", "") }
        let output = try await run(ListDirectoryTool(), ["path": .string(folder), "limit": .number(500)])
        #expect(output.count < ToolOutputCap.limit)
        #expect(output.contains("itens"))
        // Cut by the budget, not by `limit`: asking for a different limit would change nothing, so the note leaves it out.
        #expect(output.contains("use pattern ou um subcaminho") && !output.contains("limit"))
    }

    // MARK: grep and glob

    @Test func manyMatchesInOneFileShareOneHeader() async throws {
        try workspace.write("big.swift", (1...8).map { "let hit\($0) = \($0)" }.joined(separator: "\n") + "\n")
        try workspace.write("small.swift", "let hit = 1\nlet hit2 = 2\n")
        let output = lines(try await run(GrepTool(), ["pattern": .string("hit")]))
        #expect(output == ["big.swift:"] + (1...8).map { "  \($0): let hit\($0) = \($0)" }
                + ["small.swift:1: let hit = 1", "small.swift:2: let hit2 = 2"])
    }

    @Test func exactlyFiveMatchesKeepTheOldFormat() async throws {
        try workspace.write("five.txt", (1...5).map { "hit \($0)" }.joined(separator: "\n") + "\n")
        let output = lines(try await run(GrepTool(), ["pattern": .string("hit")]))
        #expect(output == (1...5).map { "five.txt:\($0): hit \($0)" })
    }

    @Test func contextAroundMatchesIsNeverGrouped() async throws {
        try workspace.write("c.txt", (1...20).map { "hit \($0)" }.joined(separator: "\n") + "\n")
        let output = lines(try await run(GrepTool(), ["pattern": .string("hit 1$|hit 3$|hit 5$|hit 7$|hit 9$|hit 11$"), "context": .number(1)]))
        #expect(output.allSatisfy { !$0.hasPrefix("  ") })
        #expect(output.first == "c.txt:1: hit 1")
    }

    @Test func aHugeResultIsCutWhereItFitsAndSaysSo() async throws {
        let line = "needle " + String(repeating: "w", count: 280)
        for file in 0..<4 { try workspace.write("f\(file).txt", (1...60).map { _ in line }.joined(separator: "\n") + "\n") }
        let output = try await run(GrepTool(), ["pattern": .string("needle"), "max_results": .number(1000)])
        #expect(output.count < ToolOutputCap.limit)
        #expect(output.contains("saída cortada por tamanho"))
        #expect(!output.contains("resultados truncados em"))
        // The cap would not have touched it, so the model gets exactly this.
        #expect(ToolOutputCap.apply(output, botID: UUID(), callID: "g") == output)
    }

    @Test func aSmallResultHasNoSizeNote() async throws {
        try workspace.write("a.txt", "needle\n")
        #expect(!(try await run(GrepTool(), ["pattern": .string("needle")])).contains("saída cortada"))
    }

    @Test func globStaysUnderTheBudgetAndCountsWhatItLeftOut() async throws {
        let folder = String(repeating: "g", count: 100)
        for index in 0..<400 { try workspace.write("\(folder)/\(String(repeating: "h", count: 80))-\(index).md", "") }
        let output = try await run(GlobTool(), ["pattern": .string("**/*.md"), "max_results": .number(1000)])
        #expect(output.count < ToolOutputCap.limit)
        let note = try #require(lines(output).last)
        #expect(note.hasPrefix("[... mais ") && note.contains("arquivos"))
        let shown = lines(output).count - 1
        let more = Int(note.dropFirst("[... mais ".count).prefix { $0.isNumber }) ?? -1
        #expect(shown + more == 400)
    }

    // MARK: web_fetch

    @Test func theDefaultFetchPageIsTwelveThousandCharacters() {
        let text = String(repeating: "a", count: 30_000)   // no break to cut at: the piece is exactly the size asked for
        let page = WebFetchTool.page(of: text, arguments: .object([:]), truncatedDownload: nil)
        #expect(page.hasPrefix("[caracteres 1–12000 de 30000]"))
        #expect(page.hasSuffix("use offset=12000 para continuar ...]"))
        let bigger = WebFetchTool.page(of: text, arguments: .object(["max_chars": .number(24_000)]), truncatedDownload: nil)
        #expect(bigger.hasPrefix("[caracteres 1–24000 de 30000]"))
        #expect(WebFetchTool.page(of: text, arguments: .object(["max_chars": .number(99_000)]), truncatedDownload: nil).contains("1–24000"))
        // A piece ends at a line break, else at a space, never inside a word; the note says where it stopped.
        let words = String(repeating: "abcdef ", count: 5_000)
        let soft = WebFetchTool.page(of: words, arguments: .object([:]), truncatedDownload: nil)
        #expect(soft.hasPrefix("[caracteres 1–11998 de 35000]") && soft.hasSuffix("use offset=11998 para continuar ...]"))
        let lines = (0..<2_000).map { "linha \($0) de texto" }.joined(separator: "\n")
        let byLine = WebFetchTool.page(of: lines, arguments: .object([:]), truncatedDownload: nil)
        let offset = try? #require(Int(byLine.components(separatedBy: "use offset=").last?.components(separatedBy: " ").first ?? ""))
        #expect(offset.map { lines[lines.index(lines.startIndex, offsetBy: $0 - 1)] == "\n" } == true)
        // A short page has no header and no note.
        #expect(WebFetchTool.page(of: "curto", arguments: .object([:]), truncatedDownload: nil) == "curto")
    }

    // MARK: screenshot

    @Test func theTextOnACaptureTheModelSeesIsShortened() {
        let ocr = (1...400).map { "linha \($0) do texto reconhecido" }.joined(separator: "\n")
        let capture = ScreenshotTool.Capture(header: "Captura salva em /tmp/a.png (100×100 px).", ocr: ocr,
                                             file: URL(fileURLWithPath: "/tmp/a.png"))
        let withPicture = capture.report(ocrLimit: ScreenshotTool.ocrLimitWithPicture)
        let textOnly = capture.report(ocrLimit: ScreenshotTool.ocrLimitTextOnly)
        #expect(ScreenshotTool.ocrLimitWithPicture == 1_500 && ScreenshotTool.ocrLimitTextOnly == 8_000)
        #expect(withPicture.count < 1_500 + 400)
        #expect(textOnly.count > 7_000 && textOnly.count < 8_400)
        #expect(withPicture.hasPrefix("Captura salva em /tmp/a.png (100×100 px).\nTexto na imagem (OCR):\nlinha 1 do texto"))
        #expect(withPicture.contains("caracteres omitidos"))
    }

    @Test func aCaptureWithoutTextSaysSoInEitherCase() {
        let capture = ScreenshotTool.Capture(header: "Captura.", ocr: "", file: URL(fileURLWithPath: "/tmp/a.png"))
        #expect(capture.report(ocrLimit: 1_500) == "Captura.\nNão achei texto legível na imagem.")
        #expect(capture.report(ocrLimit: 8_000) == capture.report(ocrLimit: 1_500))
    }
}
