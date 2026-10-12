import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Orb

/// Files and pictures dropped anywhere on an Orb's chat join its next message, as the "Anexar" button's would.
@MainActor final class ChatDropTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbChatDrop-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private func model() throws -> (AppModel, UUID) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        return (model, try #require(model.bots.first?.id))
    }

    private func file(_ name: String, _ contents: Data = Data("conteúdo".utf8)) throws -> URL {
        let url = root.appending(path: name)
        try contents.write(to: url)
        return url
    }

    @Test func filesAreListedOncePicturesArePrepared() async throws {
        let (model, botID) = try model()
        let notes = try file("notas.txt")
        let photo = try file("foto.png", try Pictures.data(width: 40, height: 40))
        model.attach([notes, photo, notes, URL(string: "https://example.com/a.txt")!], to: botID)
        let lane = model.composerLane(botID)
        #expect(lane.files.map(\.url) == [notes])
        await waitUntil("the picture to be prepared") { lane.pictures.count == 1 && lane.pendingPictures == 0 }
        #expect(lane.error == nil)
    }

    @Test func picturesJoinInTheOrderTheyWereAttachedHoweverLongEachTakes() async throws {
        let (model, botID) = try model()
        let lane = model.composerLane(botID)
        let slow = AsyncStream<Void>.makeStream()
        model.attachPicture(to: botID) { _, _ in
            for await _ in slow.stream { break } // the big one: ready only after the next one
            return ImageAttachment(path: "/tmp/primeira.jpg", mediaType: "image/jpeg", width: 10, height: 10)
        }
        model.attachPicture(to: botID) { _, _ in ImageAttachment(path: "/tmp/segunda.jpg", mediaType: "image/jpeg", width: 10, height: 10) }
        await waitUntil("the second one is ready") { lane.pendingPictures == 1 }
        #expect(lane.pictures.isEmpty) // it waits for the one attached before it
        slow.continuation.yield()
        await waitUntil("both are in") { lane.pendingPictures == 0 }
        #expect(lane.pictures.map(\.path) == ["/tmp/primeira.jpg", "/tmp/segunda.jpg"])
    }

    @Test func aMessageTakesAtMostItsShareOfPictures() async throws {
        let (model, botID) = try model()
        let lane = model.composerLane(botID)
        for index in 0...ImageProcessing.maxPerMessage {
            model.attachPicture(to: botID) { _, _ in ImageAttachment(path: "/tmp/\(index).jpg", mediaType: "image/jpeg", width: 1, height: 1) }
        }
        await waitUntil("the pictures are in") { lane.pendingPictures == 0 }
        #expect(lane.pictures.count == ImageProcessing.maxPerMessage)
        #expect(lane.error?.contains("Até \(ImageProcessing.maxPerMessage) imagens") == true)
    }

    @Test func aFileDroppedOnTheChatJoinsTheMessageAndTheFieldTakesTheFocus() async throws {
        let (model, botID) = try model()
        let notes = try file("relatório.pdf")
        let provider = try #require(NSItemProvider(contentsOf: notes))
        #expect(model.attachDropped([provider], to: botID))
        #expect(model.pendingChatRequest == PendingChatRequest(kind: .focusComposer, botID: botID))
        let lane = model.composerLane(botID)
        await waitUntil("the dropped file to be listed") { lane.files.map(\.url.standardizedFileURL) == [notes.standardizedFileURL] }
    }

    @Test func aPictureFromABrowserComesAsTheImageItself() async throws {
        let (model, botID) = try model()
        let provider = NSItemProvider(item: try Pictures.data(width: 64, height: 48) as NSData, typeIdentifier: UTType.png.identifier)
        #expect(model.attachDropped([provider], to: botID))
        let lane = model.composerLane(botID)
        await waitUntil("the dropped picture to be prepared") { lane.pictures.count == 1 && lane.pendingPictures == 0 }
        #expect(lane.pictures.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func textOrALinkIsNotTaken() throws {
        let (model, botID) = try model()
        let text = NSItemProvider(object: "só um texto" as NSString)
        #expect(!model.attachDropped([text], to: botID))
        #expect(model.pendingChatRequest == nil)
        #expect(!model.composerLane(botID).hasAttachments)
    }
}
