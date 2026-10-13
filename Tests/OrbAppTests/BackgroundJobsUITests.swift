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
        try await start("sleep 4; exit 3", in: model, for: botID)
        await wait { model.live(botID).jobs.count == 1 }
        #expect(model.live(botID).jobs.first?.command == "sleep 4; exit 3")

        await wait { !notices(model, botID).isEmpty }
        #expect(model.live(botID).jobs.isEmpty)
        let notice = try #require(notices(model, botID).first)
        #expect(notice.hasPrefix(NoticeAction.jobEndedPrefix) && notice.contains("código 3") && notice.contains("sleep 4"))
        #expect(NoticeAction.actions(for: notice) == [.continueTurn])
        let sent = NoticeAction.continueMessage(after: notice)
        #expect(sent.contains("job_output") && sent.contains("código 3") && !sent.contains("sleep"), "never the command: \(sent)")
        #expect(NoticeAction.continueMessage(after: "Pausei depois de 100 passos") == NoticeAction.continueMessage)
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
