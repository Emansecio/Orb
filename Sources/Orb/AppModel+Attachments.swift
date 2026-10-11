import AppKit
import UniformTypeIdentifiers

// What goes with the next message of an Orb: files from the picker, ⌘V and anything dropped on its chat. They wait in
// the Orb's `ComposerLane`, so they survive switching to another Orb and back.

extension AppModel {
    /// Pictures become image attachments (shrunk and saved in the background); other files keep being listed by path.
    func attach(_ urls: [URL], to botID: UUID) {
        let lane = composerLane(botID)
        for url in urls where url.isFileURL {
            if ImageProcessing.isImageFile(url) {
                attachPicture(to: botID) { try await $0.attach(fileAt: url, botID: $1) }
            } else if !lane.files.contains(where: { $0.url == url }) {
                lane.files.append(AttachedFile(url: url))
                attachmentTexts.prepare(url) // read now, so the message that takes it goes at once
            }
        }
    }

    /// A picture being prepared: sending waits until it is in (see `ComposerAction.canSend`).
    func attachPicture(to botID: UUID, _ load: @escaping @Sendable (ImageStore, UUID) async throws -> ImageAttachment) {
        let lane = composerLane(botID)
        lane.error = nil
        let store = images
        lane.pendingPictures += 1
        Task {
            defer { lane.pendingPictures -= 1 }
            do { lane.pictures.append(try await load(store, botID)) }
            catch { lane.error = error.localizedDescription }
        }
    }

    /// What can be dropped on a chat: files from Finder or the desktop, and pictures dragged out of a browser or an app
    /// that hands over the image itself, not a file.
    nonisolated static let droppableTypes: [UTType] = [.fileURL, .image]

    /// Something dropped anywhere on the chat of `botID` joins the next message, and the field takes the focus.
    /// False when nothing in it can be attached (a link, some text).
    @discardableResult
    func attachDropped(_ providers: [NSItemProvider], to botID: UUID) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in self?.attach([url], to: botID) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                let name = provider.suggestedName ?? "imagem arrastada"
                let data = DroppedImage(provider: provider, name: name)
                attachPicture(to: botID) { try await $0.attach(try await data.load(), name: name, botID: $1) }
            }
        }
        if took { request(.focusComposer, of: botID) }
        return took
    }
}

/// The picture inside a dropped item, read when the attachment is prepared. The provider is only read from, once.
private struct DroppedImage: @unchecked Sendable {
    let provider: NSItemProvider
    let name: String

    func load() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ImageAttachmentError.unreadable(name: name)) }
            }
        }
    }
}
