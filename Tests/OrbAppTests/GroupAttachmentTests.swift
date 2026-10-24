import Foundation
import Testing
@testable import Orb

/// Pictures in a group's chat: they wait in the group's composer, go into the thread with the message, reach the member(s) the
/// message goes to, and come back with the thread and the draft.
@MainActor
struct GroupAttachmentTests {
    private func picture(_ world: GroupWorld) throws -> ImageAttachment {
        try world.model.images.add(try Pictures.data(width: 40, height: 40), name: "foto", botID: world.groupID)
    }

    private func userMessages(_ world: GroupWorld) -> [(text: String, attachments: [String])] {
        world.items.compactMap { if case .user(let text, let attachments) = $0.kind { (text, attachments) } else { nil } }
    }

    // MARK: Sending

    @Test func aMessageWithAPictureIsInTheThreadAndGoesToTheOrchestrator() throws {
        let world = GroupWorld()
        let photo = try picture(world)
        world.model.groupLane(world.groupID).pictures = [photo]
        #expect(world.model.postUserMessage("Veja isto", to: world.groupID))

        let sent = try #require(userMessages(world).first)
        #expect(sent.text == "Veja isto" && sent.attachments == [photo.path])
        let turn = world.lastGroupTurn
        #expect(turn.envelope.to.id == world.atlas.id && turn.envelope.text == "Veja isto")
        #expect(world.hub.images(for: turn) == [photo])
        // They left the composer with the message.
        #expect(world.model.groupLane(world.groupID).pictures.isEmpty)
    }

    @Test func picturesAloneAreAMessageAsInAnOrbsChat() throws {
        let world = GroupWorld()
        let photo = try picture(world)
        world.model.groupLane(world.groupID).pictures = [photo]
        #expect(world.model.postUserMessage("   ", to: world.groupID))

        #expect(userMessages(world).first?.text == "" && userMessages(world).first?.attachments == [photo.path])
        #expect(world.lastGroupTurn.envelope.text == AppModel.attachmentsOnlyPrompt)
        #expect(world.hub.images(for: world.lastGroupTurn) == [photo])
    }

    @Test func onlyTheMentionedMembersGetThePictures() throws {
        let world = GroupWorld()
        let photo = try picture(world)
        world.model.groupLane(world.groupID).pictures = [photo]
        world.model.postUserMessage("@revisor olha essa foto", to: world.groupID)
        #expect(world.fake.groupTurns.map(\.envelope.to.id) == [world.revisor.id])
        #expect(world.hub.images(for: world.lastGroupTurn) == [photo])

        let all = GroupWorld()
        let shared = try picture(all)
        all.model.groupLane(all.groupID).pictures = [shared]
        all.model.postUserMessage("@todos, vejam", to: all.groupID)
        #expect(all.fake.groupTurns.count == 3)
        #expect(all.fake.groupTurns.allSatisfy { all.hub.images(for: $0) == [shared] }) // by path: the bytes are not copied
    }

    @Test func aMessageRightAfterAnotherJoinsTheTurnWithItsPictures() throws {
        let world = GroupWorld()
        let first = try picture(world), second = try picture(world)
        world.model.groupLane(world.groupID).pictures = [first]
        world.model.postUserMessage("Primeira", to: world.groupID)
        world.model.groupLane(world.groupID).pictures = [second]
        world.model.postUserMessage("Segunda", to: world.groupID)

        #expect(world.fake.groupTurns.count == 1)
        #expect(world.hub.images(for: world.lastGroupTurn) == [first, second])
    }

    @Test func aMessageThatWasNotSentKeepsItsPictures() throws {
        let world = GroupWorld()
        let photo = try picture(world)
        let ghost = UUID() // a group that does not exist
        world.model.groupLane(ghost).pictures = [photo]
        #expect(!world.model.postUserMessage("oi", to: ghost))
        #expect(world.model.groupLane(ghost).pictures == [photo])
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(!world.hub.postUserMessage("", images: [], to: world.groupID)) // nothing to send
    }

    @Test func moreThanTheLimitIsRefusedByTheHubToo() throws {
        let world = GroupWorld()
        let photo = try picture(world)
        let tooMany = Array(repeating: photo, count: ImageProcessing.maxPerMessage + 1)
        #expect(!world.hub.postUserMessage("oi", images: tooMany, to: world.groupID))
        #expect(userMessages(world).isEmpty && world.fake.groupTurns.isEmpty)
    }

    // MARK: Limits and kinds, the same as an Orb's chat

    @Test func theLimitPerMessageGivesTheSameWarningAsAnOrbsChat() async throws {
        let world = GroupWorld()
        let lane = world.model.groupLane(world.groupID)
        let photo = try picture(world)
        lane.pictures = Array(repeating: photo, count: ImageProcessing.maxPerMessage)
        world.model.attachPicture(into: lane, of: world.groupID) { _, _ in photo }
        #expect(lane.error == "Até \(ImageProcessing.maxPerMessage) imagens por mensagem; mande as outras na próxima.")
        #expect(lane.pendingPictures == 0 && lane.pictures.count == ImageProcessing.maxPerMessage)
    }

    @Test func aFileThatIsNotAPictureGivesTheSameErrorAsAnOrbsChat() async throws {
        let world = GroupWorld()
        let lane = world.model.groupLane(world.groupID)
        let text = world.root.appending(path: "nota.txt")
        try FileManager.default.createDirectory(at: world.root, withIntermediateDirectories: true)
        try Data("oi".utf8).write(to: text)
        world.model.attach([text], toGroup: world.groupID)
        #expect(lane.error == AppModel.groupImagesOnly && lane.pictures.isEmpty)

        // A name that says picture over bytes that are not: the same refusal the Orb's chat gives.
        let fake = world.root.appending(path: "falsa.png")
        try Data("não sou imagem".utf8).write(to: fake)
        world.model.attach([fake], toGroup: world.groupID)
        await waitUntil("the refusal") { lane.pendingPictures == 0 && lane.error != nil && lane.error != AppModel.groupImagesOnly }
        #expect(lane.error == ImageAttachmentError.unreadable(name: "falsa.png").errorDescription && lane.pictures.isEmpty)
    }

    @Test func aTooBigPictureIsRefusedAndAGoodOneJoinsTheLane() async throws {
        let world = GroupWorld()
        let lane = world.model.groupLane(world.groupID)
        try FileManager.default.createDirectory(at: world.root, withIntermediateDirectories: true)
        let big = world.root.appending(path: "grande.png")
        try Data(count: ImageProcessing.maxOriginalBytes + 10).write(to: big)
        world.model.attach([big], toGroup: world.groupID)
        await waitUntil("the refusal") { lane.pendingPictures == 0 && lane.error != nil }
        #expect(lane.pictures.isEmpty && lane.error?.contains("o limite é") == true)

        let good = world.root.appending(path: "boa.png")
        try Pictures.data(width: 60, height: 40).write(to: good)
        world.model.attach([good], toGroup: world.groupID)
        #expect(lane.pendingPictures == 1) // sending waits until it is in
        await waitUntil("the picture") { lane.pendingPictures == 0 }
        let saved = try #require(lane.pictures.first)
        #expect(lane.error == nil && saved.path.contains("/anexos/\(world.groupID.uuidString)/"))
    }

    // MARK: What the members read

    @Test func aMessageThatWasNotForAMemberShowsItThePathsOnly() {
        let items = [TranscriptItem(.user(text: "Olhem a tela", attachments: ["/dados/anexos/g/a.jpg"])),
                     TranscriptItem(.user(text: "", attachments: ["/dados/anexos/g/b.jpg"])),
                     TranscriptItem(.user(text: "Sem imagem", attachments: []))]
        let lines = GroupThread.lines(from: items[...], member: UUID(), request: nil, userTexts: [])
        #expect(lines == ["[Você] Olhem a tela\n[imagem anexada: /dados/anexos/g/a.jpg]",
                          "[Você] \n[imagem anexada: /dados/anexos/g/b.jpg]",
                          "[Você] Sem imagem"])
    }

    @Test func theMessageTheTurnAnswersIsNotRepeatedInTheThreadEvenWithPicturesAlone() {
        let items = [TranscriptItem(.user(text: "Olhem a tela", attachments: ["/a.jpg"])),
                     TranscriptItem(.user(text: "", attachments: ["/b.jpg"]))]
        #expect(GroupThread.lines(from: items[...], member: UUID(), request: nil, userTexts: ["Olhem a tela", ""]).isEmpty)
    }

    // MARK: Kept

    @Test func theThreadWithPicturesIsSavedAndOpensAgain() async throws {
        let world = GroupWorld()
        let photo = try picture(world)
        world.model.groupLane(world.groupID).pictures = [photo]
        world.model.postUserMessage("Veja isto", to: world.groupID)
        world.model.saveNow()

        let again = AppModel(store: Store(directory: world.root), runsBackgroundWork: false)
        let session = try #require(await again.loadGroupSession(world.groupID))
        let sent = session.items.compactMap { if case .user(let text, let attachments) = $0.kind { (text, attachments) } else { nil } }
        #expect(sent.count == 1 && sent[0].0 == "Veja isto" && sent[0].1 == [photo.path])
    }

    @Test func aThreadSavedBeforePicturesExistedOpensTheSame() async throws {
        let world = GroupWorld()
        world.model.saveNow() // the group itself is in the state; the thread below replaces what was written for it
        var old = Conversation()
        old.items = [TranscriptItem(.user(text: "Oi, grupo", attachments: []))]
        world.model.store.saveGroupConversation(old, group: world.groupID)
        world.model.store.flush()
        let again = AppModel(store: Store(directory: world.root), runsBackgroundWork: false)
        let session = try #require(await again.loadGroupSession(world.groupID))
        #expect(session.items.contains { $0.kind == .user(text: "Oi, grupo", attachments: []) })
    }

    @Test func theDraftKeepsThePicturesAcrossARestartAndDropsTheOnesThatAreGone() throws {
        let world = GroupWorld()
        let kept = try picture(world), gone = try picture(world)
        world.model.setDraft("rascunho", for: world.groupID)
        world.model.groupLane(world.groupID).pictures = [kept, gone]
        world.model.saveNow()
        try FileManager.default.removeItem(atPath: gone.path)

        let again = AppModel(store: Store(directory: world.root), runsBackgroundWork: false)
        #expect(again.draftText(world.groupID) == "rascunho")
        #expect(again.groupLane(world.groupID).pictures == [kept])
    }

    @Test func deletingTheGroupDeletesItsPicturesAndItsDraft() async throws {
        let world = GroupWorld()
        let photo = try picture(world)
        world.model.groupLane(world.groupID).pictures = [photo]
        world.model.deleteGroup(world.groupID)
        await waitUntil("the group's pictures to be deleted") { !FileManager.default.fileExists(atPath: photo.path) }
        #expect(world.model.groupLanes[world.groupID] == nil)
    }
}
