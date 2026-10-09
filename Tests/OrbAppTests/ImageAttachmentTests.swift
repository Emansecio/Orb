import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Orb

// Pictures in conversations: decoding and shrinking, the store, how each wire format carries them, which ones are
// kept in the window, and what happens with a model that cannot see.

// MARK: - Fixtures

/// Pictures built with Core Graphics, so no binary files live in the repository.
enum Pictures {
    /// An RGBA bitmap: opaque colour, or a transparent background with a coloured square, or random noise.
    enum Fill { case opaque, transparent, opaqueWithAlphaChannel, noise }

    static func image(width: Int, height: Int, fill: Fill = .opaque) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        switch fill {
        case .opaque, .opaqueWithAlphaChannel:
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .transparent:
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        case .noise:
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(context.bytesPerRow * height) { pixels[index] = index % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator) }
        }
        return try #require(context.makeImage())
    }

    static func data(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func data(width: Int, height: Int, as type: UTType = .png, fill: Fill = .opaque) throws -> Data {
        try data(try image(width: width, height: height, fill: fill), as: type)
    }

    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

/// A temporary folder removed when the test ends.
private final class Folder {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OrbImageTests-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A file of fake picture bytes and the attachment that points at it (the wire never looks inside).
    func attachment(_ name: String = "a.jpg", bytes: String = "bytes", mediaType: String = "image/jpeg") throws -> ImageAttachment {
        let file = url.appending(path: name)
        try Data(bytes.utf8).write(to: file)
        return ImageAttachment(path: file.path, mediaType: mediaType, width: 10, height: 10)
    }
}

// MARK: - Decoding and shrinking

struct ImageProcessingTests {
    @Test func aLargePictureIsScaledToTheLongSideLimitAsJPEG() throws {
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 3136, height: 1000), name: "grande.png")
        #expect(prepared.mediaType == "image/jpeg" && prepared.fileExtension == "jpg")
        #expect(prepared.width == 1568 && prepared.height == 500)
        let written = try #require(Pictures.size(of: prepared.data))
        #expect(written.width == 1568 && written.height == 500)
    }

    @Test func aTallPictureIsLimitedOnItsHeight() throws {
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 800, height: 4000), name: "alta.png")
        #expect(prepared.height == 1568 && prepared.width == 314)
    }

    @Test func aSmallPictureIsNotEnlarged() throws {
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 200, height: 100), name: "pequena.png")
        #expect(prepared.width == 200 && prepared.height == 100)
    }

    @Test func aSmallTransparentPictureStaysPNG() throws {
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 120, height: 80, fill: .transparent), name: "logo.png")
        #expect(prepared.mediaType == "image/png" && prepared.fileExtension == "png")
        #expect(Pictures.size(of: prepared.data)?.width == 120)
    }

    @Test func aPictureWithAnAlphaChannelButNoTransparencyBecomesJPEG() throws {
        // Screenshots usually carry an alpha channel that is all opaque.
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 300, height: 200, fill: .opaqueWithAlphaChannel), name: "tela.png")
        #expect(prepared.mediaType == "image/jpeg")
    }

    @Test func aLargeTransparentPictureBecomesJPEGOnWhite() throws {
        // Noise does not compress: the PNG is far over the keep limit. Half the pixels are made transparent below.
        let image = try Pictures.image(width: 900, height: 900, fill: .noise)
        let context = try #require(CGContext(data: nil, width: 900, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 900, height: 900))
        context.clear(CGRect(x: 0, y: 0, width: 900, height: 450))
        let data = try Pictures.data(try #require(context.makeImage()), as: .png)
        #expect(data.count > ImageProcessing.pngKeepLimit)
        let prepared = try ImageProcessing.prepare(data, name: "ruido.png")
        #expect(prepared.mediaType == "image/jpeg")
        #expect(prepared.width == 900)
    }

    @Test(arguments: [UTType.jpeg, .tiff, .gif, .png])
    func commonFormatsAreAccepted(type: UTType) throws {
        let prepared = try ImageProcessing.prepare(try Pictures.data(width: 64, height: 48, as: type), name: "x")
        #expect(prepared.width == 64 && prepared.height == 48)
    }

    @Test func heicIsAcceptedWhereTheSystemCanWriteIt() throws {
        let image = try Pictures.image(width: 64, height: 48)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        let prepared = try ImageProcessing.prepare(output as Data, name: "foto.heic")
        #expect(prepared.width == 64)
    }

    @Test func theExifOrientationIsApplied() throws {
        // 200×100 stored sideways (orientation 6 = rotate 90°): it is a 100×200 picture.
        let image = try Pictures.image(width: 200, height: 100)
        let data = try Pictures.data(image, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let prepared = try ImageProcessing.prepare(data, name: "foto.jpg")
        #expect(prepared.width == 100 && prepared.height == 200)
    }

    @Test func aFileOverTwentyMegabytesIsRefusedWithAClearMessage() throws {
        let data = Data(count: 21 * 1_048_576)
        let error = #expect(throws: ImageAttachmentError.self) { try ImageProcessing.prepare(data, name: "enorme.png") }
        let message = try #require(error?.errorDescription)
        #expect(message == "A imagem “enorme.png” tem 21 MB; o limite é 20 MB. Reduza a imagem e tente de novo.")
    }

    @Test func somethingThatIsNotAPictureIsRefused() {
        let error = #expect(throws: ImageAttachmentError.self) { try ImageProcessing.prepare(Data("texto".utf8), name: "nota.png") }
        #expect(error == .unreadable(name: "nota.png"))
        #expect(error?.errorDescription?.contains("nota.png") == true)
    }

    @Test func imageFilesAreToldFromOtherFilesByTheirType() {
        for name in ["a.png", "a.JPG", "a.jpeg", "a.heic", "a.gif", "a.tiff", "a.webp"] {
            #expect(ImageProcessing.isImageFile(URL(fileURLWithPath: "/tmp/" + name)), "\(name)")
        }
        for name in ["a.txt", "a.pdf", "a.svg", "a.mov", "a"] {
            #expect(!ImageProcessing.isImageFile(URL(fileURLWithPath: "/tmp/" + name)), "\(name)")
        }
    }
}

// MARK: - Store

struct ImageStoreTests {
    @Test func aPictureIsSavedUnderTheOrbsFolder() throws {
        let folder = Folder()
        let store = ImageStore(dataFolder: folder.url)
        let botID = UUID()
        let source = folder.url.appending(path: "foto.png")
        try Pictures.data(width: 3000, height: 1500).write(to: source)

        let image = try store.add(fileAt: source, botID: botID)
        #expect(image.path.hasPrefix(folder.url.appending(path: "anexos/\(botID.uuidString)/").path))
        #expect(image.path.hasSuffix(".jpg") && image.mediaType == "image/jpeg")
        #expect(image.width == 1568 && image.height == 784)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original is left alone")
    }

    @Test func aHugeFileIsRefusedBeforeItIsRead() throws {
        let folder = Folder()
        let store = ImageStore(dataFolder: folder.url)
        let source = folder.url.appending(path: "grande.png")
        try Data(count: ImageProcessing.maxOriginalBytes + 10).write(to: source)
        #expect(throws: ImageAttachmentError.self) { try store.add(fileAt: source, botID: UUID()) }
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "anexos").path))
    }

    @Test func aPictureTheAppMadeItselfIsNotRefusedForItsSize() async throws {
        let folder = Folder()
        let store = ImageStore(dataFolder: folder.url)
        let source = folder.url.appending(path: "tela.png")
        // A real PNG followed by padding (ImageIO stops at the end of the image): over the limit, still readable.
        var bytes = try Pictures.data(width: 3000, height: 1500)
        bytes.append(Data(count: ImageProcessing.maxOriginalBytes + 10))
        try bytes.write(to: source)

        #expect(throws: ImageAttachmentError.self) { try store.add(fileAt: source, botID: UUID()) }
        let image = try await store.attach(fileAt: source, botID: UUID(), enforcingLimit: false)
        #expect(image.width == 1568 && image.height == 784)
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func removingOnlyTouchesTheStore() throws {
        let folder = Folder()
        let store = ImageStore(dataFolder: folder.url)
        let saved = try store.add(try Pictures.data(width: 40, height: 40), name: "x", botID: UUID())
        let outside = try folder.attachment("fora.jpg")
        store.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        store.remove(saved)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func deletingAnOrbRemovesItsPicturesAndNoOthers() throws {
        let folder = Folder()
        let store = ImageStore(dataFolder: folder.url)
        let mine = UUID(), other = UUID()
        let first = try store.add(try Pictures.data(width: 40, height: 40), name: "x", botID: mine)
        let second = try store.add(try Pictures.data(width: 40, height: 40), name: "y", botID: other)
        store.deleteAll(for: mine)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test @MainActor func deletingTheOrbInTheAppDeletesItsPictures() async throws {
        let folder = Folder()
        let model = AppModel(store: Store(directory: folder.url), runsBackgroundWork: false)
        let bot = model.bots[0]
        let image = try model.images.add(try Pictures.data(width: 40, height: 40), name: "x", botID: bot.id)
        model.deleteBot(bot.id)
        await waitUntil("the Orb's pictures to be deleted") { !FileManager.default.fileExists(atPath: image.path) }
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }
}

// MARK: - Persistence

struct ImageMessageCodingTests {
    private func json(_ message: ChatMessage) throws -> JSONValue {
        try #require(JSONValue.parse(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
    }

    @Test func aMessageWithoutPicturesIsWrittenAsBefore() throws {
        let object = try json(.user("oi"))
        #expect(object["images"] == nil)
        #expect(object == .object(["role": .string("user"), "content": .string("oi"), "toolCalls": .array([]),
                                   "isError": .bool(false)]))
    }

    @Test func picturesAreWrittenAsPathsAndNeverAsBytes() throws {
        let image = ImageAttachment(path: "/data/anexos/x/1.jpg", mediaType: "image/jpeg", width: 800, height: 600)
        let object = try json(.user("veja", images: [image]))
        #expect(object["images"] == .array([.object(["path": .string("/data/anexos/x/1.jpg"), "mediaType": .string("image/jpeg"),
                                                     "width": .number(800), "height": .number(600)])]))
        let back = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage.user("veja", images: [image])))
        #expect(back.images == [image] && back.content == "veja")
    }

    @Test func messagesSavedBeforePicturesStillLoad() throws {
        let old = #"{"role":"tool","content":"ok","toolCallID":"c1"}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        #expect(message.images.isEmpty && message.content == "ok" && message.toolCallID == "c1")
    }

    @Test func aPictureEntryThisVersionCannotReadIsSkippedNotTheMessage() throws {
        let text = #"{"role":"user","content":"oi","images":[{"mediaType":"image/png"},{"path":"/a.png"}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(text.utf8))
        #expect(message.content == "oi")
        #expect(message.images == [ImageAttachment(path: "/a.png", mediaType: "image/jpeg", width: 0, height: 0)])
    }

    @Test func transcriptEntriesWithOnlyANameStillDecode() throws {
        let item = TranscriptItem(.user(text: "oi", attachments: ["nota.txt"]))
        let back = try JSONDecoder().decode(TranscriptItem.self, from: JSONEncoder().encode(item))
        #expect(back.kind == .user(text: "oi", attachments: ["nota.txt"]))
    }
}

// MARK: - Wire formats

struct ImageWireTests {
    private func parts(_ value: JSONValue?) -> [JSONValue] { value?.array ?? [] }

    // MARK: OpenAI chat

    @Test func chatKeepsTextOnlyMessagesAsPlainStrings() throws {
        let body = OpenAIClient.requestBody(model: "m", messages: [.user("oi"), ChatMessage(role: .assistant, content: "olá")], tools: [])
        let wire = try #require(body["messages"]?.array)
        #expect(wire[0] == .object(["role": .string("user"), "content": .string("oi")]))
    }

    @Test func chatSendsAUserPictureAsADataURLAfterTheText() throws {
        let folder = Folder()
        let image = try folder.attachment(bytes: "hello")
        let body = OpenAIClient.requestBody(model: "m", messages: [.user("o que é isto?", images: [image])], tools: [])
        let content = try #require(body["messages"]?.array?.first?["content"])
        #expect(content == .array([
            .object(["type": .string("text"), "text": .string("o que é isto?")]),
            .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/jpeg;base64,aGVsbG8=")])]),
        ]))
    }

    @Test func chatOmitsEmptyTextWhenOnlyAPictureIsSent() throws {
        let folder = Folder()
        let body = OpenAIClient.requestBody(model: "m", messages: [.user("", images: [try folder.attachment()])], tools: [])
        let content = parts(body["messages"]?.array?.first?["content"])
        #expect(content.count == 1 && content[0]["type"] == .string("image_url"))
    }

    @Test func aPictureWhoseFileIsGoneBecomesTextInsteadOfFailingTheRequest() throws {
        let gone = ImageAttachment(path: "/nonexistent/x.jpg", mediaType: "image/jpeg", width: 1, height: 1)
        let body = OpenAIClient.requestBody(model: "m", messages: [.user("veja", images: [gone])], tools: [])
        let content = parts(body["messages"]?.array?.first?["content"])
        #expect(content == [.object(["type": .string("text"), "text": .string("veja\n[imagem indisponível: /nonexistent/x.jpg]")])])
    }

    @Test func chatSendsToolPicturesInAUserMessageAfterTheWholeRunOfToolResults() throws {
        let folder = Folder()
        let shot = try folder.attachment("tela.jpg", bytes: "tela")
        let calls = [ToolCallRequest(id: "a", name: "screenshot", arguments: "{}"), ToolCallRequest(id: "b", name: "read_file", arguments: "{}")]
        let messages: [ChatMessage] = [
            .user("veja a tela"),
            ChatMessage(role: .assistant, content: "", toolCalls: calls),
            .tool("a", "Captura salva", images: [shot]),
            .tool("b", "conteúdo"),
            ChatMessage(role: .assistant, content: "Vi."),
        ]
        let wire = try #require(OpenAIClient.requestBody(model: "m", messages: messages, tools: [])["messages"]?.array)
        #expect(wire.map { $0["role"]?.string } == ["user", "assistant", "tool", "tool", "user", "assistant"])
        // The tool message itself is text as usual.
        #expect(wire[2] == .object(["role": .string("tool"), "content": .string("Captura salva"), "tool_call_id": .string("a")]))
        let extra = parts(wire[4]["content"])
        #expect(extra[0] == .object(["type": .string("text"), "text": .string("Image returned by the previous tool call (screenshot).")]))
        #expect(extra[1]["image_url"]?["url"]?.string?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func aPictureFromTheLastToolResultComesAfterItAtTheEnd() throws {
        let folder = Folder()
        let messages: [ChatMessage] = [
            .user("veja"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "a", name: "screenshot", arguments: "{}")]),
            .tool("a", "ok", images: [try folder.attachment()]),
        ]
        let wire = try #require(OpenAIClient.requestBody(model: "m", messages: messages, tools: [])["messages"]?.array)
        #expect(wire.map { $0["role"]?.string } == ["user", "assistant", "tool", "user"])
    }

    // MARK: Anthropic

    @Test func anthropicPutsPictureBlocksBeforeTheText() throws {
        let folder = Folder()
        let body = AnthropicClient.requestBody(model: "claude-x", messages: [.user("o que é?", images: [try folder.attachment(bytes: "hello")])],
                                               tools: [], maxTokens: 100)
        let blocks = parts(body["messages"]?.array?.first?["content"])
        #expect(blocks[0] == .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string("aGVsbG8="),
        ])]))
        #expect(blocks[1]["type"] == .string("text") && blocks[1]["text"] == .string("o que é?"))
    }

    @Test func anthropicTextOnlyMessagesAreUnchanged() throws {
        let body = AnthropicClient.requestBody(model: "claude-x", messages: [.user("oi")], tools: [], maxTokens: 100)
        let blocks = parts(body["messages"]?.array?.first?["content"])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] == .string("text") && blocks[0]["text"] == .string("oi"))
    }

    @Test func anthropicToolResultsCarryPicturesAsContentBlocks() throws {
        let folder = Folder()
        let messages: [ChatMessage] = [
            .user("veja"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "toolu_1", name: "screenshot", arguments: "{}"),
                                                                    ToolCallRequest(id: "toolu_2", name: "read_file", arguments: "{}")]),
            .tool("toolu_1", "Captura salva", images: [try folder.attachment(bytes: "tela")]),
            .tool("toolu_2", "texto"),
        ]
        let body = AnthropicClient.requestBody(model: "claude-x", messages: messages, tools: [], maxTokens: 100)
        let results = parts(body["messages"]?.array?.last?["content"])
        #expect(results.count == 2)
        let withPicture = try #require(results[0]["content"]?.array)
        #expect(withPicture[0] == .object(["type": .string("text"), "text": .string("Captura salva")]))
        #expect(withPicture[1]["type"] == .string("image") && withPicture[1]["source"]?["data"] == .string("dGVsYQ=="))
        // A result without pictures keeps its plain string.
        #expect(results[1]["content"] == .string("texto"))
    }

    // MARK: Responses

    @Test func responsesSendsInputTextAndInputImage() throws {
        let folder = Folder()
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("e isto?", images: [try folder.attachment(bytes: "hello")])], tools: [])
        let content = parts(body["input"]?.array?.first?["content"])
        #expect(content == [
            .object(["type": .string("input_text"), "text": .string("e isto?")]),
            .object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64,aGVsbG8=")]),
        ])
    }

    @Test func responsesTextOnlyUserMessagesStayStrings() throws {
        let body = ResponsesClient.requestBody(model: "gpt-x", messages: [.user("oi")], tools: [])
        #expect(body["input"]?.array?.first == .object(["role": .string("user"), "content": .string("oi")]))
    }

    @Test func responsesSendsToolPicturesInAUserMessageRightAfterTheOutput() throws {
        let folder = Folder()
        let messages: [ChatMessage] = [
            .user("veja"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c1", name: "screenshot", arguments: "{}")]),
            .tool("c1", "ok", images: [try folder.attachment()]),
        ]
        let input = try #require(ResponsesClient.requestBody(model: "gpt-x", messages: messages, tools: [])["input"]?.array)
        #expect(input.map { $0["type"]?.string ?? $0["role"]?.string } == ["user", "function_call", "function_call_output", "user"])
        #expect(input[2]["output"] == .string("ok"))
        let extra = parts(input[3]["content"])
        #expect(extra[0] == .object(["type": .string("input_text"), "text": .string("Image returned by the previous tool call (screenshot).")]))
        #expect(extra[1]["type"] == .string("input_image"))
    }
}

// MARK: - Window

struct ImageContextTests {
    private func picture(_ name: String) -> ImageAttachment {
        ImageAttachment(path: "/anexos/\(name).jpg", mediaType: "image/jpeg", width: 100, height: 100)
    }

    @Test func eachPictureCountsAbout1600Tokens() {
        let plain = ChatMessage.user("oi")
        let withTwo = ChatMessage.user("oi", images: [picture("a"), picture("b")])
        let added = withTwo.contextCharacters - plain.contextCharacters
        #expect(added == 2 * Int(1_600 * ContextBudget.charactersPerToken))
    }

    @Test func picturesOlderThanTheLastThreeUserTurnsBecomeTheirPath() {
        var conversation: [ChatMessage] = []
        for number in 1...5 {
            conversation += [.user("pedido \(number)", images: [picture("p\(number)")]), ChatMessage(role: .assistant, content: "ok \(number)")]
        }
        let sent = conversation.modelContext()
        let withPictures = sent.filter { !$0.images.isEmpty }.map { $0.images[0].path }
        #expect(withPictures == ["/anexos/p3.jpg", "/anexos/p4.jpg", "/anexos/p5.jpg"])
        let first = sent.first { $0.content.hasPrefix("pedido 1") }
        #expect(first?.content == "pedido 1\n[imagem anexada: /anexos/p1.jpg]")
        #expect(first?.images.isEmpty == true)
        // The history itself still has them all.
        #expect(conversation.filter { !$0.images.isEmpty }.count == 5)
    }

    @Test func fewerThanThreeTurnsKeepEverything() {
        let conversation: [ChatMessage] = [.user("um", images: [picture("a")]), ChatMessage(role: .assistant, content: "ok"),
                                           .user("dois", images: [picture("b")])]
        #expect(conversation.elidingOldImages() == conversation)
    }

    @Test func aTaskWithManyScreenshotsKeepsOnlyTheNewestOnes() {
        var conversation: [ChatMessage] = [.user("faça")]
        for step in 1...9 {
            conversation.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c\(step)", name: "screenshot", arguments: "{}")]))
            conversation.append(.tool("c\(step)", "captura \(step)", images: [picture("s\(step)")]))
        }
        let sent = conversation.elidingOldImages()
        let kept = sent.filter { !$0.images.isEmpty }.map(\.content)
        #expect(kept == (4...9).map { "captura \($0)" })
        #expect(sent[2].content == "captura 1\n[imagem anexada: /anexos/s1.jpg]")
    }

    @Test func pictureCostCountsTowardTheBudget() {
        // Two turns of 10 pictures each do not fit a small budget; the older turn is folded into the summary.
        let heavy = (0..<10).map { picture("h\($0)") }
        let conversation: [ChatMessage] = [.user("antes", images: heavy), ChatMessage(role: .assistant, content: "ok"),
                                           .user("agora", images: heavy), ChatMessage(role: .assistant, content: "ok")]
        let window = ContextWindow.fit(conversation, budget: ContextBudget(tokens: 20_000))
        #expect(window.droppedCount == 2)
        #expect(window.messages.contains { $0.content.hasPrefix("agora") })
    }
}

// MARK: - Engine

private actor Calls {
    private(set) var received: [[ChatMessage]] = []
    private var plan: [Result<[LLMEvent], Error>]

    init(_ plan: [Result<[LLMEvent], Error>]) { self.plan = plan }

    func next(_ messages: [ChatMessage]) throws -> [LLMEvent] {
        received.append(messages)
        return try (plan.isEmpty ? .success([.text("fim")]) : plan.removeFirst()).get()
    }
}

private struct PlannedLLM: LLMClient {
    let calls: Calls

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for event in try await calls.next(messages) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A read-only tool that returns a picture along with its text.
private struct LookAtTool: AgentTool {
    let image: ImageAttachment
    var spec: ToolSpec { ToolSpec(name: "look", description: "Looks", parameters: .schema([:])) }
    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("Olhando", "") }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "texto" }
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        ToolResult(text: "texto", images: context.acceptsImages ? [image] : [])
    }
}

struct ImageEngineTests {
    private func request(_ calls: Calls, images: [ImageAttachment] = [], supportsImages: Bool? = nil, tools: [any AgentTool] = [],
                         rejected: Flag? = nil, acceptsImages: Bool = true) -> TurnRequest {
        let onRejected: (@Sendable () -> Void)? = rejected.map { flag in { @Sendable in flag.set() } }
        return TurnRequest(bot: Bot(name: "T", role: "", orb: OrbConfig(), permissionMode: .auto), model: "m", system: "sys", history: [],
                    prompt: "veja isto", client: PlannedLLM(calls: calls), tools: tools,
                    context: ToolContext(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), acceptsImages: acceptsImages),
                    images: images, supportsImages: supportsImages, onImagesRejected: onRejected)
    }

    private func run(_ request: TurnRequest) async -> [TurnEvent] {
        var events: [TurnEvent] = []
        for await event in AgentEngine().run(request) { events.append(event) }
        return events
    }

    private func notices(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }

    private func recorded(_ events: [TurnEvent]) -> [ChatMessage] {
        events.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }

    @Test func theUserMessageCarriesThePicturesAndTheModelGetsThem() async throws {
        let folder = Folder()
        let image = try folder.attachment()
        let calls = Calls([])
        let events = await run(request(calls, images: [image], supportsImages: true))
        #expect(recorded(events).first?.images == [image])
        let sent = await calls.received[0]
        #expect(sent.last?.images == [image])
        #expect(notices(events).isEmpty)
    }

    @Test func aModelThatCannotSeeNeverGetsPicturesOnlyTheirPaths() async throws {
        let folder = Folder()
        let image = try folder.attachment()
        let calls = Calls([])
        let events = await run(request(calls, images: [image], supportsImages: false))
        let sent = await calls.received[0]
        #expect(sent.allSatisfy { $0.images.isEmpty })
        #expect(sent.last?.content.contains("[imagem: \(image.path) — este modelo não aceita imagens]") == true)
        #expect(notices(events) == ["Este modelo não vê imagens; mandei só o caminho do arquivo."])
        // The conversation keeps the picture: a later switch to a model that sees can use it.
        #expect(recorded(events).first?.images == [image])
    }

    @Test func aProviderThatRefusesPicturesIsRetriedOnceWithoutThem() async throws {
        let folder = Folder()
        let image = try folder.attachment()
        let calls = Calls([.failure(LLMError.http(status: 400, message: "This model does not support image input")),
                           .success([.text("Não vejo, mas segue o caminho.")])])
        let rejected = Flag()
        let events = await run(request(calls, images: [image], supportsImages: nil, rejected: rejected))
        let received = await calls.received
        #expect(received.count == 2)
        #expect(received[0].last?.images == [image])
        #expect(received[1].allSatisfy { $0.images.isEmpty })
        #expect(received[1].last?.content.contains("[imagem: \(image.path) — este modelo não aceita imagens]") == true)
        #expect(notices(events) == ["Este modelo não vê imagens; mandei só o caminho do arquivo."])
        #expect(rejected.isSet)
        #expect(recorded(events).last?.content == "Não vejo, mas segue o caminho.")
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func otherFailuresAreNotBlamedOnThePictures() async throws {
        let folder = Folder()
        let calls = Calls([.failure(LLMError.http(status: 401, message: "invalid image api key")),
                           .success([.text("x")])])
        let events = await run(request(calls, images: [try folder.attachment()], supportsImages: nil))
        #expect(await calls.received.count == 1)
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aRefusalThatIsNotAboutPicturesIsNotRetriedWithoutThem() async throws {
        // No pictures in the request: an error that mentions images cannot be about them.
        let calls = Calls([.failure(LLMError.http(status: 400, message: "image input is not supported")), .success([.text("x")])])
        let events = await run(request(calls, images: [], supportsImages: nil))
        #expect(await calls.received.count == 1)
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aToolPictureIsRecordedOnTheToolMessageAndSentOnTheNextCall() async throws {
        let folder = Folder()
        let shot = try folder.attachment("tela.jpg")
        let calls = Calls([.success([.toolCalls([ToolCallRequest(id: "c1", name: "look", arguments: "{}")])]),
                           .success([.text("Vi a tela.")])])
        let events = await run(request(calls, supportsImages: true, tools: [LookAtTool(image: shot)]))
        let toolMessage = try #require(recorded(events).first { $0.role == .tool })
        #expect(toolMessage.content == "texto" && toolMessage.images == [shot])
        let second = await calls.received[1]
        #expect(second.last?.role == .tool && second.last?.images == [shot])
    }

    @Test func aToolPictureToAModelThatCannotSeeBecomesItsPath() async throws {
        let folder = Folder()
        let shot = try folder.attachment("tela.jpg")
        let calls = Calls([.success([.toolCalls([ToolCallRequest(id: "c1", name: "look", arguments: "{}")])]),
                           .success([.text("ok")])])
        _ = await run(request(calls, supportsImages: false, tools: [LookAtTool(image: shot)], acceptsImages: true))
        let second = await calls.received[1]
        #expect(second.allSatisfy { $0.images.isEmpty })
        #expect(second.last?.content.contains(shot.path) == true)
    }

    @Test func aToolWithoutPicturesStillWorksThroughTheDefaultHook() async throws {
        struct Plain: AgentTool {
            var spec: ToolSpec { ToolSpec(name: "plain", description: "", parameters: .schema([:])) }
            var kind: ToolCall.Kind { .file }
            var capability: Capability? { nil }
            func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
            func summary(_ arguments: JSONValue) -> (title: String, detail: String) { ("", "") }
            func run(_ arguments: JSONValue, context: ToolContext) async throws -> String { "pronto" }
        }
        let result = try await Plain().runWithImages(.object([:]), context: ToolContext(workingDirectory: URL(fileURLWithPath: "/tmp")))
        #expect(result.text == "pronto" && result.images.isEmpty)
    }
}

struct ImageRejectionTests {
    @Test func recognizesProvidersSayingTheyCannotReadPictures() {
        let messages = ["Invalid content type. image_url is only supported by certain models.",
                        "This model does not support image inputs", "Model does not support vision",
                        "Multimodal input is not supported by this model"]
        for message in messages {
            #expect(ImageRejection.matches(LLMError.http(status: 400, message: message)), "\(message)")
        }
        #expect(ImageRejection.matches(LLMError.invalidResponse("images are not supported")))
        #expect(ImageRejection.matches(LLMError.stream(type: "invalid_request_error", message: "image input not allowed")))
    }

    @Test func ignoresOtherErrors() {
        #expect(!ImageRejection.matches(LLMError.http(status: 401, message: "bad image key")))
        #expect(!ImageRejection.matches(LLMError.http(status: 429, message: "too many image requests")))
        #expect(!ImageRejection.matches(LLMError.http(status: 400, message: "max_tokens too large")))
        #expect(!ImageRejection.matches(CancellationError()))
    }

    @Test func aProblemWithOnePictureDoesNotMarkTheModelAsBlind() {
        let messages = ["image exceeds 5 MB maximum", "messages.0.content: could not process image",
                        "[imagem anexada: /d/anexos/x/1.jpg] is not valid"]
        for message in messages {
            #expect(!ImageRejection.matches(LLMError.http(status: 400, message: message)), "\(message)")
        }
    }
}

// MARK: - Catalogs

struct VisionCatalogTests {
    private func json(_ text: String) throws -> JSONValue { try #require(JSONValue.parse(text)) }

    @Test func modelsDevInputModalitiesAndAttachmentSayWhetherPicturesWork() throws {
        let metadata = try json("""
        {"sees": {"name":"Vê","modalities":{"input":["text","image"],"output":["text"]},"tool_call":true,"cost":{"input":1,"output":2}},
         "reads": {"name":"Lê","attachment":true,"tool_call":true,"cost":{"input":1,"output":2}},
         "blind": {"name":"Cego","modalities":{"input":["text"]},"attachment":false,"tool_call":true,"cost":{"input":1,"output":2}},
         "silent": {"name":"Mudo","tool_call":true,"cost":{"input":1,"output":2}}}
        """)
        let models = ModelCatalog.openCodeModels(live: ["sees", "reads", "blind", "silent"], metadata: metadata)
        #expect(Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.supportsImages) }) ==
                ["sees": true, "reads": true, "blind": false, "silent": nil])
    }

    @Test func openRouterListsInputModalities() throws {
        let entries = try #require(try json("""
        {"data":[{"id":"b/model","architecture":{"input_modalities":["text","image"]}},
                 {"id":"a/text-only","architecture":{"input_modalities":["text"]}},
                 {"id":"c/unknown"}]}
        """)["data"]?.array)
        let models = ModelCatalog.openRouterModels(entries)
        #expect(models.map(\.id) == ["a/text-only", "b/model", "c/unknown"])
        #expect(models.map(\.supportsImages) == [false, true, nil])
        #expect(models.allSatisfy { $0.format == .chat })
    }

    @Test func knownOpenAIFamiliesTakePicturesAndTheRestAreUnknown() {
        let models = ModelCatalog.openAIModels(["gpt-4o-mini", "gpt-4.1", "gpt-5.2-codex", "o3", "o4-mini", "o3-mini", "gpt-3.5-turbo", "o1-mini"])
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.supportsImages) })
        #expect(byID["gpt-4o-mini"] == true && byID["gpt-4.1"] == true && byID["gpt-5.2-codex"] == true)
        #expect(byID["o3"] == true && byID["o4-mini"] == true)
        #expect(byID["o3-mini"] == false)
        #expect(byID["gpt-3.5-turbo"] == .some(nil) && byID["o1-mini"] == .some(nil))
    }

    @Test func chatGPTUsesItsOwnModalitiesThenTheFamily() throws {
        let models = ModelCatalog.chatGPTModels(try json("""
        {"models":[{"slug":"gpt-6-sol","display_name":"A","visibility":"list","input_modalities":["text","image"]},
                   {"slug":"gpt-text","display_name":"B","visibility":"list","input_modalities":["text"]},
                   {"slug":"gpt-5-codex","display_name":"C","visibility":"list"},
                   {"slug":"mystery","display_name":"D","visibility":"list"}]}
        """))
        #expect(models.map(\.supportsImages) == [true, false, true, nil])
    }

    @Test func modelsSavedBeforeTheFieldExistedDecodeAsUnknown() throws {
        let account = try JSONDecoder().decode(ProviderAccount.self, from: Data("""
        {"kind":"openai","baseURL":"https://api.openai.com/v1","models":[{"id":"gpt-5","name":"gpt-5","format":"responses"}]}
        """.utf8))
        #expect(account.models[0].supportsImages == nil)
        var seen = account
        seen.models[0].supportsImages = true
        let back = try JSONDecoder().decode(ProviderAccount.self, from: JSONEncoder().encode(seen))
        #expect(back.models[0].supportsImages == true)
    }
}

// MARK: - App

struct ImageAppTests {
    @Test func claudeCodeIsToldWhereThePicturesAreAndToUseRead() {
        let note = AppModel.pictureNote([ImageAttachment(path: "/d/anexos/x/1.jpg", mediaType: "image/jpeg", width: 1, height: 1)],
                                        forClaudeCode: true, modelSees: true)
        #expect(note.contains("Imagens anexadas") && note.contains("Read") && note.contains("/d/anexos/x/1.jpg"))
    }

    @Test func theNativeEngineMentionsPathsOnlyForModelsThatSee() {
        let images = [ImageAttachment(path: "/d/1.jpg", mediaType: "image/jpeg", width: 1, height: 1)]
        #expect(AppModel.pictureNote(images, forClaudeCode: false, modelSees: true).contains("/d/1.jpg"))
        #expect(AppModel.pictureNote(images, forClaudeCode: false, modelSees: false).isEmpty)
    }

    @Test func whenItIsNotKnownIfTheModelSeesTheNoteDoesNotPromiseIt() {
        let images = [ImageAttachment(path: "/d/1.jpg", mediaType: "image/jpeg", width: 1, height: 1)]
        let note = AppModel.pictureNote(images, forClaudeCode: false, modelSees: nil)
        #expect(note.contains("/d/1.jpg") && !note.contains("shown to you"))
    }

    @Test func theClaudeCodeCatchUpListsPicturesOtherModelsWereShown() {
        let image = ImageAttachment(path: "/d/anexos/x/1.jpg", mediaType: "image/jpeg", width: 1, height: 1)
        let text = ClaudeCodePrompt.catchUp([.user("veja", images: [image]), ChatMessage(role: .assistant, content: "vi")])
        #expect(text.contains("/d/anexos/x/1.jpg"))
    }

    @Test @MainActor func aSentMessageStoresFullPathsAndAPictureAloneIsEnough() throws {
        let folder = Folder()
        let model = AppModel(store: Store(directory: folder.url), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let bot = model.bots[0]
        let image = try model.images.add(try Pictures.data(width: 64, height: 64), name: "x", botID: bot.id)
        let file = URL(fileURLWithPath: "/tmp/nota.txt")

        #expect(model.send("", attachments: [file], images: [image], to: bot.id))
        let user = model.transcript(bot.id).compactMap { item -> (String, [String])? in
            if case .user(let text, let attachments) = item.kind { (text, attachments) } else { nil }
        }
        #expect(user.count == 1)
        #expect(user[0].1 == ["/tmp/nota.txt", image.path])
        model.stop(bot.id)
    }

    @Test @MainActor func nothingToSendIsStillRefused() {
        let folder = Folder()
        let model = AppModel(store: Store(directory: folder.url), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        #expect(model.send("   ", to: model.bots[0].id) == false)
    }

    @Test func memoryNotesKeepOnlyTheFileNamesOfAttachments() throws {
        let items = [TranscriptItem(.user(text: "veja", attachments: ["/Users/x/Library/Orb/anexos/1/abc.jpg"]))]
        let page = try #require(SessionSummary.page(from: items))
        #expect(page.body.contains("abc.jpg") && !page.body.contains("/Users/x"))
    }
}
