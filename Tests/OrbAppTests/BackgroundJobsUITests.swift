import Foundation
import Testing
@testable import Orb

/// The processes an Orb leaves running are on screen (`BotLive.jobs`, the composer's strip) and the chat says when one ends
/// by itself, with "Continuar" telling the Orb which one.
@Suite final class BackgroundJobsUITests {
    let root = FileManager.default.temporaryDirectory.appending(path: "orb-jobs-ui-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor private func makeModel() -> (AppModel, UUID) {
        let model = AppModel(store: Store(directory: root.appending(path: "data")), runsBackgroundWork: false)
        let bot = model.createBot(name: "Atlas", role: "Teste", orb: OrbConfig(), model: "", mode: .ask, identity: "",
                                  interview: false, folder: .home)
        return (model, bot.id)
    }

    @MainActor private func start(_ command: String, in model: AppModel, for botID: UUID) async throws {
        _ = try await model.jobs.start(botID: botID, command: command, directory: root, shell: "/bin/sh",
                                       environment: ProcessInfo.processInfo.environment)
    }

    @MainActor private func notices(_ model: AppModel, _ botID: UUID) -> [String] {
        model.orbTranscript(botID).items.compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }

    @MainActor private func wait(until condition: () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test @MainActor func aJobIsShownWhileItRunsAndItsEndIsToldInTheChat() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (model, botID) = makeModel()
        // It ends only once it has been seen running: a busy machine may take a while to show it.
        let command = "until [ -e go ]; do sleep 0.1; done; exit 3"
        try await start(command, in: model, for: botID)
        await wait { model.live(botID).jobs.count == 1 }
        #expect(model.live(botID).jobs.first?.command == command)
        FileManager.default.createFile(atPath: root.appending(path: "go").path, contents: nil)

        await wait { !notices(model, botID).isEmpty }
        #expect(model.live(botID).jobs.isEmpty)
        let notice = try #require(notices(model, botID).first)
        #expect(notice.hasPrefix(NoticeAction.jobEndedPrefix) && notice.contains("código 3") && notice.contains("until [ -e go ]"))
        #expect(NoticeAction.actions(for: notice) == [.continueTurn])
        let sent = NoticeAction.continueMessage(after: notice)
        #expect(sent.contains("job_output") && sent.contains("código 3") && !sent.contains("until"), "never the command: \(sent)")
        #expect(NoticeAction.continueMessage(after: "Pausei depois de 100 passos") == NoticeAction.continueMessage)
        let afterQuit = NoticeAction.continueMessage(after: BotSession.quitNotice)
        #expect(afterQuit.hasPrefix(NoticeAction.continueMessage + ".") && afterQuit.contains("Confira antes de repetir"))
    }

    @Test @MainActor func aProcessOfTheTaskYouAskedForLetsTheOrbGoOnByItself() {
        let (model, botID) = makeModel()
        let session = model.session(botID)
        func job(startedAt: Date) -> BackgroundJobs.Snapshot {
            BackgroundJobs.Snapshot(id: "1", command: "make", directory: "/", logPath: "/x", startedAt: startedAt, state: .exited(0))
        }
        let asked = Date.now
        #expect(!model.resumesByItself(after: job(startedAt: asked), of: botID), "you never asked for anything")
        session.resumableSince = asked
        #expect(model.resumesByItself(after: job(startedAt: asked + 1), of: botID))
        #expect(!model.resumesByItself(after: job(startedAt: asked - 1), of: botID), "started before your last message")

        model.setDraft("espera", for: botID)
        #expect(!model.resumesByItself(after: job(startedAt: asked + 1), of: botID), "you are typing to it")
        model.setDraft("", for: botID)
        session.resumedAfterJobs = AppModel.resumesAfterJobs
        #expect(!model.resumesByItself(after: job(startedAt: asked + 1), of: botID), "it went on by itself enough")
        session.resumedAfterJobs = 0
        session.routineID = UUID()
        #expect(session.resumableSince == nil, "what a routine starts is not your task")
    }

    @Test @MainActor func aStoppedJobLeavesTheStripWithoutAWord() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (model, botID) = makeModel()
        try await start("sleep 30", in: model, for: botID)
        await wait { model.live(botID).jobs.count == 1 }
        model.stopJob("1", of: botID)
        await wait { model.live(botID).jobs.isEmpty }
        #expect(model.live(botID).jobs.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(notices(model, botID).isEmpty)
    }
}
