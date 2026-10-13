import AppKit
import Foundation
import Testing
@testable import Orb

/// How attachments are laid out and described in the chat (`AttachmentInfo`, `AttachmentLayout`), what the Orb reports
/// of the files it makes (`ProducedFile`) and how the transcript keeps them.
final class AttachmentPresentationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbAttachments-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func file(_ name: String, bytes: Int = 0) throws -> String {
        let url = root.appending(path: name)
        try Data(count: bytes).write(to: url)
        return url.path
    }

    // MARK: Screen steps

    @Test func capturesOfARunBecomeStepsNamedByWhatTheyShow() {
        func call(_ title: String, _ detail: String, _ picture: String? = nil, _ state: ToolCall.State = .done) -> ToolCall {
            ToolCall(kind: .browser, title: title, detail: detail, state: state, output: "ok",
                     files: picture.map { [ProducedFile(path: "/x/\($0).png", created: true)] })
        }
        let calls = [call("Abrindo a página", "loja.com"), call("Capturando a página", "", "a"),
                     call("Clicando", "Comprar"), call("Capturando a página", "", "b"),
                     call("Capturando a janela", "Safari", "c"), call("Capturando a página", "", "d", .failed),
                     // A chart a command drew is a result, not a step.
                     ToolCall(kind: .shell, title: "Executando", detail: "python plot.py", state: .done, output: "ok",
                              files: [ProducedFile(path: "/x/grafico.png", created: true)]),
                     call("Gravando arquivo", "/x/notas.md")]
        let steps = ScreenStepsStrip.steps(of: calls)
        #expect(steps?.map(\.path) == ["/x/a.png", "/x/b.png", "/x/c.png"])
        // The action before a capture names it, once; a capture that names its window keeps that.
        #expect(steps?.map(\.caption) == ["loja.com", "Comprar", "Safari"])
        // One capture stays the thumbnail of its own line.
        #expect(ScreenStepsStrip.steps(of: Array(calls.prefix(2))) == nil)
    }

    // MARK: Layout

    @Test func picturesAndFilesAreToldApart() {
        let split = AttachmentLayout.split(["/Users/x/foto.PNG", "/Users/x/relatório.pdf", "foto-antiga.png", "/Users/x/b.jpg"])
        #expect(split.images == ["/Users/x/foto.PNG", "/Users/x/b.jpg"])
        // A name without a path (older conversations) cannot be shown as a picture.
        #expect(split.files == ["/Users/x/relatório.pdf", "foto-antiga.png"])
        let none = AttachmentLayout.split([])
        #expect(none.images.isEmpty && none.files.isEmpty)
    }

    @Test func theGridHasOneWidthForAnyNumberOfPictures() {
        #expect(AttachmentLayout.grid(count: 0).visible == 0)
        let one = AttachmentLayout.grid(count: 1)
        #expect(one.columns == 1 && one.cell == CGSize(width: 232, height: 160))
        let two = AttachmentLayout.grid(count: 2)
        #expect(two.columns == 2 && two.cell == CGSize(width: 114, height: 114))
        for count in 1...20 {
            let plan = AttachmentLayout.grid(count: count)
            let columns = CGFloat(min(plan.columns, plan.visible))
            #expect(columns * plan.cell.width + (columns - 1) * plan.spacing <= AttachmentLayout.gridWidth)
        }
        for count in 3...9 {
            let plan = AttachmentLayout.grid(count: count)
            #expect(plan.columns == 3 && plan.cell.width == 74 && plan.visible == count && plan.overflow == 0)
        }
        let many = AttachmentLayout.grid(count: 12)
        #expect(many.visible == 9 && many.overflow == 3)
    }

    // MARK: What a card says

    @Test func aCardKnowsItsTypeFromTheNameAlone() {
        let sheet = AttachmentInfo.quick(path: "/Users/x/orçamento.xlsx")
        #expect(sheet.name == "orçamento.xlsx" && sheet.ext == "XLSX" && sheet.symbol == "tablecells" && sheet.state == .ok)
        #expect(AttachmentInfo.quick(path: "/Users/x/a.pdf").ext == "PDF")
        #expect(AttachmentInfo.quick(path: "/Users/x/.gitignore").ext.isEmpty)
        #expect(AttachmentInfo.quick(path: "/Users/x/.gitignore").name == ".gitignore")
        // Older conversations kept the name only.
        #expect(AttachmentInfo.quick(path: "relatorio.pdf").state == .legacy)
    }

    @Test func theCaptionSaysTypeAndSizeOrWhyThereIsNothingToOpen() {
        var info = AttachmentInfo.quick(path: "/Users/x/a.pdf")
        #expect(info.caption == "PDF") // the size comes when the disk was looked at
        info.size = 2_100_000
        #expect(info.caption == "PDF · \(AttachmentKind.size(2_100_000) ?? "")")
        var bare = AttachmentInfo.quick(path: "/Users/x/Makefile")
        bare.size = 120
        #expect(bare.caption == AttachmentKind.size(120))
        info.state = .missing
        #expect(info.caption == "Arquivo não está mais aqui")
        #expect(AttachmentInfo.quick(path: "a.pdf").caption == "Anexo antigo · sem local salvo")
    }

    @Test func loadingReadsTheSizeAndNoticesWhatIsGone() async throws {
        let notes = try file("notas.txt", bytes: 12)
        let info = await AttachmentInfo.load(path: notes)
        #expect(info.state == .ok && info.size == 12 && info.caption == "TXT · \(AttachmentKind.size(12) ?? "")")
        #expect(AttachmentInfo.cachedOrQuick(notes) == info) // a row that comes back is born complete

        let gone = await AttachmentInfo.load(path: root.appending(path: "sumiu.docx").path)
        #expect(gone.state == .missing)
        // A folder where the file was is not the file.
        let folder = root.appending(path: "pasta.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await AttachmentInfo.load(path: folder.path).state == .missing)
        #expect(await AttachmentInfo.load(path: "antigo.pdf").state == .legacy)
    }

    @Test func voiceOverHearsNameTypeAndSizeOrTheProblem() {
        var info = AttachmentInfo.quick(path: "/Users/x/relatório.pdf")
        info.size = 2_100_000
        #expect(TranscriptSpeech.attachment(info) == "Anexo: relatório.pdf, PDF, \(AttachmentKind.size(2_100_000) ?? "")")
        info.state = .missing
        #expect(TranscriptSpeech.attachment(info) == "Anexo: relatório.pdf, arquivo ausente")
        #expect(TranscriptSpeech.attachment(.quick(path: "a.pdf")) == "Anexo: a.pdf, anexo antigo, sem local salvo")
        #expect(TranscriptSpeech.user(text: "oi", attachmentCount: 2) == "Você: oi, com 2 anexos")
    }

    // MARK: Thumbnails

    @Test func aThumbnailIsDecodedOnceAndAMissingPictureLeavesNothingInTheCache() async throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let path = root.appending(path: "vermelho.png").path
        try png.write(to: URL(fileURLWithPath: path))
        #expect(Thumbnails.cached(path: path, side: Thumbnails.gridSide) == nil)
        let decoded = await Thumbnails.image(at: path, side: Thumbnails.gridSide)
        #expect(decoded != nil)
        #expect(Thumbnails.cached(path: path, side: Thumbnails.gridSide) === decoded)

        let missing = root.appending(path: "sumiu.png").path
        #expect(await Thumbnails.image(at: missing, side: Thumbnails.gridSide) == nil)
        #expect(Thumbnails.cached(path: missing, side: Thumbnails.gridSide) == nil)
    }

    // MARK: Quick Look

    @Test func quickLookSkipsWhatIsGoneAndKeepsTheStartingPoint() throws {
        let paths = ["/a.png", "/gone.png", "/b.pdf", "antigo.txt", "/c.txt"]
        let exists: (String) -> Bool = { $0 != "/gone.png" }
        let list = QuickLookPreview.items(paths, at: 2, exists: exists)
        #expect(list.urls.map(\.path) == ["/a.png", "/b.pdf", "/c.txt"] && list.start == 1)
        // The one clicked is gone itself: the next one opens.
        #expect(QuickLookPreview.items(paths, at: 1, exists: exists).start == 1)
        #expect(QuickLookPreview.items(paths, at: 4, exists: exists).start == 2)
        #expect(QuickLookPreview.items(["/gone.png"], at: 0, exists: { _ in false }).urls.isEmpty)
    }

    @MainActor @Test func theQuickLookPanelAskingForAnOldIndexGetsTheNearestItem() throws {
        let preview = QuickLookPreview.shared
        preview.urls = [URL(fileURLWithPath: "/unico.png")]
        #expect(preview.numberOfPreviewItems(in: nil) == 1)
        // The panel was on the fifth item of another message when the list was swapped.
        #expect((preview.previewPanel(nil, previewItemAt: 4) as? NSURL)?.path == "/unico.png")
        #expect((preview.previewPanel(nil, previewItemAt: -1) as? NSURL)?.path == "/unico.png")
        preview.urls = []
        #expect(preview.previewPanel(nil, previewItemAt: 0) == nil)
    }

    // MARK: Files the Orb makes

    @Test func aToolCallWithoutFilesReadsAndWritesAsBefore() throws {
        let old = #"{"id":"6F1B0E30-0D6B-4E4B-9A55-0B7A2A3F2B10","kind":"file","title":"Lendo","detail":"a.txt","state":"done"}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(old.utf8))
        #expect(call.files == nil)
        // Conversations without files stay as they were on disk.
        #expect(!(String(data: try JSONEncoder().encode(call), encoding: .utf8) ?? "").contains("files"))

        var made = call
        made.files = [ProducedFile(path: "/Users/x/notas.md", created: true)]
        let again = try JSONDecoder().decode(ToolCall.self, from: try JSONEncoder().encode(made))
        #expect(again.files == made.files)
        // What cannot be read leaves the line without cards instead of failing the conversation.
        let broken = #"{"id":"6F1B0E30-0D6B-4E4B-9A55-0B7A2A3F2B10","kind":"file","title":"x","detail":"","state":"done","files":[{"nome":1}]}"#
        #expect(try JSONDecoder().decode(ToolCall.self, from: Data(broken.utf8)).files == nil)
    }

    @Test func aFileShowsUnderTheLastCallOfTheTurnThatTouchedIt() {
        func call(_ files: [ProducedFile]?) -> TranscriptItem {
            TranscriptItem(.tool(ToolCall(kind: .file, title: "Gravando arquivo", detail: "", state: .done, files: files)))
        }
        func files(_ item: TranscriptItem) -> [ProducedFile]? { if case .tool(let call) = item.kind { call.files } else { nil } }
        let notes = ProducedFile(path: "/p/notas.md", created: true)
        let other = ProducedFile(path: "/p/outro.md", created: false)
        var items = [TranscriptItem(.user(text: "antes", attachments: [])), call([ProducedFile(path: "/p/notas.md", created: false)]),
                     TranscriptItem(.user(text: "agora", attachments: [])), call([notes, other]), call(nil)]
        // Edited again later in this turn: the card moves to the new call and the file is still "novo".
        let taken = BotSession.takeOver([ProducedFile(path: "/p/notas.md", created: false)], in: &items)
        #expect(taken == [ProducedFile(path: "/p/notas.md", created: true)])
        #expect(files(items[3]) == [other])
        // A previous turn is not touched.
        #expect(files(items[1]) == [ProducedFile(path: "/p/notas.md", created: false)])
        // The call that held only that file loses the list altogether.
        var single = [call([notes])]
        _ = BotSession.takeOver([notes], in: &single)
        #expect(files(single[0]) == nil)
        #expect(BotSession.takeOver([], in: &single).isEmpty)
    }

    @MainActor @Test func theTranscriptKeepsTheFilesOfAFinishedCall() {
        let model = AppModel(store: Store(directory: root.appending(path: "dados")), runsBackgroundWork: false)
        let botID = model.bots[0].id
        _ = model.session(botID).beginTurn()
        var ids: [UUID] = []
        for created in [true, false] {
            let call = ToolCall(kind: .file, title: "Gravando arquivo", detail: "/p/a.md")
            ids.append(call.id)
            model.apply(.toolStarted(call), to: botID)
            model.apply(.toolFinished(id: call.id, state: .done, output: "ok", files: [ProducedFile(path: "/p/a.md", created: created)]), to: botID)
        }
        let calls = model.transcript(botID).compactMap { item -> ToolCall? in if case .tool(let call) = item.kind { call } else { nil } }
        #expect(calls.map(\.id) == ids)
        #expect(calls[0].files == nil)
        #expect(calls[1].files == [ProducedFile(path: "/p/a.md", created: true)])
    }

    // MARK: The engines report the files

    @Test func aWriteToANewFileReportsItCreatedAndAnEditReportsItChanged() async throws {
        let target = root.appending(path: "novo.md").path
        // Relative to the working directory: the report carries the full path.
        let created = try await finishedFiles(tool: WriteFileTool(), arguments: #"{"path":"novo.md","content":"oi"}"#)
        #expect(created == [ProducedFile(path: URL(fileURLWithPath: target).path, created: true)])
        let changed = try await finishedFiles(tool: EditFileTool(), arguments: #"{"path":"novo.md","old_text":"oi","new_text":"tchau"}"#)
        #expect(changed == [ProducedFile(path: URL(fileURLWithPath: target).path, created: false)])
        let rewritten = try await finishedFiles(tool: WriteFileTool(), arguments: #"{"path":"novo.md","content":"outra vez"}"#)
        #expect(rewritten.map(\.created) == [false])
        // A call that failed reports nothing.
        let failed = try await finishedFiles(tool: EditFileTool(), arguments: #"{"path":"nao-existe.md","old_text":"a","new_text":"b"}"#)
        #expect(failed.isEmpty)
    }

    /// Runs one tool call through the engine (no permission asked) and returns the files its `toolFinished` carried.
    private func finishedFiles(tool: some AgentTool, arguments: String) async throws -> [ProducedFile] {
        let client = OneCallLLM(call: ToolCallRequest(id: "c1", name: tool.spec.name, arguments: arguments))
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: .bypass)
        let request = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi", client: client, tools: [tool],
                                  context: ToolContext(workingDirectory: root),
                                  permissions: { PermissionState(mode: .bypass, rules: []) })
        var files: [ProducedFile] = []
        for await event in AgentEngine().run(request) {
            if case .toolFinished(_, .done, _, let produced) = event { files += produced }
        }
        return files
    }

}

/// A model that asks for one tool call and then answers.
private actor OneCallState {
    var calls = 0
    func next() -> Int { calls += 1; return calls }
}

private struct OneCallLLM: LLMClient {
    let call: ToolCallRequest
    let state = OneCallState()

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(await state.next() == 1 ? .toolCalls([call]) : .text("Pronto."))
                continuation.finish()
            }
        }
    }
}
