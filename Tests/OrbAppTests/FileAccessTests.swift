import Foundation
import Testing
@testable import Orb

/// What the file tools say when the file system refuses, and the cases where they used to go on silently.
final class FileAccessTests {
    let workspace: ToolWorkspace

    init() throws { workspace = try ToolWorkspace() }

    deinit {
        // Let the temporary folder be removed whatever mode a test left behind.
        if let items = FileManager.default.enumerator(atPath: workspace.directory.path) {
            for case let name as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: workspace.directory.appending(path: name).path)
            }
        }
    }

    private func failure(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async -> String {
        do {
            _ = try await workspace.run(tool, arguments)
            return ""
        } catch {
            return (error as? ToolError)?.message ?? "\(error)"
        }
    }

    private func lock(_ name: String, mode: Int = 0o000) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: workspace.url(name).path)
    }

    // MARK: Permission errors

    @Test func aFileThatCannotBeReadIsReportedInPortugueseWithItsPathAndWhatToDo() async throws {
        try workspace.write("locked.txt", "segredo\n")
        try lock("locked.txt")
        for tool: any AgentTool in [ReadFileTool()] {
            let message = await failure(tool, ["path": .string("locked.txt")])
            #expect(message.contains("Sem permissão para ler"), Comment(rawValue: message))
            #expect(message.contains(workspace.url("locked.txt").lastPathComponent))
            #expect(message.contains("Privacidade e Segurança") && message.contains("sudo"))
            #expect(!message.contains("couldn’t be opened"))
        }
        let edit = await failure(EditFileTool(), ["path": .string("locked.txt"), "old_text": .string("a"), "new_text": .string("b")])
        #expect(edit.contains("Sem permissão para ler") && edit.contains("locked.txt"))
    }

    @Test func aProtectedFileIsNotOverwrittenInSilence() async throws {
        try workspace.write("fixo.txt", "original\n")
        try lock("fixo.txt", mode: 0o444)
        let message = await failure(WriteFileTool(), ["path": .string("fixo.txt"), "content": .string("novo")])
        #expect(message.contains("protegido contra escrita") && message.contains("chmod u+w"), Comment(rawValue: message))
        #expect(try workspace.readText("fixo.txt") == "original\n")
        // Appending to and editing it are refused the same way, and it stays as it was.
        let append = await failure(WriteFileTool(), ["path": .string("fixo.txt"), "content": .string("mais"), "append": .bool(true)])
        #expect(!append.isEmpty)
        let edit = await failure(EditFileTool(), ["path": .string("fixo.txt"), "old_text": .string("original"), "new_text": .string("x")])
        #expect(edit.contains("protegido contra escrita"))
        #expect(try workspace.readText("fixo.txt") == "original\n")
        // Once the owner lifts the protection, writing works again and keeps the mode.
        try lock("fixo.txt", mode: 0o644)
        _ = try await workspace.run(WriteFileTool(), ["path": .string("fixo.txt"), "content": .string("novo")])
        #expect(try workspace.readText("fixo.txt") == "novo")
    }

    @Test func aNewFileInAReadOnlyFolderSaysSo() async throws {
        try FileManager.default.createDirectory(at: workspace.url("ro"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.url("ro").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.url("ro").path) }
        let message = await failure(WriteFileTool(), ["path": .string("ro/novo.txt"), "content": .string("x")])
        #expect(message.contains("Sem permissão para gravar em") && message.contains("ro/novo.txt"), Comment(rawValue: message))
    }

    @Test func errorsThatAreNotAboutPermissionPassThrough() throws {
        struct Other: Error {}
        #expect(FileAccess.denial(Other(), path: "/x", writing: false) == nil)
        let missing = CocoaError(.fileNoSuchFile)
        #expect(FileAccess.denial(missing, path: "/x", writing: false) == nil)
        #expect(FileAccess.denial(CocoaError(.fileWriteVolumeReadOnly), path: "/Volumes/X/a", writing: true)?.message.contains("somente leitura") == true)
        #expect(FileAccess.denial(POSIXError(.EACCES), path: "/etc/x", writing: true)?.message.contains("Sem permissão para gravar em /etc/x") == true)
        // A refusal wrapped inside another error is found.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        #expect(FileAccess.denial(wrapped, path: "/x", writing: false)?.message.contains("Sem permissão para ler") == true)
    }

    // MARK: Link loops

    @Test func aLinkLoopIsNamedInsteadOfPassingForAMissingFile() async throws {
        try workspace.link("loop1", to: "loop2")
        try workspace.link("loop2", to: "loop1")
        let read = await failure(ReadFileTool(), ["path": .string("loop1")])
        #expect(read.contains("Link simbólico em loop") && !read.contains("não encontrado"))
        let write = await failure(WriteFileTool(), ["path": .string("loop1"), "content": .string("x")])
        #expect(write.contains("Link simbólico em loop"))
        // The link is still a link: nothing replaced it with a file.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: workspace.url("loop1").path)) != nil)
        let edit = await failure(EditFileTool(), ["path": .string("loop1"), "old_text": .string("a"), "new_text": .string("b")])
        #expect(edit.contains("Link simbólico em loop"))
        // Ordinary links are not loops, nor is a dangling one.
        try workspace.write("real.txt", "ok\n")
        try workspace.link("good", to: "real.txt")
        try workspace.link("dangling", to: "nowhere.txt")
        #expect(!workspace.url("good").isInLinkLoop && !workspace.url("dangling").isInLinkLoop && !workspace.url("real.txt").isInLinkLoop)
        #expect(workspace.url("loop2").isInLinkLoop)
        #expect(try await workspace.run(ReadFileTool(), ["path": .string("good")]).contains("ok"))
    }

    // MARK: Long lines

    @Test func aClippedLineSaysHowToSeeTheRest() async throws {
        try workspace.write("min.json", String(repeating: "x", count: 5_000) + "\n")
        let output = try await workspace.run(ReadFileTool(), ["path": .string("min.json")])
        #expect(output.contains("+3000 caracteres nesta linha"))
        #expect(output.contains("grep") && output.contains("cut -c"))
    }
}
