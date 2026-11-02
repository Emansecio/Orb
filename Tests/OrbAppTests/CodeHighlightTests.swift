import Foundation
import SwiftUI
import Testing
@testable import Orb

/// The colors of code: what each language marks, and that a stray mark never colors the rest of a block.
@Suite("Cores do código") struct CodeHighlightTests {
    private func marked(_ code: String, _ language: String) -> [String: CodeSpan.Kind] {
        let bytes = Array(code.utf8)
        var found: [String: CodeSpan.Kind] = [:]
        for span in CodeHighlight.spans(code, language: language) {
            found[String(decoding: bytes[span.start..<span.end], as: UTF8.self)] = span.kind
        }
        return found
    }

    @Test func swiftMarksKeywordsTypesStringsNumbersAndComments() {
        let found = marked("@MainActor struct Preço {\n  let n = 12.5 // taxa\n  let s = \"a \\\" b\"\n}", "swift")
        #expect(found["@MainActor"] == .keyword)
        #expect(found["struct"] == .keyword)
        #expect(found["let"] == .keyword)
        #expect(found["Preço"] == .type)
        #expect(found["12.5"] == .number)
        #expect(found["// taxa"] == .comment)
        #expect(found["\"a \\\" b\""] == .string)
        #expect(found["n"] == nil)
    }

    @Test func multilineStringsAndCommentsGoOnOverLines() {
        #expect(marked("/* a\nb */ let", "swift")["/* a\nb */"] == .comment)
        #expect(marked("x = \"\"\"a\n\"b\"\n\"\"\"", "python")["\"\"\"a\n\"b\"\n\"\"\""] == .string)
        #expect(marked("const a = `x\ny`", "ts")["`x\ny`"] == .string)
    }

    @Test func aStrayQuoteColorsOneLineAtMost() {
        let found = marked("let a = \"sem fim\nlet b = 1", "swift")
        #expect(found["\"sem fim"] == .string)
        #expect(found["1"] == .number)
    }

    @Test func anApostropheInAWordIsNotAString() {
        #expect(marked("echo don't\nfor x", "bash")["for"] == .keyword)
        #expect(marked("echo 'isto é'", "bash")["'isto é'"] == .string)
    }

    @Test func aHashIsACommentOnlyAfterASpaceInTheShell() {
        let found = marked("echo ${#a} url#b # fim", "bash")
        #expect(found["# fim"] == .comment)
        #expect(found.keys.filter { $0.hasPrefix("#") }.count == 1)
        #expect(marked("echo $HOME", "sh")["$HOME"] == .type)
    }

    @Test func jsonAndYamlTellKeysFromValues() {
        let json = marked("{\"a\": \"b\", \"c\": true}", "json")
        #expect(json["\"a\""] == .keyword)
        #expect(json["\"b\""] == .string)
        #expect(json["true"] == .keyword)
        let yaml = marked("nome: x # nota\nhora: 12:30\nurl: http://a.b", "yaml")
        #expect(yaml["nome"] == .keyword)
        #expect(yaml["# nota"] == .comment)
        #expect(yaml["http"] == nil)
    }

    @Test func sqlIgnoresCase() {
        let found = marked("SELECT a FROM b where c = 'd' -- fim", "SQL")
        #expect(found["SELECT"] == .keyword)
        #expect(found["where"] == .keyword)
        #expect(found["'d'"] == .string)
        #expect(found["-- fim"] == .comment)
    }

    @Test func markupMarksTagsAttributesValuesAndComments() {
        let found = marked("<!-- nota --><a href=\"x\">a < b</a>", "html")
        #expect(found["<!-- nota -->"] == .comment)
        #expect(found["<a"] == .keyword)
        #expect(found["href"] == .type)
        #expect(found["\"x\""] == .string)
        #expect(found["</a"] == .keyword)
        #expect(found["b"] == nil)
    }

    @Test func diffAndMarkdownGoByLine() {
        let diff = marked("@@ -1 +1 @@\n-a\n+b\n c", "patch")
        #expect(diff["@@ -1 +1 @@"] == .keyword)
        #expect(diff["-a"] == .removed)
        #expect(diff["+b"] == .added)
        #expect(diff.count == 3)
        let markdown = marked("# Título\n> nota\ntexto `código` e `sem fim", "md")
        #expect(markdown["# Título"] == .keyword)
        #expect(markdown["> nota"] == .comment)
        #expect(markdown["`código`"] == .string)
        #expect(markdown.count == 3)
    }

    @Test func spansAreInOrderWithoutOverlaps() {
        let code = "let a = \"é\" /* x */ + 1 // ü\nfunc b() -> Int { 2 }"
        var cursor = 0
        for span in CodeHighlight.spans(code, language: "swift") {
            #expect(span.start >= cursor)
            #expect(span.end > span.start)
            cursor = span.end
        }
        #expect(cursor <= code.utf8.count)
    }

    @Test func colorsKeepTheTextIntact() throws {
        for (code, language) in [("let é = \"ñ\" // ü\n\n  var x", "swift"), ("<p class='a'>ç</p>\n", "html"), ("+é\n-ü\n", "diff")] {
            let colored = try #require(CodeHighlight.attributed(code, language: language))
            #expect(String(colored.characters) == code)
            #expect(colored.runs.contains { $0.foregroundColor != nil })
        }
    }

    @Test func aSearchMarksColoredCodeAndKeepsItsColors() throws {
        let colored = try #require(CodeHighlight.attributed("let taxa = 1", language: "swift"))
        let marked = FindMarking.marked(colored, query: "TAXA")
        #expect(String(marked.characters) == "let taxa = 1")
        #expect(marked.runs.contains { $0.backgroundColor != nil })
        #expect(marked.runs.contains { $0.foregroundColor != nil })
    }

    @Test func whatHasNoColorsStaysPlain() {
        #expect(CodeHighlight.attributed("x", language: "cobol") == nil)
        #expect(!CodeHighlight.colors("cobol"))
        #expect(CodeHighlight.colors("TypeScript"))
        #expect(CodeHighlight.attributed("nada", language: "swift") == nil)
        #expect(CodeHighlight.attributed("let a\n" + String(repeating: "x", count: CodeHighlight.maxBytes), language: "swift") == nil)
    }

    @Test func aChangeColorsItsLinesButNotItsPath() {
        let detail = "+ estranho/a.swift\nTodas as ocorrências\n- velho\n+ novo\n"
        let colored = EditDiff.colored(detail)
        #expect(String(colored.characters) == detail)
        let painted = colored.runs.filter { $0.foregroundColor != nil }.map { String(colored[$0.range].characters) }
        #expect(painted == ["- velho", "+ novo"])
    }

    @MainActor @Test func coloredCodeIsKeptForTheRowThatComesBack() throws {
        let code = "let só = \(UUID().uuidString.count)"
        let colors = try #require(CodeHighlight.attributed(code, language: "swift"))
        #expect(MarkdownCache.colored(code, language: "swift") == nil)
        MarkdownCache.remember(colored: colors, of: code, language: "swift")
        #expect(MarkdownCache.colored(code, language: "swift") == colors)
        #expect(MarkdownCache.colored(code, language: "python") == nil)
    }

    @Test func aLongBlockIsColoredQuickly() {
        let line = "    let total = valores.map { $0 * 2 }.reduce(0, +) // soma \"final\"\n"
        let code = String(repeating: line, count: CodeHighlight.maxBytes / line.utf8.count)
        let start = ContinuousClock.now
        #expect(CodeHighlight.attributed(code, language: "swift") != nil)
        print("CodeHighlight: \(code.utf8.count) bytes em \(ContinuousClock.now - start)")
    }
}

/// What a table's buttons copy.
@Suite("Copiar tabela") struct TableExportTests {
    private let table = MarkdownTable(header: ["Plano", "Taxa"], rows: [["**Pro**", "a | b"], ["x, y", "diz \"oi\""]],
                                      alignments: [.leading, .trailing])

    @Test func markdownReadsBackAsTheSameTable() {
        #expect(table.markdown == "| Plano | Taxa |\n| --- | ---: |\n| **Pro** | a \\| b |\n| x, y | diz \"oi\" |")
        #expect(MarkdownBlocks.parse(table.markdown) == [.table(table)])
    }

    @Test func csvQuotesWhatNeedsQuotes() {
        #expect(table.csv { $0 } == "Plano,Taxa\r\n**Pro**,a | b\r\n\"x, y\",\"diz \"\"oi\"\"\"")
    }

    @Test func csvTakesTheTextAsShown() {
        #expect(table.csv { $0.replacingOccurrences(of: "*", with: "") }.contains("\r\nPro,"))
    }

    @Test func csvStopsWhatStartsWithASign() {
        let risky = MarkdownTable(header: ["a"], rows: [["+cmd|' /C calc'!A0"], ["-2+3"], ["-1,5"], ["\u{9}=1"], ["=\u{301}1"], [",\u{301}"]], alignments: [.leading])
        let lines = risky.csv { $0 }.components(separatedBy: "\r\n")
        #expect(lines[1] == "'+cmd|' /C calc'!A0" && lines[2] == "'-2+3" && lines[3] == "\"-1,5\"")
        #expect(lines[4].hasPrefix("'") && lines[5].hasPrefix("'") && lines[6].hasPrefix("\""))
    }

    @Test func csvNeverHandsASpreadsheetAFormula() {
        let risky = MarkdownTable(header: ["a"], rows: [["=HYPERLINK(\"x\")"], ["@SUM(1)"], ["-5"], ["+55"]], alignments: [.leading])
        #expect(risky.csv { $0 } == "a\r\n\"'=HYPERLINK(\"\"x\"\")\"\r\n'@SUM(1)\r\n-5\r\n+55")
    }
}

/// The count on the way back to the end of the chat.
@Suite("Voltar ao fim") struct JumpToEndTests {
    private func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
    private func tool() -> TranscriptItem {
        TranscriptItem(.tool(ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls", state: .done, output: "ok")))
    }

    @Test func countsOnlyTheRepliesAfterTheLastItemSeen() {
        let seen = bot("a")
        #expect(JumpToEnd.arrived(in: [bot("0"), seen, tool(), bot("b"), tool(), bot("c")], after: seen.id) == 2)
        #expect(JumpToEnd.arrived(in: [seen], after: seen.id) == 0)
    }

    @Test func noPlaceToCountFromCountsNothing() {
        #expect(JumpToEnd.arrived(in: [bot("a")], after: UUID()) == 0)
        #expect(JumpToEnd.arrived(in: [bot("a")], after: nil) == 0)
    }
}

@Suite("Cores do código: casos da revisão")
struct CodeHighlightReviewTests {
    private func kind(of word: String, in code: String, _ language: String) -> CodeSpan.Kind? {
        let bytes = Array(code.utf8), target = Array(word.utf8)
        guard let start = bytes.indices.first(where: { bytes[$0...].starts(with: target) }) else { return nil }
        return CodeHighlight.spans(code, language: language).first { $0.start <= start && start < $0.end }?.kind
    }

    @Test func pythonPrefixesOpenStrings() {
        #expect(kind(of: "Total", in: "print(f'Total: {n} itens')", "python") == .string)
        #expect(kind(of: "x", in: "rb'x'", "python") == .string)
        #expect(kind(of: "t", in: "don't = 1", "python") != .string)
    }

    @Test func shellQuotesCrossLines() {
        #expect(kind(of: "b", in: "curl -d 'a\nb\nc'", "bash") == .string)
    }

    @Test func aRemovedDashLineIsNotAHeader() {
        let diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n--- nota\n+++ nova"
        #expect(kind(of: "--- a/x", in: diff, "diff") == .keyword)
        #expect(kind(of: "--- nota", in: diff, "diff") == .removed)
        #expect(kind(of: "+++ nova", in: diff, "diff") == .added)
    }

    @Test func aMemberIsNotAKeyword() {
        #expect(kind(of: "type", in: "obj.type = 1", "js") == nil)
        #expect(kind(of: "type", in: "type X = 1", "ts") == .keyword)
    }

    @Test func textIsNotATag() {
        #expect(kind(of: "t", in: "<p>x <5 e don't</p>", "html") == nil)
    }

    @Test func aJSONKeyMayHaveASpaceBeforeItsColon() {
        #expect(kind(of: "\"a\"", in: "{ \"a\" : 1 }", "json") == .keyword)
    }
}
