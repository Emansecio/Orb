import Foundation
import Testing
@testable import Orb

/// A failed call says how to recover where the error starts: the paths that look like a mistyped one, the arguments a
/// broken call should have had. The model fixes the call instead of trying the same thing again.
final class ErrorRecoveryTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OrbErrorRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Relatorio.md", "notas.txt", ".oculto"] {
            FileManager.default.createFile(atPath: directory.appending(path: name).path, contents: Data("x".utf8))
        }
        try FileManager.default.createDirectory(at: directory.appending(path: "docs"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func near(_ path: String) -> [String] {
        directory.appending(path: path).lookalikes.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    @Test func aMistypedPathPointsToTheOnesThatExist() {
        #expect(near("Relatoro.md") == ["Relatorio.md"])
        #expect(near("notas.md") == ["notas.txt"])
        #expect(near("doc/guia.md") == ["docs"])
        #expect(near("completamente-diferente.pdf").isEmpty)
        #expect(near("oculto").isEmpty)
        #expect(near("nota").isEmpty, "nota is no typo of notas.txt")
        #expect(near("relatorio.md") == ["Relatorio.md"])
        #expect(directory.appending(path: "sumiu/de/vez/a.txt").lookalikes.isEmpty)
    }

    @Test func readingAMissingFileListsTheLookalikes() async throws {
        let context = ToolContext(workingDirectory: directory, botID: UUID())
        await #expect {
            try await ReadFileTool().run(.object(["path": .string("relatorio.mdd")]), context: context)
        } throws: { error in
            let message = (error as? ToolError)?.message ?? ""
            return message.hasPrefix("Arquivo não encontrado: ") && message.hasSuffix("Caminhos parecidos: \(self.directory.path)/Relatorio.md.")
        }
    }

    @Test func editDistanceGivesUpPastTheLimit() {
        #expect("relatorio".editDistance(to: "relatoro", limit: 2) == 1)
        #expect("abc".editDistance(to: "xyz", limit: 2) == nil)
        #expect("".editDistance(to: "ab", limit: 2) == 2)
        #expect("curto".editDistance(to: "muito mais comprido", limit: 2) == nil)
    }

    @Test func aBrokenCallIsToldTheArgumentsItNeeds() {
        let spec = ToolSpec(name: "read_file", description: "",
                            parameters: .schema(["limit": .property("integer"), "path": .property("string")], required: ["path"]))
        #expect(spec.argumentsHint == " with: path (string, required), limit (integer)")
        #expect(ToolSpec(name: "x", description: "", parameters: .schema([:])).argumentsHint == "")
    }
}
