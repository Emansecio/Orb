import SwiftUI

// Review scenes for the attachments in the chat (`Orb --snapshot transcript-attachments|transcript-outputs|
// chat-attachments-queued out.png`): the files and pictures are made in the run's data folder (which `DevRun` removes
// on exit when it is temporary). Dev aid; nothing here is used by the app itself.

@MainActor
enum AttachmentSnapshots {
    /// A file of `size` bytes in the run's data folder.
    private static func file(_ name: String, size: Int) -> String {
        let folder = DevRun.currentDataFolder.url.appendingPathComponent("snapshot-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try? Data(count: size).write(to: url)
        return url.path
    }

    private static func pictures(_ count: Int) -> [String] {
        (0..<count).map { Snapshot.sampleImage(named: "grade-\($0)", hue: CGFloat($0) * 0.083).path }
    }

    /// The conversation of `transcript-attachments`: one, two, five and twelve pictures, five files (one long, one gone,
    /// one from an older conversation that kept only the name) and a mix.
    static func conversation() -> [TranscriptItem] {
        let report = file("relatorio-trimestral-final-versao-2.pdf", size: 2_100_000)
        let sheet = file("orcamento.xlsx", size: 48_000)
        let archive = file("fotos.zip", size: 5_200_000)
        let code = file("main.swift", size: 900)
        let gone = (report as NSString).deletingLastPathComponent + "/sumiu.docx"
        func user(_ text: String, _ paths: [String]) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: paths)) }
        func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
        return [
            user("O que há nesta foto?", pictures(1)), bot("Um degradê azul."),
            user("E nestas duas?", pictures(2)), bot("Duas fotos."),
            user("Compare estas cinco", pictures(5)), bot("Cinco fotos."),
            user("E se forem doze?", pictures(12)), bot("Doze fotos."),
            user("Resume estes arquivos", [report, sheet, archive, code, gone, "relatorio-antigo.pdf"]), bot("Li os arquivos."),
            user("Mistura", Array(pictures(2).prefix(1)) + [report, gone, "relatorio-antigo.pdf"]),
        ]
    }

    /// `transcript-outputs`: a file the Orb made, one it changed and a capture of the screen, under their tool lines.
    static func outputs() -> [TranscriptItem] {
        let notes = file("NOTAS.md", size: 3_400)
        let readme = file("README.md", size: 1_200)
        let capture = Snapshot.sampleImage(named: "captura", hue: 0.55).path
        func call(_ kind: ToolCall.Kind, _ title: String, _ detail: String, files: [ProducedFile]) -> TranscriptItem {
            TranscriptItem(.tool(ToolCall(kind: kind, title: title, detail: detail, state: .done, output: "ok",
                                          startedAt: .now - 2, finishedAt: .now - 1.8, files: files)))
        }
        return [
            TranscriptItem(.user(text: "Anote o que combinamos e me mostre a tela", attachments: [])),
            call(.file, "Gravando arquivo", notes, files: [ProducedFile(path: notes, created: true)]),
            call(.file, "Editando arquivo", readme, files: [ProducedFile(path: readme, created: false)]),
            call(.computer, "Capturando a tela", "", files: [ProducedFile(path: capture, created: true)]),
            TranscriptItem(.bot(text: "Anotei em NOTAS.md, ajustei o README e tirei uma captura da tela.", isStreaming: false)),
        ]
    }

    /// Two messages waiting in the queue, one with pictures and files.
    static func queue(_ lane: ComposerLane) {
        let pictures = pictures(3).map { ImageAttachment(path: $0, mediaType: "image/png", width: 240, height: 180) }
        lane.enqueue(SteeredMessage(text: "Use estas também.", files: [URL(fileURLWithPath: file("orcamento.xlsx", size: 48_000)),
                                                                      URL(fileURLWithPath: file("fotos.zip", size: 5_200_000))],
                                    pictures: pictures, prompt: ""))
        lane.enqueue(SteeredMessage(text: "E me mande um resumo no fim.", files: [URL(fileURLWithPath: file("main.swift", size: 900))], prompt: ""))
    }
}
