import Foundation
import Testing
@testable import Orb

/// `app_dictionary`: the sdef XML below is a made-up app, so nothing here needs a real one.
struct AppDictionaryTests {
    static let sdef = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dictionary xmlns:xi="http://www.w3.org/2001/XInclude">
      <xi:include href="file://localhost/System/Library/ScriptingDefinitions/CocoaStandard.sdef" xpointer="xpointer(/dictionary/suite)"/>
      <suite name="Notes Suite" code="note" description="Terms and Events for controlling the Notes application">
        <command name="show" code="noteshow" description="Show an object in the UI">
          <direct-parameter description="The object to be shown">
            <type type="folder"/>
            <type type="note"/>
          </direct-parameter>
          <parameter name="separately" code="sepa" type="boolean" optional="yes"/>
          <result description="The object shown."><type type="note"/></result>
        </command>
        <command name="secret" code="xxxxxxxx" hidden="yes"><direct-parameter type="text"/></command>
        <class-extension extends="application" description="the Notes application">
          <property name="default account" code="dfac" type="account" description="the default account"/>
          <property name="selection" code="seln" description="the selected note(s)"><type type="note" list="yes"/></property>
          <element type="folder"/>
          <element type="note"/>
        </class-extension>
        <class name="note" code="cnot" description="a note" inherits="item">
          <property name="name" code="pnam" type="text" description="the name"/>
          <property name="id" code="ID  " type="text" access="r"/>
          <property name="body" code="body" type="text"/>
          <property name="hidden bit" code="hidd" type="boolean" hidden="yes"/>
          <element type="attachment"/>
        </class>
        <enumeration name="save options" code="savo">
          <enumerator name="yes" code="yes "/>
          <enumerator name="no" code="no  "/>
        </enumeration>
      </suite>
      <suite name="Mail Suite" code="mail" description="Mail things">
        <command name="send" code="mailsend"><direct-parameter type="outgoing message"/></command>
      </suite>
    </dictionary>
    """

    private var dictionary: AppDictionary { AppDictionary.parse(Data(Self.sdef.utf8))! }

    @Test func readsSuitesCommandsClassesAndEnumerations() {
        let dictionary = dictionary
        #expect(dictionary.suites.map(\.name) == ["Notes Suite", "Mail Suite"])
        #expect(dictionary.includesStandardSuite)
        let notes = dictionary.suites[0]
        #expect(notes.commands.map(\.name) == ["show"], "hidden items are left out")
        #expect(notes.commands[0].direct == "folder|note")
        #expect(notes.commands[0].parameters == [.init(name: "separately", type: "boolean", optional: true)])
        #expect(notes.commands[0].result == "note")
        #expect(notes.classes.map(\.name) == ["application", "note"])
        #expect(notes.classes[0].isExtension)
        #expect(notes.classes[0].properties.map(\.type) == ["account", "[note]"])
        #expect(notes.classes[1].properties.map(\.name) == ["name", "id", "body"])
        #expect(notes.classes[1].properties[1].readOnly)
        #expect(notes.classes[1].elements == ["attachment"])
        #expect(notes.enumerations == [.init(name: "save options", values: ["yes", "no"])])
    }

    @Test func notXMLIsNotADictionary() {
        #expect(AppDictionary.parse(Data("sdef: couldn't get sdef".utf8)) == nil)
    }

    @Test func theListingIsCompact() {
        let text = dictionary.lines().joined(separator: "\n")
        #expect(text.contains("- cmd show <folder|note> separately?:boolean -> note  # Show an object in the UI"))
        #expect(text.contains("- class note (item): name:text, id:text ro, body:text; elements: attachment  # a note"))
        #expect(text.contains("- class application+: default account:account, selection:[note]; elements: folder, note"))
        #expect(text.contains("- enum save options: yes|no"))
        #expect(text.count < Self.sdef.count / 2)
    }

    @Test func searchKeepsOnlyWhatMatches() {
        let byName = dictionary.lines(search: "SEND").joined(separator: "\n")
        #expect(byName.contains("cmd send") && !byName.contains("cmd show") && byName.contains("## Mail Suite"))
        #expect(!byName.contains("Notes Suite"))
        // A property that matches shows alone, in its class.
        let property = dictionary.lines(search: "body")
        #expect(property.contains("- class note (item): body:text"))
        #expect(dictionary.lines(search: "nothing like this").isEmpty)
        // A parameter name finds its command.
        #expect(dictionary.lines(search: "separately").joined().contains("cmd show"))
    }

    @Test func aSuiteNarrowsTheListing() {
        let lines = dictionary.lines(suite: "mail")
        #expect(lines.first == "## Mail Suite  # Mail things")
        #expect(!lines.joined().contains("Notes"))
    }

    @Test func pagesStopAtTheLimitAndContinueFromTheOffset() {
        let lines = (0..<10).map { _ in String(repeating: "x", count: 99) }
        let first = AppDictionary.page(lines, offset: 0, limit: 350)
        #expect(first.text.split(separator: "\n").count == 3)
        #expect(first.next == 3)
        let second = AppDictionary.page(lines, offset: 3, limit: 350)
        #expect(second.next == 6)
        #expect(AppDictionary.page(lines, offset: 9, limit: 350).next == nil)
        // A line longer than the limit still comes out, so a page is never empty.
        #expect(AppDictionary.page([String(repeating: "y", count: 500)], offset: 0, limit: 100).text.count == 500)
        #expect(AppDictionary.page(lines, offset: 99, limit: 350).text.isEmpty)
    }

    // MARK: The tool

    private func fakeApp(named name: String, version: String = "1.0") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "orb-dict-\(UUID().uuidString)")
        let app = directory.appending(path: "\(name).app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try (plist as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func theToolAnswersWithTheListingAndCachesByVersion() async throws {
        let app = try fakeApp(named: "Fake Notes", version: "7")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let reads = Counter()
        let tool = AppDictionaryTool(readSdef: { _ in reads.bump(); return Data(Self.sdef.utf8) })
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let text = try await tool.run(.object(["app": .string(app.path)]), context: context)
        #expect(text.contains("Dicionário de Fake Notes (") && text.contains("2 suítes"))
        #expect(text.contains("- cmd show") && text.contains("Standard Suite"))
        let again = try await tool.run(.object(["app": .string(app.path), "search": .string("body")]), context: context)
        #expect(again.contains("body:text") && !again.contains("cmd show"))
        #expect(reads.count == 1, "the second call came from the cache")
    }

    @Test func anAppWithoutADictionarySaysSoAndPointsElsewhere() async throws {
        let app = try fakeApp(named: "Plain App")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let tool = AppDictionaryTool(readSdef: { _ in nil })
        let text = try await tool.run(.object(["app": .string(app.path)]),
                                      context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        #expect(text.contains("não tem dicionário") && text.contains("shortcuts_list") && text.contains("ui_read"))
    }

    @Test func aSearchWithoutMatchesListsTheSuites() async throws {
        let app = try fakeApp(named: "Fake Mail")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let tool = AppDictionaryTool(readSdef: { _ in Data(Self.sdef.utf8) })
        let text = try await tool.run(.object(["app": .string(app.path), "search": .string("zzz")]),
                                      context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
        #expect(text.contains("Nada no dicionário") && text.contains("Notes Suite, Mail Suite"))
    }

    @Test func anUnknownAppIsRefusedWithTheNextStep() async {
        let tool = AppDictionaryTool(readSdef: { _ in nil })
        do {
            _ = try await tool.run(.object(["app": .string("/nao/existe.app")]),
                                   context: ToolContext(workingDirectory: FileManager.default.temporaryDirectory))
            Issue.record("should have thrown")
        } catch { #expect(error.localizedDescription.contains("apps_list")) }
    }

    @Test func itOnlyReadsAndTheModelIsToldToUseIt() {
        let tool = AppDictionaryTool()
        #expect(tool.risk(.object([:])) == .safe)
        #expect(AppleScriptTool().spec.description.contains("app_dictionary"))
    }

    @Test func theRealSdefOfASystemAppParses() async throws {
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        guard FileManager.default.fileExists(atPath: notes.path) else { return }
        let data = try #require(try await AppDictionaryTool.liveSdef(notes))
        let parsed = try #require(AppDictionary.parse(data))
        #expect(parsed.suites.contains { $0.classes.contains { $0.name == "note" } })
        #expect(parsed.lines().joined(separator: "\n").count < data.count)
    }
}
