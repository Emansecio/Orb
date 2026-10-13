import Foundation
import os
import Testing
@testable import Orb

/// A command the turn waits for can go on as a background job (`CommandRelease`), so the user talks to the Orb again
/// while it runs. Commands here wait for a file `go` instead of sleeping, so no test depends on timing.
final class CommandReleaseTests {
    let directory: URL
    let jobs: BackgroundJobs
    let bot = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OrbCommandReleaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        jobs = BackgroundJobs(directory: directory.appending(path: "jobs"))
    }

    deinit { jobs.killAllNow(); try? FileManager.default.removeItem(at: directory) }

    private let waitsForGo = "echo antes; while [ ! -e go ]; do sleep 0.05; done; echo depois"

    private func letItFinish() {
        FileManager.default.createFile(atPath: directory.appending(path: "go").path, contents: nil)
    }

    private func context(release: CommandRelease) throws -> ToolContext {
        let shell = try FakeShell.make(in: directory)
        var context = ToolContext(workingDirectory: directory, botID: bot, jobs: jobs,
                                  shell: ShellEnvironment(shell: shell, base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                          timeout: .seconds(60)),
                                  outputsDirectory: directory.appending(path: "saidas"))
        context.release = release
        return context
    }

    private func waitForEnd(of id: String) async -> BackgroundJobs.Snapshot? {
        var found: BackgroundJobs.Snapshot?
        await waitUntil("job \(id) to end") {
            found = await jobs.list(botID: bot).first { $0.id == id }
            return found.map { !$0.isRunning } ?? false
        }
        return found
    }

    // MARK: CommandRelease

    @Test func aPressCountsOnlyForCommandsRunningWhenItWasMade() {
        let calls = OSAllocatedUnfairLock(initialState: [Bool]())
        let release = CommandRelease(steering: nil) { waited in calls.withLock { $0.append(waited) } }
        release.press()
        release.begin()
        #expect(!release.isRequested(after: .zero))
        release.press()
        #expect(release.isRequested(after: .zero))
        release.begin()
        release.end()
        #expect(release.isRequested(after: .zero))
        release.end()
        #expect(!release.isRequested(after: .zero))
        #expect(calls.withLock { $0 } == [true, false])
    }

    @Test func aMessageForTheTaskReleasesOnlyAfterTheGrace() {
        let queue = SteeringQueue()
        let release = CommandRelease(steering: queue)
        release.begin()
        queue.push(SteeredMessage(text: "e aí?", prompt: "e aí?", delivery: .afterTask))
        #expect(!release.isRequested(after: .seconds(60)))
        queue.push(SteeredMessage(text: "e aí?", prompt: "e aí?"))
        #expect(!release.isRequested(after: .seconds(1)))
        #expect(release.isRequested(after: CommandRelease.messageGrace))
    }

    // MARK: ProcessRunner

    @Test func aDetachedCommandKeepsWritingItsWholeOutputToTheLog() async throws {
        let log = jobs.logFolder(for: bot).appending(path: "comando.log")
        let result = try await ProcessRunner.run("/bin/sh", ["-c", waitsForGo], directory: directory, timeout: .seconds(60),
                                                 detach: .init(log: log, when: { _ in true }))
        let process = try #require(result.detached)
        let job = await jobs.adopt(botID: bot, command: waitsForGo, directory: directory, startedAt: .now, process: process)
        #expect(job.isRunning && job.logPath == log.path)

        letItFinish()
        #expect(await waitForEnd(of: job.id)?.state == .exited(0))
        let text = try await jobs.output(botID: bot, id: job.id, lines: 10).text
        #expect(text.contains("antes") && text.contains("depois"))
    }

    @Test func aCommandThatEndsFirstIsNotDetached() async throws {
        let log = directory.appending(path: "nunca.log")
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo oi"], timeout: .seconds(60),
                                                 detach: .init(log: log, when: { _ in false }))
        #expect(result.detached == nil && result.status == 0 && result.output.contains("oi"))
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    // MARK: run_command

    @Test func theButtonSendsTheRunningCommandToTheBackground() async throws {
        let waiting = OSAllocatedUnfairLock(initialState: false)
        let release = CommandRelease(steering: nil) { waited in waiting.withLock { $0 = waited } }
        let context = try context(release: release)
        let command = waitsForGo
        let run = Task { try await RunCommandTool().run(.object(["command": .string(command)]), context: context) }
        await waitUntil("the command to be waited for") { waiting.withLock { $0 } }
        release.press()

        let text = try await run.value
        #expect(text.contains("segundo plano como o processo 1") && text.contains("job_output(id: \"1\")"))
        #expect(!waiting.withLock { $0 })
        letItFinish()
        #expect(await waitForEnd(of: "1")?.state == .exited(0))
        #expect(try await jobs.output(botID: bot, id: "1", lines: 10).text.contains("depois"))
    }

    @Test func aMessageSendsALongCommandToTheBackgroundButNotAQuickOne() async throws {
        let queue = SteeringQueue()
        queue.push(SteeredMessage(text: "e aí?", prompt: "e aí?"))
        // The grace decides it, not the clock of a busy machine: within it a command just ends, past it it goes.
        let quick = try await RunCommandTool().run(.object(["command": .string("echo oi")]),
                                                   context: context(release: CommandRelease(steering: queue, grace: .seconds(60))))
        #expect(quick.hasPrefix("Código de saída: 0"))

        let long = try await RunCommandTool().run(.object(["command": .string(waitsForGo)]),
                                                  context: context(release: CommandRelease(steering: queue, grace: .milliseconds(300))))
        #expect(long.contains("segundo plano como o processo 1"))
        letItFinish()
        #expect(await waitForEnd(of: "1")?.state == .exited(0))
    }

    @Test func withoutAReleaseTheCommandIsWaitedForToTheEnd() async throws {
        var context = try context(release: CommandRelease(steering: nil))
        context.release = nil
        letItFinish()
        let text = try await RunCommandTool().run(.object(["command": .string(waitsForGo)]), context: context)
        #expect(text.hasPrefix("Código de saída: 0") && text.contains("depois"))
        #expect(await jobs.list(botID: bot).isEmpty)
    }
}
