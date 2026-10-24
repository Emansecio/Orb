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
    /// They join in the order they were attached, however long each takes; past `ImageProcessing.maxPerMessage` the
    /// rest is turned down (the provider would refuse the whole message).
    func attachPicture(to botID: UUID, _ load: @escaping @Sendable (ImageStore, UUID) async throws -> ImageAttachment) {
        attachPicture(into: composerLane(botID), of: botID, load)
    }

    /// The same for any composer: `owner` is the Orb or the group the picture is saved under (`anexos/<owner>/`).
    func attachPicture(into lane: ComposerLane, of owner: UUID,
                       _ load: @escaping @Sendable (ImageStore, UUID) async throws -> ImageAttachment) {
        lane.error = nil
        guard lane.pictures.count + lane.pendingPictures < ImageProcessing.maxPerMessage else {
            lane.error = "Até \(ImageProcessing.maxPerMessage) imagens por mensagem; mande as outras na próxima."
            return
        }
        let store = images
        let place = lane.reservePicture()
        Task {
            var loaded: ImageAttachment?
            do { loaded = try await load(store, owner) }
            catch { lane.error = error.localizedDescription }
            lane.pictureArrived(place, loaded)
        }
    }

    /// ⌘V with a picture on the clipboard (a screenshot, an image copied from Preview), or with picture files copied in Finder:
    /// `files` gets the files, `picture` the image itself. False when the clipboard held none (text pastes as text, as before).
    static func takePastedPictures(files attach: ([URL]) -> Void, picture: (Data) -> Void) -> Bool {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if files.contains(where: ImageProcessing.isImageFile) {
            attach(files)
            return true
        }
        let hasText = board.types?.contains { [.string, .rtf].contains($0) } ?? false
        guard files.isEmpty, !hasText, let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return false }
        picture(data)
        return true
    }

    /// What can be dropped on a chat: files from Finder or the desktop, and pictures dragged out of a browser or an app
    /// that hands over the image itself, not a file.
    nonisolated static let droppableTypes: [UTType] = [.fileURL, .image]

    /// Something dropped anywhere on the chat of `botID` joins the next message, and the field takes the focus.
    /// False when nothing in it can be attached (a link, some text).
    @discardableResult
    func attachDropped(_ providers: [NSItemProvider], to botID: UUID) -> Bool {
        let took = takeDropped(providers, file: { [weak self] url in self?.attach([url], to: botID) },
                               picture: { [weak self] data in
                                   self?.attachPicture(to: botID) { try await $0.attach(try await data.load(), name: data.name, botID: $1) }
                               })
        if took { request(.focusComposer, of: botID) }
        return took
    }

    /// Reads what was dropped: a file by its address, a picture that came as the image itself. False when it was neither.
    private func takeDropped(_ providers: [NSItemProvider], file: @escaping @MainActor (URL) -> Void,
                             picture: (DroppedImage) -> Void) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in file(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                picture(DroppedImage(provider: provider, name: provider.suggestedName ?? "imagem arrastada"))
            }
        }
        return took
    }

    // MARK: Groups

    /// The composer state of a group (only pictures: a group's message carries no other file). Made when first asked for.
    func groupLane(_ groupID: UUID) -> ComposerLane {
        if let lane = groupLanes[groupID] { return lane }
        let lane = ComposerLane()
        groupLanes[groupID] = lane
        return lane
    }

    nonisolated static let groupImagesOnly = "Nos grupos, por enquanto, só dá para anexar imagens."

    /// Pictures from the picker, ⌘V or a drop join the next message of the group, with the same limits as an Orb's chat.
    /// Any other file is turned down out loud, not dropped without a word.
    func attach(_ urls: [URL], toGroup groupID: UUID) {
        let lane = groupLane(groupID)
        for url in urls where url.isFileURL {
            if ImageProcessing.isImageFile(url) {
                attachPicture(into: lane, of: groupID) { try await $0.attach(fileAt: url, botID: $1) }
            } else {
                lane.error = Self.groupImagesOnly
            }
        }
    }

    @discardableResult
    func attachDropped(_ providers: [NSItemProvider], toGroup groupID: UUID) -> Bool {
        let lane = groupLane(groupID)
        return takeDropped(providers, file: { [weak self] url in self?.attach([url], toGroup: groupID) },
                           picture: { [weak self] data in
                               self?.attachPicture(into: lane, of: groupID) { try await $0.attach(try await data.load(), name: data.name, botID: $1) }
                           })
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
