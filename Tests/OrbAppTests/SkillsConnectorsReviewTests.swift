import Foundation
import Testing
@testable import Orb

// The pure parts of the Skills and Conectores review: how a slug reads as a name, the line diff of an improvement,
// the effect badge of a connector tool and the split of the gallery into services and resources.

struct SkillTextTests {
    @Test func aSlugReadsAsASentenceWithItsInitialisms() {
        #expect(SkillText.displayName("publicar-lp-docker") == "Publicar LP docker")
        #expect(SkillText.displayName("resumir_pdf") == "Resumir PDF")
        #expect(SkillText.displayName("seo") == "SEO")
        #expect(SkillText.displayName("pdf") == "PDF")
    }

    @Test func aNameTheUserTypedKeepsItsCapitals() {
        #expect(SkillText.displayName("Resumir para o CEO") == "Resumir para o CEO")
        #expect(SkillText.displayName("organizar pasta") == "Organizar pasta")
    }

    @Test func edgeCases() {
        #expect(SkillText.displayName("") == "")
        #expect(SkillText.displayName("---") == "")
        #expect(SkillText.displayName("--a--b--") == "A b")
    }

    @Test func aRepeatedTitleIsDroppedOnlyWhenItIsTheSkillsName() {
        #expect(SkillText.droppingTitle("# Documentos\n\nTexto", matching: "documentos") == "Texto")
        #expect(SkillText.droppingTitle("# Outro\nTexto", matching: "Documentos") == "# Outro\nTexto")
        #expect(SkillText.droppingTitle("Texto\n# Documentos", matching: "Documentos") == "Texto\n# Documentos")
        #expect(SkillText.droppingTitle("# Documentos", matching: "Documentos") == "")
    }

    @Test func orbInitialSymbolFoldsAccentsAndFallsBack() {
        #expect(SkillText.orbInitialSymbol("Atlas") == "a.circle")
        #expect(SkillText.orbInitialSymbol("  Éter") == "e.circle")
        #expect(SkillText.orbInitialSymbol("") == "sparkles")
        #expect(SkillText.orbInitialSymbol("7 Orb") == "sparkles")
        #expect(SkillText.orbInitialSymbol("日本") == "sparkles")
    }
}

struct LineDiffTests {
    private func kinds(_ lines: [LineDiff.Line]) -> String {
        lines.map { $0.kind == .same ? "=" : $0.kind == .added ? "+" : "-" }.joined()
    }

    @Test func identicalTextsHaveNoChange() {
        let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nb\nc")
        #expect(lines.allSatisfy { $0.kind == .same } && lines.count == 3)
    }

    @Test func aChangedLineIsRemovedThenAdded() {
        let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nB\nc")
        #expect(kinds(lines) == "=-+=")
        #expect(lines[1].text == "b" && lines[2].text == "B")
    }

    @Test func insertionsAndDeletionsInTheMiddleKeepTheRest() {
        let lines = LineDiff.lines(old: "1\n2\n3\n4\n5", new: "1\n3\nx\n4\n5\n6")
        #expect(kinds(lines) == "=-=+==+")
    }

    @Test func emptySides() {
        #expect(kinds(LineDiff.lines(old: "", new: "a\nb")) == "-++")
        #expect(kinds(LineDiff.lines(old: "a\nb", new: "")) == "--+")
    }

    @Test func lineEndingsDoNotCountAsChanges() {
        #expect(LineDiff.lines(old: "a\r\nb", new: "a\nb").allSatisfy { $0.kind == .same })
    }

    @Test func aHugeMiddleFallsBackToReplacingItWhole() {
        let old = (0..<2_100).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<2_100).map { "new \($0)" }.joined(separator: "\n")
        let lines = LineDiff.lines(old: old, new: new)
        #expect(lines.count == 4_200 && lines.prefix(2_100).allSatisfy { $0.kind == .removed })
    }
}

struct ConnectorToolEffectTests {
    @Test func theThreeLevelsComeFromTheServersHints() {
        #expect(ToolEffect(MCPToolAnnotations(readOnly: true)) == .readOnly)
        #expect(ToolEffect(MCPToolAnnotations(destructive: true)) == .destructive)
        // A tool that writes without destroying (create_issue): readOnly false, destructive false or absent.
        #expect(ToolEffect(MCPToolAnnotations(readOnly: false, destructive: false)) == .modifies)
        #expect(ToolEffect(MCPToolAnnotations(readOnly: false)) == .modifies)
        #expect(ToolEffect(MCPToolAnnotations(destructive: false)) == .modifies)
    }

    @Test func destructiveWinsAndSilenceMakesNoClaim() {
        #expect(ToolEffect(MCPToolAnnotations(readOnly: true, destructive: true)) == .destructive)
        #expect(ToolEffect(.none) == .unknown)
        #expect(ToolEffect(MCPToolAnnotations(openWorld: true)) == .unknown)
    }

    @Test func aToolNameReadsAsAPhrase() {
        #expect(ConnectorToolText.title("create_issue") == "Create issue")
        #expect(ConnectorToolText.title("get-me") == "Get me")
        #expect(ConnectorToolText.title("") == "")
    }
}

struct ConnectorGallerySplitTests {
    @Test func memoryAndThinkingAreResourcesNotServices() {
        let features = Set(ConnectorGallery.featureCards.map(\.id))
        #expect(features == ["memoria", "pensamento"])
        #expect(ConnectorGallery.serviceCards.allSatisfy { !features.contains($0.id) })
        #expect(ConnectorGallery.serviceCards.count + ConnectorGallery.featureCards.count == ConnectorGallery.services.count)
    }
}
