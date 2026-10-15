import Foundation
@testable import Orb

/// One turn of a chat as the transcript shows it and as the model saw it: a question, a file read whose result is `output`, and the answer.
func storeTurn(_ n: Int, output: String) -> (items: [TranscriptItem], messages: [ChatMessage]) {
    let call = ToolCall(kind: .file, title: "Lendo", detail: "f\(n)", state: .done, output: output)
    return ([TranscriptItem(.user(text: "pergunta \(n)", attachments: [])), TranscriptItem(.tool(call)),
             TranscriptItem(.bot(text: "resposta \(n)", isStreaming: false))],
            [.user("pergunta \(n)"),
             ChatMessage(role: .assistant, content: "", toolCalls: [ToolCallRequest(id: "c\(n)", name: "read_file", arguments: "{}")]),
             .tool("c\(n)", output), ChatMessage(role: .assistant, content: "resposta \(n)")])
}

/// Writes `text` at `url`, creating the folders above it.
func put(_ text: String, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
