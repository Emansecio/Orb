import Foundation
import Testing
@testable import Orb

// How the permission rules reach the browser tools, and how the browser note names them.

struct BrowserMCPPermissionTests {
    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> PermissionCall {
        let tool = ToolBox.all.first { $0.spec.name == name }!
        return PermissionPolicy.call(for: tool, arguments: .object(arguments), context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
    }

    private func verdict(_ name: String, _ arguments: [String: JSONValue] = [:], mode: PermissionMode = .ask,
                         rules: [PermissionRule] = []) -> PermissionVerdict {
        PermissionPolicy.evaluate(mode: mode, call: call(name, arguments), rules: rules, workspace: nil)
    }

    @Test func clickingAndTypingKeepTheirOwnFamilyAndRules() {
        for name in ["browse_click", "browse_fill", "browse_select", "browse_press", "browse_show"] {
            #expect(call(name).family == .browserPage, Comment(rawValue: name))
            #expect(verdict(name) == .ask(.needsPermission), Comment(rawValue: name))
            #expect(verdict(name, mode: .auto) == .allow && verdict(name, mode: .bypass) == .allow, Comment(rawValue: name))
            #expect(verdict(name, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), Comment(rawValue: name))
            #expect(verdict(name, rules: [PermissionRule(family: .browserPage)]) == .allow, Comment(rawValue: name))
            #expect(verdict(name, rules: [.host("a.test"), PermissionRule(family: .web, scope: .search)]) == .ask(.needsPermission), Comment(rawValue: name))
        }
    }

    @Test func openingAPageAsksLikeWebFetchAndIsCoveredBySiteRules() {
        let open: [String: JSONValue] = ["url": .string("https://docs.a.test/x")]
        #expect(call("browse_open", open).family == .web && call("browse_open", open).host == "docs.a.test")
        #expect(verdict("browse_open", open) == .ask(.needsPermission))
        #expect(verdict("browse_open", open, rules: [.host("a.test")]) == .allow)
        #expect(verdict("browse_open", open, rules: [.host("b.test")]) == .ask(.needsPermission))
        #expect(verdict("browse_open", open, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial))
    }

    @Test func theSearchIsAskedAndGrantedLikeWebSearch() {
        let search: [String: JSONValue] = ["query": .string("tempo em Lisboa")]
        #expect(PermissionPolicy.isSearch(call("web_search", search)))
        #expect(verdict("web_search", search) == .ask(.needsPermission))
        #expect(verdict("web_search", search, rules: [PermissionRule(family: .web, scope: .search)]) == .allow)
        #expect(verdict("web_search", search, rules: [.host("a.test")]) == .ask(.needsPermission))
        #expect(PermissionPolicy.suggestions(for: call("web_search", search)) == [PermissionRule(family: .web, scope: .search)])
    }

    @Test func lookingAtThePageAlreadyOpenAsksNothingButReadOnlyRefusesIt() {
        for name in ["browse_snapshot", "browse_read", "browse_screenshot"] {
            #expect(verdict(name) == .allow && verdict(name, mode: .auto) == .allow, Comment(rawValue: name))
            #expect(verdict(name, mode: .readOnly) == .deny(PermissionPolicy.readOnlyDenial), Comment(rawValue: name))
        }
    }

    @Test func aRuleSavedWithTheOldToolNameIsTheSameGrant() {
        // A rule saved before the Orb's tools were native (the CLI's name for them) is the same grant.
        let rule = PermissionRule(family: .browserPage)
        #expect(PermissionPolicy.isCovered(call("browse_click"), by: [rule]))
        #expect(PermissionPolicy.legacyRule(forToolName: PermissionPolicy.legacyOrbToolPrefix + "browse_click") == PermissionPolicy.legacyRule(forToolName: "browse_click"))
    }
}

struct BrowserMCPPromptTests {
    private func bot(_ mode: BrowserMode) -> Bot {
        var bot = Bot(name: "Atlas", role: "", orb: OrbConfig())
        bot.browserMode = mode
        return bot
    }

    @Test func theBrowserNoteNamesTheToolsPlainly() {
        let native = BrowserPrompt.section(bot: bot(.background), availability: .browser, status: BrowserStatus())
        #expect(native.contains("browse_open") && !native.contains("mcp__") && !native.contains("WebFetch"))
    }
}
