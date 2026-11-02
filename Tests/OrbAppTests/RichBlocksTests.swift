import Foundation
import WebKit
import Testing
@testable import Orb

@Suite("Blocos ricos: leitura")
struct RichBlockParsingTests {
    private func one(_ text: String) -> MarkdownBlock? {
        let blocks = MarkdownBlocks.parse(text)
        return blocks.count == 1 ? blocks[0] : nil
    }

    @Test func aClosedChartFenceIsAChart() throws {
        let source = #"{"type":"bar","labels":["A","B"],"series":[{"name":"x","values":[1,2]}]}"#
        guard case .chart(let spec, let kept) = one("```chart\n\(source)\n```") else { Issue.record("not a chart"); return }
        #expect(spec.kind == .bar && spec.labels == ["A", "B"] && kept == source)
    }

    @Test func anOpenFenceStaysCodeUntilItCloses() {
        #expect(ChartSpec.parse(#"{"type":"line","labels":["a"],"series":[{"values":[1]},{"values":[2]},{"name":"Meta","values":[3]}]}"#)?
            .series.map(\.name) == ["Série 1", "Série 2", "Meta"])
        #expect(ChartSpec.parse(#"{"type":"bar","labels":["a"],"values":[1]}"#)?.series.first?.name == "")
        guard case .code(let language, _, false) = one("```chart\n{\"type\":\"bar\"") else { Issue.record("not code"); return }
        #expect(language == "chart")
        guard case .code = one("```mermaid\ngraph TD") else { Issue.record("not code"); return }
    }

    @Test(arguments: [
        "not json", #"{"type":"radar","labels":["A"],"values":[1]}"#, #"{"type":"bar","labels":[],"values":[]}"#,
        #"{"type":"bar","labels":["A","B"],"values":[1]}"#, #"{"type":"bar","labels":["A","A"],"values":[1,2]}"#,
        #"{"type":"bar","labels":["A"],"values":["1"]}"#, #"{"type":"bar","labels":["A"],"values":[true]}"#,
        #"{"type":"pie","labels":["A","B"],"values":[-1,2]}"#, #"{"type":"pie","labels":["A"],"values":[0]}"#,
        #"{"type":"pie","labels":["A"],"series":[{"name":"x","values":[1]},{"name":"y","values":[1]}]}"#,
        #"{"type":"line","labels":["A"],"series":[{"name":"x","values":[1]},{"name":"x","values":[2]}]}"#,
    ]) func whatIsNotAChartStaysCode(json: String) {
        guard case .code(let language, let code, true) = one("```chart\n\(json)\n```") else { Issue.record("not code"); return }
        #expect(language == "chart" && code == json)
    }

    @Test func aChartAcceptsOneSeriesAndGaps() throws {
        let spec = try #require(ChartSpec.parse(#"{"type":"line","title":"  ","labels":["A","B",3],"values":[1,null,2.5]}"#))
        #expect(spec.title == nil && spec.labels == ["A", "B", "3"] && spec.series[0].values == [1, nil, 2.5])
        #expect(spec.speech.contains("A, 1") && spec.speech.contains("3, 2,5") || spec.speech.contains("3, 2.5"))
    }

    @Test func tooMuchDataStaysCode() {
        let labels = (0...ChartSpec.maxLabels).map { "\"\($0)\"" }.joined(separator: ",")
        let values = (0...ChartSpec.maxLabels).map(String.init).joined(separator: ",")
        #expect(ChartSpec.parse(#"{"type":"bar","labels":[\#(labels)],"values":[\#(values)]}"#) == nil)
    }

    @Test func diagramAndMathFences() {
        guard case .diagram("graph TD") = one("```mermaid\ngraph TD\n```") else { Issue.record("no diagram"); return }
        guard case .math("x^2") = one("```math\nx^2\n```") else { Issue.record("no math"); return }
        guard case .page("<b>x</b>") = one("```page\n<b>x</b>\n```") else { Issue.record("no page"); return }
    }

    @Test func aHugeDiagramStaysCode() {
        let source = String(repeating: "a", count: MarkdownBlocks.richSourceLimit + 1)
        guard case .code = one("```mermaid\n\(source)\n```") else { Issue.record("not code"); return }
    }

    @Test func blockMath() {
        guard case .math("E = mc^2") = one("$$E = mc^2$$") else { Issue.record("one line"); return }
        guard case .math("a\nb") = one("$$\na\nb\n$$") else { Issue.record("two lines"); return }
    }

    @Test(arguments: ["Custa $5 ou $10", "$$", "$$ sem fim", "$$\nnunca fecha", "de $$5 a $$6", "$$5 e $$6$$", "US$ 10 e R$ 20"])
    func dollarsAreNotMath(text: String) {
        #expect(!MarkdownBlocks.parse(text).contains { if case .math = $0 { true } else { false } })
    }

    @Test func mathEndsTheParagraphAboveIt() {
        let blocks = MarkdownBlocks.parse("Veja:\n$$x$$\ndepois")
        #expect(blocks.count == 3)
    }

    @Test func aCopyGivesTheSource() {
        #expect(MarkdownBlocks.plainText(of: "```mermaid\ngraph TD\n```") == "graph TD")
        #expect(MarkdownBlocks.plainText(of: "$$x$$") == "x")
    }

    @Test func richBlocksAreNeverProse() {
        for block: MarkdownBlock in [.diagram(source: "x"), .math(tex: "x"), .page(html: "x")] { #expect(!ProseSegment.isProse(block)) }
    }
}

@Suite("Código recolhido")
struct CodeFoldTests {
    private func code(_ lines: Int) -> String { (1...lines).map(String.init).joined(separator: "\n") }

    @Test func shortCodeStaysWhole() {
        #expect(CodeBlockView.head(of: code(CodeBlockView.foldLines)) == nil)
        #expect(CodeBlockView.head(of: "") == nil)
    }

    @Test func longCodeFoldsAtALineEnd() throws {
        let head = try #require(CodeBlockView.head(of: code(100)))
        #expect(head.text == code(CodeBlockView.headLines) && head.hiddenLines == 100 - CodeBlockView.headLines)
    }

    @Test func accentsDoNotShiftTheCut() throws {
        let text = (1...60).map { "ação \($0)" }.joined(separator: "\n")
        #expect(try #require(CodeBlockView.head(of: text)).text.hasSuffix("ação 24"))
    }
}

@Suite("Caminhos na resposta")
struct PathLinkTests {
    private func paths(_ text: String) -> [String] { PathLinks.candidates(in: text, isCode: false).map(\.path) }

    @Test func aPathAmongWords() {
        #expect(paths("Salvei em /Users/voce/nota.md, confira.") == ["/Users/voce/nota.md"])
        #expect(paths("(veja /tmp/a/b.txt)") == ["/tmp/a/b.txt"])
        #expect(paths("--saida=/tmp/a/b") == ["/tmp/a/b"])
    }

    @Test func aTildeIsExpanded() {
        #expect(paths("em ~/Documentos/a.txt") == [NSString(string: "~/Documentos/a.txt").expandingTildeInPath])
    }

    @Test(arguments: ["e/ou", "1/2", "src/app/main.swift", "https://exemplo.com/a/b", "//host/a/b", "/tmp", "/", "~30", "a /../../etc", "http:/x/y"])
    func whatIsNotAPath(text: String) {
        #expect(paths(text).isEmpty)
    }

    @Test(arguments: ["shortcuts://run-shortcut?name=x", "ssh://a", "smb://a/b", "x-apple.systempreferences:com.apple", "javascript:alert(1)", "tel:1"])
    func aReplyOpensNoOtherScheme(address: String) throws {
        #expect(!PathLinks.opensOutside(try #require(URL(string: address))))
    }

    @Test func aReplyOpensWebAndMail() throws {
        for address in ["https://a.com", "HTTP://a.com", "mailto:a@b.com"] { #expect(PathLinks.opensOutside(try #require(URL(string: address)))) }
    }

    @MainActor @Test func linksArriveWithoutTouchingASelection() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orb-link-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = NSTextView()
        view.string = "Salvei em \(file.path) agora"
        view.setSelectedRange(NSRange(location: 2, length: 4))
        let storage = try #require(view.textStorage)
        #expect(await PathLinks.check(PathLinks.unknown(in: storage)))
        PathLinks.link(storage)
        #expect(view.selectedRange() == NSRange(location: 2, length: 4))
        #expect(storage.attribute(.link, at: 12, effectiveRange: nil) != nil)
    }

    @Test func codeIsThePathWithItsSpaces() {
        let found = PathLinks.candidates(in: "/Users/voce/Meus Documentos/a b.pdf", isCode: true)
        #expect(found.map(\.path) == ["/Users/voce/Meus Documentos/a b.pdf"])
        #expect(PathLinks.candidates(in: "ls /tmp/a", isCode: true).isEmpty)
    }

    @Test func theRangeIsThePathAlone() throws {
        let text = "em /tmp/a/b.txt."
        let found = try #require(PathLinks.candidates(in: text, isCode: false).first)
        #expect(text[found.range] == "/tmp/a/b.txt")
    }
}

@MainActor @Suite("Conversa: Novas, pedidos e rastro do turno")
struct TranscriptExtrasTests {
    private func user(_ text: String) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }
    private func bot(_ text: String, streaming: Bool = false) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: streaming)) }
    private func tool(_ kind: ToolCall.Kind, _ title: String, _ detail: String, _ state: ToolCall.State = .done) -> TranscriptItem {
        TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: state)))
    }

    @Test func theLineGoesAboveWhatCameWhileAway() {
        let seen = user("oi"), reply = bot("olá"), later = bot("mais")
        let transcript = OrbTranscript(items: [seen])
        transcript.readerLeft()
        transcript.show([seen, reply, later])
        transcript.readerReturned(unread: 1)
        #expect(transcript.newFrom == reply.id)
        transcript.readerLeft()
        #expect(transcript.newFrom == nil)
    }

    @Test func nothingUnreadNoLine() {
        let seen = user("oi")
        let transcript = OrbTranscript(items: [seen])
        transcript.readerLeft()
        transcript.show([seen, bot("olá")])
        transcript.readerReturned(unread: 0)
        #expect(transcript.newFrom == nil)
    }

    @Test func aConversationReadFromDiskIsMarkedWhenItArrives() {
        let seen = user("oi"), reply = bot("olá")
        let transcript = OrbTranscript(items: [seen])
        transcript.readerLeft()
        transcript.show([])
        transcript.readerReturned(unread: 1)
        #expect(transcript.newFrom == nil)
        transcript.show([seen, reply])
        #expect(transcript.newFrom == reply.id)
    }

    @Test func anotherConversationDropsTheMark() {
        let seen = user("oi")
        let transcript = OrbTranscript(items: [seen, bot("olá")])
        transcript.readerLeft()
        transcript.swapped()
        transcript.readerReturned(unread: 1)
        #expect(transcript.newFrom == nil)
    }

    @Test func aSecondLeavingKeepsWhereTheReaderStopped() {
        let seen = user("oi"), reply = bot("olá")
        let transcript = OrbTranscript(items: [seen])
        transcript.readerLeft()
        transcript.show([seen, reply])
        transcript.readerLeft() // the app in the back, then a notification selects another Orb
        transcript.readerReturned(unread: 1)
        #expect(transcript.newFrom == reply.id)
    }

    @Test func aReplyBeingWrittenWhenTheReaderLeftIsNew() {
        let seen = user("oi"), writing = bot("ol", streaming: true)
        let transcript = OrbTranscript(items: [seen, writing])
        transcript.readerLeft()
        transcript.show([seen, bot("olá")])
        transcript.readerReturned(unread: 1)
        #expect(transcript.newFrom != nil)
    }

    @Test func aBlankStartAndAHugeMessageGiveOneLine() {
        #expect(RequestMark.of([user("\n\nTítulo\nresto")]).first?.title == "Título")
        #expect(RequestMark.of([user(String(repeating: "a", count: 500))]).first?.title.count == 160)
        #expect(RequestMark.of([user("\n")]).first?.title == "Mensagem")
    }

    @Test func aWordAlongTheWayIsNotTheReplyOfATurnStillRunning() {
        let items = [user("x"), tool(.browser, "Lendo página", "https://a.com"), bot("já volto")]
        #expect(TurnTrail.of(items, isLive: true).isEmpty)
        #expect(TurnTrail.of(items).count == 1)
    }

    @Test func theRailHasAMarkPerMessage() {
        let first = user("Primeira linha\nsegunda")
        let marks = RequestMark.of([first, bot("x"), user("outra")])
        #expect(marks.map(\.title) == ["Primeira linha", "outra"] && marks[0].id == first.id)
    }

    @Test func aLongRailKeepsTheEnds() {
        let marks = (0..<100).map { RequestMark(id: UUID(), title: "\($0)") }
        let thin = RequestMark.thinned(marks, limit: 10)
        #expect(thin.count == 10 && thin.first == marks.first && thin.last == marks.last && Set(thin.map(\.id)).count == 10)
        #expect(RequestMark.thinned(Array(marks.prefix(5)), limit: 10).count == 5)
    }

    @Test func aTurnKeepsWhatItReadAndChanged() {
        let reply = bot("feito")
        let trails = TurnTrail.of([user("x"), tool(.browser, "Lendo página", "https://a.com/1"), tool(.browser, "Lendo página", "https://a.com/1"),
                                   tool(.browser, "Lendo página", "file:///etc/passwd"), tool(.browser, "Lendo página", "https://b.com", .failed),
                                   tool(.schedule, "Agendando tarefa", "“Conferir” · diário · 9h"),
                                   tool(.memory, "Guardando na memória (fato)", "Prefere PDF"), bot("meio"), reply, user("y"), bot("sem nada")])
        #expect(trails.count == 1)
        #expect(trails[reply.id]?.sources == ["https://a.com/1"])
        #expect(trails[reply.id]?.changes == [.routine("Conferir"), .memory("Prefere PDF")])
    }

    @Test func aReplyBeingWrittenWaitsForItsEnd() {
        #expect(TurnTrail.of([tool(.browser, "Lendo página", "https://a.com"), bot("…", streaming: true)]).isEmpty)
    }

    @Test func onlyWebAddressesHaveAHost() {
        #expect(TurnTrail.host(of: "https://www.exemplo.com/a") == "exemplo.com")
        #expect(TurnTrail.host(of: "javascript:alert(1)") == nil)
        #expect(TurnTrail.host(of: "file:///etc/passwd") == nil)
    }
}

@Suite("ask_user: várias respostas e formulário")
struct AskUserRichTests {
    @Test func picksGoInTheirOrderWithOwnWords() {
        let question = OrbQuestion(text: "?", options: ["A", "B", "C"], multiple: true)
        #expect(question.composed(picked: ["C", "A"], reply: " outra ") == "A; C; outra")
        #expect(question.composed() == nil)
    }

    @Test func returnWalksTheFormToItsLastFieldToWrite() {
        let question = OrbQuestion(text: "?", fields: [OrbQuestion.Field(label: "Nome"), OrbQuestion.Field(label: "Cor", options: ["a"]),
                                                       OrbQuestion.Field(label: "Data")])
        #expect(question.textField(after: 0) == 2)
        #expect(question.textField(after: 2) == nil)
    }

    @Test func multipleNeedsOptions() {
        #expect(!OrbQuestion(text: "?", options: ["A"], multiple: true).multiple)
        #expect(!OrbQuestion(text: "?", multiple: true).multiple)
    }

    @Test func aFormAnswersByLine() {
        let question = OrbQuestion(text: "?", fields: [.init(label: "Nome"), .init(label: "Formato", options: ["PDF"]), .init(label: "Vazio")])
        #expect(question.composed(values: ["Ana", "PDF", " "]) == "Nome: Ana\nFormato: PDF")
        #expect(question.composed(values: ["", "", ""]) == nil)
        #expect(question.composed(values: ["", "", ""], reply: "tanto faz") == "tanto faz")
    }

    @Test func fieldsAreCleanedAndCapped() {
        let fields = (0..<10).map { OrbQuestion.Field(label: "c\($0)") } + [.init(label: "  ")]
        let question = OrbQuestion(text: "?", options: ["A", "B"], multiple: true, fields: fields)
        #expect(question.fields.count == OrbQuestion.fieldLimit && question.options.isEmpty && !question.multiple)
    }

    @Test func anOldQuestionStillReads() throws {
        let data = Data(#"{"text":"?","options":["A"],"answer":"A"}"#.utf8)
        let question = try JSONDecoder().decode(OrbQuestion.self, from: data)
        #expect(question.text == "?" && question.answer == "A" && question.fields.isEmpty && !question.multiple)
    }

    @Test func aFullQuestionRoundTrips() throws {
        let question = OrbQuestion(text: "?", fields: [.init(label: "L", options: ["x"])])
        #expect(try JSONDecoder().decode(OrbQuestion.self, from: JSONEncoder().encode(question)) == question)
    }

    @Test func theToolReadsTheForm() async throws {
        let tool = AskUserTool()
        let box = QuestionBox()
        var context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        context.askUser = { question in await box.keep(question); return "ok" }
        let arguments = JSONValue.parse(#"{"question":"?","fields":[{"label":"Nome"},{"label":"Tipo","options":["a","b"]}]}"#)!
        #expect(try await tool.run(arguments, context: context) == "The user answered: ok")
        #expect(await box.question?.fields.map(\.label) == ["Nome", "Tipo"])
    }

    private actor QuestionBox {
        var question: OrbQuestion?
        func keep(_ question: OrbQuestion) { self.question = question }
    }
}

@Suite("Pergunta lateral")
struct SideQuestionTests {
    @Test func onlyWordsGoIntoThePrompt() {
        let messages = SideQuestion.prompt("Qual o total?", context: [ChatMessage(role: .user, content: "oi"), ChatMessage(role: .assistant, content: "olá"),
                                                                       ChatMessage(role: .tool, content: "SEGREDO DA FERRAMENTA")])
        #expect(messages.count == 2 && messages[0].role == .system)
        #expect(messages[1].content.contains("Person: oi") && messages[1].content.contains("Assistant: olá"))
        #expect(!messages[1].content.contains("SEGREDO") && messages[1].content.hasSuffix("Question: Qual o total?"))
    }

    private struct Tokens: LLMClient {
        let count: Int
        var failure: Error?

        func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
            AsyncThrowingStream { continuation in
                for _ in 0..<count { continuation.yield(.text("a")) }
                continuation.finish(throwing: failure)
            }
        }
    }

    @MainActor private final class Shown { var texts: [String] = [] }

    @MainActor @Test func aLongAnswerIsNotShownPerTokenAndEndsWhole() async {
        let shown = Shown()
        _ = await SideQuestion.ask("?", context: [], client: Tokens(count: 2_000), model: "m") { shown.texts.append($0) }
        #expect(shown.texts.last?.count == 2_000)
        #expect(shown.texts.count < 200)
    }

    @MainActor @Test func whatArrivedBeforeAFailureStays() async {
        struct Broke: Error {}
        let shown = Shown()
        _ = await SideQuestion.ask("?", context: [], client: Tokens(count: 50, failure: Broke()), model: "m") { shown.texts.append($0) }
        #expect(shown.texts.last?.count == 50)
    }
}

@Suite("Desenho local")
struct RichRendererUnitTests {
    @Test func theKeyFollowsWhatIsDrawn() {
        let math = RichRequest(kind: .math, source: "x")
        #expect(math.key == RichRequest(kind: .math, source: "x").key)
        #expect(math.key != RichRequest(kind: .diagram, source: "x").key && math.key != RichRequest(kind: .math, source: "y").key)
    }

    @Test func theFolderIsTrimmedOldestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rich-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["a", "b", "c"].enumerated() {
            let file = folder.appending(path: name)
            try Data(repeating: 1, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 1000)], ofItemAtPath: file.path)
        }
        RichDisk.trim(limit: 200, folder: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["b", "c"])
    }

    @Test func thePolicyComesFirstAndClosesTheNetwork() {
        let page = PageSandbox.document("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\">", scripts: true)
        let policy = try! #require(page.range(of: "default-src 'none'"))
        #expect(policy.lowerBound < page.range(of: "default-src *")!.lowerBound)
        #expect(!PageSandbox.policy(scripts: false).contains("script-src"))
        #expect(PageSandbox.policy(scripts: true).contains("script-src 'unsafe-inline'"))
        #expect(!PageSandbox.policy(scripts: true).contains("connect-src"))
    }

    @Test func theResourcesAreThere() throws {
        let folder = try #require(RichRenderer.resources)
        for name in ["render.html", "render.js", "mermaid.min.js", "katex.min.js", "katex.min.css", "fonts/KaTeX_Main-Regular.woff2"] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
        }
    }
}

/// Real WebKit, so only on request: `ORB_RICH_RENDER_TESTS=1`. What a page written by a model tries, against the actual sandbox.
@MainActor @Suite("Sandbox de páginas", .enabled(if: ProcessInfo.processInfo.environment["ORB_RICH_RENDER_TESTS"] == "1"))
struct PageSandboxLiveTests {
    private func page(_ body: String, scripts: Bool = true) async throws -> WKWebView {
        let view = try #require(await PageSandbox.makeView(javaScript: scripts))
        let loaded = await PageSandbox.load(view, deadline: .seconds(10)) { view.loadHTMLString(PageSandbox.document(body, scripts: scripts), baseURL: nil) }
        #expect(loaded)
        return view
    }

    private func read(_ view: WKWebView, _ script: String) async throws -> String {
        String(describing: try await view.callAsyncJavaScript(script, contentWorld: .page) ?? "nil")
    }

    @Test func aStaticPageRunsNoScript() async throws {
        let view = try await page(#"<div id="a">antes</div><script>document.getElementById("a").textContent = "rodou"</script>"#, scripts: false)
        #expect(try await read(view, #"return document.getElementById("a").textContent"#) == "antes")
    }

    @Test func aLivePageRuns() async throws {
        let view = try await page(#"<div id="a"></div><script>document.getElementById("a").textContent = "rodou"</script>"#)
        #expect(try await read(view, #"return document.getElementById("a").textContent"#) == "rodou")
    }

    @Test func theNetworkTiesAreCut() async throws {
        let view = try await page("<p>x</p>")
        for name in ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "RTCPeerConnection", "webkitRTCPeerConnection", "Worker", "SharedWorker"] {
            #expect(try await read(view, "return typeof window.\(name)") == "undefined", "\(name)")
        }
        #expect(try await read(view, "return typeof navigator.sendBeacon") == "undefined")
        #expect(try await read(view, "return typeof navigator.clipboard") == "undefined")
        #expect(try await read(view, #"return String(document.execCommand("copy"))"#) == "false")
    }

    @Test func aFreshFrameDoesNotBringThemBack() async throws {
        let view = try await page("<p>x</p>")
        let script = """
        const frame = document.createElement("iframe");
        document.body.append(frame);
        await new Promise((resolve) => setTimeout(resolve, 100));
        const other = frame.contentWindow;
        if (!other) return "none";
        return ["fetch", "XMLHttpRequest", "WebSocket", "RTCPeerConnection"].map((name) => { try { return typeof other[name]; } catch { return "blocked"; } }).join(",");
        """
        let types = try await read(view, script)
        #expect(!types.contains("function"), "\(types)")
    }

    @Test func nothingIsKept() async throws {
        let view = try await page("<p>x</p>")
        #expect(view.configuration.websiteDataStore.isPersistent == false)
        let stored = try await read(view, #"try { document.cookie = "a=1"; return document.cookie; } catch { return "blocked"; }"#)
        #expect(!stored.contains("a=1"))
    }

    @Test func aPageCannotLeave() async throws {
        let view = try await page("<p>x</p>")
        _ = try await read(view, #"location.href = "https://example.com/"; return 1"#)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.url?.scheme != "https")
    }

    @Test func aPageCanOnlyPropose() async throws {
        final class Inbox: NSObject, WKScriptMessageHandler {
            var received: [String] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let text = message.body as? String { received.append(text) }
            }
        }
        let inbox = Inbox()
        let view = try #require(await PageSandbox.makeView(javaScript: true, messages: inbox))
        #expect(await PageSandbox.load(view, deadline: .seconds(10)) {
            view.loadHTMLString(PageSandbox.document("<p>x</p>", scripts: true), baseURL: nil)
        })
        _ = try await read(view, #"orb.propose("a".repeat(5000)); return 1"#)
        try await waitUntil { !inbox.received.isEmpty }
        #expect(inbox.received[0].count == PageSandbox.proposalLimit)
        #expect(try await read(view, #"try { orb.propose = null; window.orb = 1; return typeof orb.propose; } catch { return "function"; }"#) == "function")
    }

    @Test func aPagePictureIsAsTallAsItsContent() async throws {
        guard case .image(let png, let size) = await PageSandbox.draw(html: "<p>curta</p>") else {
            Issue.record("no picture")
            return
        }
        #expect(size.height < 120 && !png.isEmpty)
    }

    @Test func diagramsAndFormulasDraw() async {
        RichRenderer.shared.forget()
        guard case .image = await RichRenderer.shared.draw(RichRequest(kind: .math, source: "x^\(UUID().uuidString.prefix(4).filter(\.isNumber).count)")) else {
            Issue.record("no formula")
            return
        }
        guard case .failed = await RichRenderer.shared.draw(RichRequest(kind: .diagram, source: "flowchart TD\n A --> B[\(UUID())")) else {
            Issue.record("should fail")
            return
        }
    }
}
