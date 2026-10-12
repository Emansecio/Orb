import Foundation
import Testing
@testable import Orb

/// Dictation into the composer: how what is heard becomes the draft (`DictationText`) and how the button reads.
struct DictationTextTests {
    @Test func theQuickWordsShowWhileTheyAreSaid() {
        var text = DictationText()
        text.take("Abre a", isFinal: false, end: 1)
        text.take("Abre a planilha", isFinal: false, end: 2)
        #expect(text.whole == "Abre a planilha")
        text.take("Abre a planilha de vendas", isFinal: true, end: 3)
        text.take("depois me", isFinal: false, end: 4)
        #expect(text.whole == "Abre a planilha de vendas depois me")
    }

    @Test func theExactSentenceTakesThePlaceOfTheQuickOneOverTheSameAudio() {
        var text = DictationText()
        text.take("O IRB abre a lista", isFinal: true, end: 7.74)
        text.take("e me manda um", isFinal: false, end: 8.7)
        // The exact recognizer ends its sentence a little before the quick one did: it still covers it.
        text.take("O Orb abre a lista.", isFinal: true, isExact: true, end: 7.68)
        #expect(text.whole == "O Orb abre a lista. e me manda um")
        text.take(" e me manda um resumo", isFinal: true, end: 9.88)
        text.take("E me manda um resumo, por favor.", isFinal: true, isExact: true, end: 9.88)
        #expect(text.whole == "O Orb abre a lista. E me manda um resumo, por favor.")
        // A quick piece of audio the exact recognizer already settled is not shown twice.
        text.take("por favor", isFinal: false, end: 9.8)
        text.take("por favor", isFinal: true, end: 9.9)
        #expect(text.whole == "O Orb abre a lista. E me manda um resumo, por favor.")
    }

    @Test func theExactDraftShowsPunctuatedBeforeItsSentencesSettle() {
        var text = DictationText()
        text.take("abre a planilha de vendas e me manda um resumo", isFinal: true, end: 11)
        text.take("por favor", isFinal: false, end: 12)
        // At the end of the window it heard, the exact recognizer's draft takes the place of the quick words under it.
        text.take("Abre a planilha de vendas e me manda um resumo,", isFinal: false, isExact: true, end: 11.2)
        #expect(text.whole == "Abre a planilha de vendas e me manda um resumo, por favor")
        // A sentence settled out of the draft's beginning leaves only the rest of it, without saying it twice.
        text.take("Abre a planilha de vendas.", isFinal: true, isExact: true, end: 5)
        #expect(text.whole == "Abre a planilha de vendas. e me manda um resumo, por favor")
        // The sentence that reaches the draft's end takes it all.
        text.take("E me manda um resumo, por favor.", isFinal: true, isExact: true, end: 12)
        #expect(text.whole == "Abre a planilha de vendas. E me manda um resumo, por favor.")
        #expect(text.exactDraft == nil && text.quick.isEmpty)
    }

    @Test func aDraftLosesASettledSentenceByItsTextOrByItsWords() {
        let draft = DictationText.Sentence(text: "Abre a planilha. Me manda o resumo", end: 9)
        #expect(DictationText.drafted(draft, after: "Abre a planilha.") == .init(text: "Me manda o resumo", end: 9))
        // Reworded when it settled: as many words come off.
        #expect(DictationText.drafted(draft, after: "Abra a planilha.") == .init(text: "Me manda o resumo", end: 9))
        #expect(DictationText.drafted(draft, after: "Abre a planilha. Me manda o resumo") == nil)
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

    /// The halo rises with the voice at once and falls back slowly: a pause between syllables does not drop it to nothing.
    @Test func theHaloRisesFastAndFallsSlowly() {
        let risen = Dictation.envelope(0, toward: 1)
        #expect(risen > 0.5 && risen < 1)
        var level: Float = 1
        level = Dictation.envelope(level, toward: 0)
        #expect(level > 0.7) // one quiet buffer (a tenth of a second) keeps most of it
        for _ in 0..<15 { level = Dictation.envelope(level, toward: 0) }
        #expect(level < 0.02) // a second and a half of silence lets it go
        #expect(Dictation.envelope(0.4, toward: 0.4) == 0.4)
    }

    @Test func aBuildThatCannotSayWhyItWantsTheMicrophoneShowsNoButton() {
        // The test runner has no Info.plist: asking for the microphone there would get the process killed.
        #expect(!Dictation.isSupported)
    }
}

import AVFoundation
import Speech

/// The microphone's path without a microphone: speech made by `say`, handed to `SpeechCapture` in the buffers a
/// microphone gives and at the pace of speech. Runs where macOS 26 has Portuguese installed.
struct DictationRecognizerTests {
    @MainActor private final class Heard {
        var text = DictationText()
        var shownBeforeTheEnd = ""
        var audioEnded = false
        func take(_ piece: String, _ isFinal: Bool, _ isExact: Bool, _ end: Double) {
            text.take(piece, isFinal: isFinal, isExact: isExact, end: end)
            if !audioEnded { shownBeforeTheEnd = text.whole }
        }
    }

    @Test @MainActor func theWordsShowWhileTheyAreSaidAndTheExactTextStays() async throws {
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

        let heard = Heard()
        let capture = SpeechCapture()
        capture.listensToMicrophone = false
        try await capture.start(locale: locale, vocabulary: [], downloading: {}, heard: { heard.take($0, $1, $2, $3) }, level: { _ in })
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer, frameCount: 4096)
            capture.feed(buffer)
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / buffer.format.sampleRate)) // as fast as it is said
        }
        heard.audioEnded = true
        await capture.finish()
        // Most of it showed while it was said, not only once the microphone closed.
        #expect(heard.shownBeforeTheEnd.lowercased().contains("planilha"), "\(heard.shownBeforeTheEnd)")
        let final = heard.text.whole
        #expect(final.lowercased().contains("planilha") && final.lowercased().contains("resumo"), "\(final)")
        #expect(!heard.text.settled.isEmpty && heard.text.quick.isEmpty, "the exact text is what stays")
        #expect(final.hasSuffix("."), "\(final)")
    }
}
