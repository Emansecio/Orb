import Foundation
import Testing
@testable import Orb

/// Dictation into the composer: how what is heard becomes the draft (`DictationText`) and how the button reads.
struct DictationTextTests {
    @Test func guessesAreReplacedAndSettledWordsKept() {
        var text = DictationText()
        text.take("Abre a", isFinal: false)
        text.take("Abre a planilha", isFinal: false)
        #expect(text.whole == "Abre a planilha")
        text.take("Abre a planilha.", isFinal: true)
        #expect(text.whole == "Abre a planilha." && text.guessing.isEmpty)
        text.take("Depois", isFinal: false)
        #expect(text.whole == "Abre a planilha. Depois")
        text.take(" Depois me manda.", isFinal: true)
        #expect(text.whole == "Abre a planilha. Depois me manda.")
    }

    @Test func whatIsSaidGoesAfterWhatWasTyped() {
        #expect(DictationText.draft(base: "", spoken: "  Oi") == "Oi")
        #expect(DictationText.draft(base: "Resuma", spoken: "o relatório") == "Resuma o relatório")
        #expect(DictationText.draft(base: "Resuma ", spoken: "o relatório") == "Resuma o relatório")
        #expect(DictationText.draft(base: "Linha um\n", spoken: "linha dois") == "Linha um\nlinha dois")
        #expect(DictationText.draft(base: "Resuma", spoken: "") == "Resuma")
    }
}

@MainActor struct DictationStateTests {
    @Test func theButtonAndTheHintFollowThePhase() {
        let dictation = Dictation()
        let botID = UUID(), other = UUID()
        #expect(!dictation.isActive(for: botID) && DictationButton.hint(dictation, botID: botID) == nil)
        dictation.pose(.listening, level: 0.5, for: botID)
        #expect(dictation.isActive(for: botID) && !dictation.isActive(for: other))
        #expect(DictationButton.hint(dictation, botID: botID)?.hasPrefix("Ouvindo") == true)
        #expect(DictationButton.hint(dictation, botID: other) == nil) // another Orb's composer says nothing
        #expect(DictationButton.symbol(.listening) == "mic.fill" && DictationButton.symbol(.idle) == "mic")
        // Typing in the field gives the dictation up; the same text written back by the field does not.
        dictation.draftEdited("oi", for: other)
        #expect(dictation.isActive(for: botID))
        dictation.draftEdited("digitei", for: botID)
        #expect(!dictation.isActive(for: botID) && dictation.level == 0)
    }

    @Test func aBuildThatCannotSayWhyItWantsTheMicrophoneShowsNoButton() {
        // The test runner has no Info.plist: asking for the microphone there would get the process killed.
        #expect(!Dictation.isSupported)
    }
}

import AVFoundation
import Speech

/// The microphone's path without a microphone: speech made by `say`, cut in the buffers a microphone gives, converted
/// as `SpeechCapture` converts them and streamed to the recognizer. Runs where macOS 26 has Portuguese installed.
struct DictationRecognizerTests {
    @Test func spokenPortugueseBecomesPunctuatedText() async throws {
        guard #available(macOS 26, *) else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "pt-BR")),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbDictation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appending(path: "fala.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Luciana", "-o", audio.path, "Abre a planilha de vendas e me manda um resumo, por favor."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, let file = try? AVAudioFile(forReading: audio) else { return } // no Portuguese voice

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let reader = Task {
            var text = DictationText(), guesses = 0
            for try await result in transcriber.results {
                if !result.isFinal { guesses += 1 }
                text.take(String(result.text.characters), isFinal: result.isFinal)
            }
            return (text, guesses)
        }
        try await analyzer.start(inputSequence: stream)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: format))
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer, frameCount: 4096)
            if let converted = SpeechCapture.convert(buffer, with: converter, to: format) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, guesses) = try await reader.value
        #expect(guesses > 0) // the words came while they were said, not only at the end
        let heard = text.whole.lowercased()
        #expect(heard.contains("planilha") && heard.contains("resumo"), "\(text.whole)")
        #expect(text.whole.hasSuffix(".") || text.whole.hasSuffix("?"), "\(text.whole)")
    }
}
