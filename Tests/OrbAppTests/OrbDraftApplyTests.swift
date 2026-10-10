import Foundation
import Testing
@testable import Orb

/// The merge of one `orb_draft` call into the draft: what it takes, what it refuses, what it says changed.
@Suite struct OrbDraftApplyTests {
    private func args(_ json: String) -> JSONValue { JSONValue.parse(json) ?? .null }

    @Test func partialCallsFillTheDraftPieceByPiece() {
        var draft = OrbDraft()
        let first = draft.apply(args(#"{"name":"Maia","role":"Cuida da agenda"}"#))
        #expect(draft.name == "Maia" && draft.role == "Cuida da agenda")
        #expect(first.changed == [.name, .role] && first.rejected.isEmpty)
        #expect(draft.revision == 1 && draft.changed == [.name, .role])
        let second = draft.apply(args(#"{"instructions":"Você ajuda com a agenda.","mode":"auto"}"#))
        #expect(draft.name == "Maia", "what the call does not carry stays")
        #expect(draft.instructions == "Você ajuda com a agenda." && draft.mode == .auto)
        #expect(second.changed == [.instructions, .mode] && draft.revision == 2)
    }

    @Test func theDraftStartsWithWhatTheFormStartsWith() {
        var draft = OrbDraft()
        #expect(draft.capabilities == Bot(name: "x", role: "", orb: OrbConfig()).capabilities, "never a toolless Orb by omission")
        draft.apply(args(#"{"name":"Maia","mode":"auto"}"#))
        #expect(draft.capabilities == [.terminal, .browser, .computerUse], "a call that says nothing about it leaves it")
    }

    @Test func aValueEqualToTheCurrentOneIsNotAChange() {
        var draft = OrbDraft()
        draft.apply(args(#"{"name":"Maia"}"#))
        let again = draft.apply(args(#"{"name":"Maia"}"#))
        #expect(again.changed.isEmpty && draft.changed.isEmpty)
        #expect(draft.revision == 2, "each call counts")
    }

    @Test func theLookIsNotTheModelsToChoose() {
        var draft = OrbDraft()
        let before = draft.orb
        let report = draft.apply(args(#"{"name":"Maia","look":{"color":"menta","eyes":"ovais","hair":"franja","accessories":["laco"]}}"#))
        #expect(draft.orb == before, "an old model that still sends a look changes nothing")
        #expect(report.changed == [.name] && report.rejected.isEmpty, "and is not scolded")
        // Neither the tool nor the prompt offers it (every word is billed in every request).
        let schema = OrbDraftTool().spec.parameters.jsonString
        #expect(!schema.contains("\"look\"") && !schema.contains("mustache"))
        #expect(!WizardPrompt.system().contains("look that") && !WizardPrompt.system().contains(", look,"))
    }

    @Test func connectorsAndBypassAreNeverTaken() {
        var draft = OrbDraft()
        let report = draft.apply(args(#"{"capabilities":["terminal","connectors","telepatia"],"mode":"bypass"}"#))
        #expect(draft.capabilities == [.terminal])
        #expect(draft.mode == .ask, "bypass is refused and the mode stays")
        #expect(report.rejected.count == 3)
        #expect(report.rejected.contains { $0.hasPrefix("mode 'bypass'") })
        #expect(report.rejected.contains { $0.hasPrefix("capabilities 'connectors'") })
        draft.apply(args(#"{"mode":"readOnly","capabilities":[]}"#))
        #expect(draft.mode == .readOnly && draft.capabilities.isEmpty, "an empty list clears")
    }

    @Test func textIsCleanedAndCapped() {
        var draft = OrbDraft()
        let long = String(repeating: "Responda com calma. ", count: 200)
        draft.apply(args(#"{"name":"  \u0007Maia da Silva  ","role":"Linha um\nlinha dois"}"#))
        #expect(draft.name == "Maia da Silva")
        #expect(draft.role == "Linha um linha dois")
        draft.apply(.object(["instructions": .string(long)]))
        #expect(draft.instructions.count <= OrbDraft.instructionsLimit && draft.instructions.count > 1_000)
        draft.apply(.object(["name": .string(String(repeating: "a", count: 200))]))
        #expect(draft.name.count == OrbDraft.nameLimit)
        draft.apply(.object(["instructions": .string("Você é a Maia.\n\n\n- Seja breve.\nUse a chave sk-ant-abcdefghijklmnopqrstuvwxyz123456 sempre.")]))
        #expect(draft.instructions.contains("Você é a Maia.\n\n- Seja breve."))
        #expect(!draft.instructions.contains("sk-ant-abcdefghijklmnopqrstuvwxyz123456"), "a secret is scrubbed")
    }

    @Test func readyNeedsAName() {
        var draft = OrbDraft()
        let early = draft.apply(args(#"{"ready":true}"#))
        #expect(!draft.ready)
        #expect(early.rejected.contains { $0.hasPrefix("ready") })
        draft.apply(args(#"{"name":"Maia","ready":true}"#))
        #expect(draft.ready)
        draft.apply(args(#"{"ready":false}"#))
        #expect(!draft.ready)
    }

    @Test func theModelReadsTheDraftBackOneLinePerField() {
        var draft = OrbDraft()
        let report = draft.apply(args(#"{"name":"Maia","capabilities":["browser","telepatia"]}"#))
        let lines = draft.modelSummary(report).split(separator: "\n").map(String.init)
        #expect(lines.first == "name: Maia")
        #expect(lines.contains("capabilities: browser") && lines.contains("mode: ask") && lines.contains("ready: false"))
        #expect(lines.contains { $0.hasPrefix("rejected: capabilities 'telepatia'") })
        #expect(!lines.contains { $0.hasPrefix("look") }, "the look is not the model's: the draft does not tell it")
    }

    @Test func aCallThatIsNotAnObjectChangesNothing() {
        var draft = OrbDraft()
        let report = draft.apply(.string("oi"))
        #expect(report.changed.isEmpty && report.rejected.isEmpty && draft.name.isEmpty)
    }
}

@Suite struct OrbCreationModeTests {
    @Test func theAssistantIsTheDefaultWhenAModelIsConnected() {
        #expect(OrbCreationMode.initial(canConverse: true, prefersForm: false) == .assistant)
        #expect(OrbCreationMode.initial(canConverse: false, prefersForm: false) == .form)
        #expect(OrbCreationMode.initial(canConverse: true, prefersForm: true) == .form, "a kept memory or an import is the form's")
        #expect(OrbCreationMode.allCases.map(\.title) == ["Criar conversando", "Formulário"])
        #expect(NewOrbTab.allCases.map(\.title) == ["Quem ele é", "Aparência"])
    }

    @MainActor @Test func theWizardSnapshotModesAreRegistered() {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbWizardSnap-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false, secretVault: MemoryVault())
        for screen in ["wizard", "wizard-asking", "wizard-writing", "wizard-ready", "wizard-narrow", "wizard-failed", "wizard-form", "wizard-appearance"] {
            #expect(MultiOrbSnapshots.view(screen, model: model) != nil, "\(screen)")
        }
        #expect(WizardSnapshots.view("wizard-nao-existe", model: model) == nil)
        #expect(WizardSnapshots.view("events", model: model) == nil)
    }

    @MainActor @Test func theAppSaysWhetherAModelIsConnected() {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbWizardMode-\(UUID().uuidString)")
        defer { removeTestFolder(root) }
        let store = Store(directory: root)
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.providers = []
        model.defaultModel = ""
        #expect(!model.canCreateByConversing)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        #expect(model.canCreateByConversing)
        #expect(OrbCreationMode.initial(canConverse: model.canCreateByConversing, prefersForm: false) == .assistant)
    }
}
