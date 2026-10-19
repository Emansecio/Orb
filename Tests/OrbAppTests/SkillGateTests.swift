import Foundation
import Testing
@testable import Orb

/// The gate that runs before the skill review (one short call on the cheap model): its request and how its answer is read.
struct SkillGateTests {
    @Test func theAnswerIsReadFromItsFirstWord() {
        #expect(SkillReview.gateSaysYes("YES") == true)
        #expect(SkillReview.gateSaysYes("  sim.\n") == true)
        #expect(SkillReview.gateSaysYes("Yes, because the user corrected it") == true)
        #expect(SkillReview.gateSaysYes("NO") == false)
        #expect(SkillReview.gateSaysYes("Não.") == false)
        #expect(SkillReview.gateSaysYes("nao") == false)
    }

    @Test func noiseIsNeitherYesNorNo() {
        #expect(SkillReview.gateSaysYes("") == nil)
        #expect(SkillReview.gateSaysYes("   ") == nil)
        #expect(SkillReview.gateSaysYes("maybe") == nil)
        #expect(SkillReview.gateSaysYes("I think yes") == nil)
        #expect(SkillReview.gateSaysYes("...") == nil)
    }

    @Test func theRequestCarriesTheInstructionsTheSkillNamesAndTheTranscript() {
        let messages = SkillReview.gatePrompt(transcript: "User: publica", skillNames: ["/publicar-site", "/resumir"])
        #expect(messages.count == 2 && messages[0].role == .system && messages[0].content == SkillReview.gateInstructions)
        #expect(messages[1].content.contains("/publicar-site, /resumir") && messages[1].content.hasSuffix("User: publica"))
        #expect(SkillReview.gatePrompt(transcript: "x", skillNames: [])[1].content.contains("already has: none"))
    }

    @Test func theTranscriptIsCutToTheGatesLimit() {
        let long = (0..<200).map { ChatMessage.user("passo \($0) " + String(repeating: "texto ", count: 100)) }
        let text = ChunkSummarizer.transcript(of: long[...], characters: SkillReview.gateCharacters)
        #expect(text.count <= SkillReview.gateCharacters + 200)
        #expect(text.count < ChunkSummarizer.transcript(of: long[...]).count)
    }

    @Test @MainActor func theGateUsesHaikuOnClaudeCodeAndNothingWhenItHasNone() {
        var code = ProviderAccount(kind: .claudeCode)
        code.models = ["sonnet", "claude-haiku-4-5"].map { ProviderModel(id: $0, name: $0, format: .claudeCode) }
        #expect(AppModel.skillGate(in: code, orb: "sonnet") == "claude-haiku-4-5")
        code.models = [ProviderModel(id: "sonnet", name: "sonnet", format: .claudeCode)]
        #expect(AppModel.skillGate(in: code, orb: "sonnet") == nil)
    }
}
