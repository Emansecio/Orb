import AppKit
import Foundation
import Testing
@testable import Orb

/// Parsing, formatting, error translation and wiring of the Mac tools. Anything that needs a system permission
/// (Automation, Screen Recording, notifications) or touches the user's apps, Trash or clipboard is not run here.
struct MacToolTests {
    private let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

    private func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: context)
    }

    private func message(from body: () async throws -> String) async -> String {
        do { _ = try await body(); return "" } catch { return error.localizedDescription }
    }

    // MARK: Registry

    @Test func invalidIndexIsNotBlamedOnAccessibility() {
        let invalid = AppleScript.explain("execution error: System Events got an error: Can’t get window 1 of process \"Finder\". Invalid index. (-1719)")
        #expect(!invalid.contains("Acessibilidade"))
        #expect(invalid.contains("Invalid index"))
        let blocked = AppleScript.explain("execution error: osascript não tem acesso assistiva. (-1719)")
        #expect(blocked.contains("Acessibilidade"))
    }

    @Test func commonScriptErrorsComeWithAdvice() {
        let cases: [(Int, String)] = [(-30720, "current date"), (-1728, "Liste os nomes"), (-1708, "vocabulário"), (-2741, "Erro de sintaxe")]
        for (code, hint) in cases {
            let text = AppleScript.explain("execution error: algo deu errado. (\(code))")
            #expect(text.contains(hint), Comment(rawValue: "\(code)"))
            #expect(text.contains("algo deu errado"))
            #expect(!text.contains("Abrir Ajustes") && !text.contains("Permissões do Mac"))
        }
    }

    @Test func registersEveryMacToolWithTheRightCapabilityAndRisk() {
        let tools = Dictionary(uniqueKeysWithValues: ToolBox.macTools.map { ($0.spec.name, $0) })
        let expected: [(name: String, risk: ToolRisk, capability: Capability?)] = [
            ("shortcuts_list", .safe, .computerUse), ("shortcuts_run", .sensitive, .computerUse),
            ("clipboard_read", .safe, .computerUse), ("clipboard_write", .sensitive, .computerUse),
            ("screenshot", .safe, .computerUse), ("notify", .safe, nil),
            ("apps_list", .safe, .computerUse), ("processes", .safe, .computerUse),
            ("app_quit", .sensitive, .computerUse), ("trash", .sensitive, .terminal),
            ("applescript", .sensitive, .computerUse), ("browser_tab", .safe, .computerUse),
            ("open", .sensitive, nil),
        ]
        for item in expected {
            guard let tool = tools[item.name] else { Issue.record("missing tool \(item.name)"); continue }
            #expect(tool.risk(.object([:])) == item.risk, "\(item.name) risk")
            #expect(tool.capability == item.capability, "\(item.name) capability")
            #expect(!tool.spec.description.isEmpty)
        }
        #expect(Set(ToolBox.all.map(\.spec.name)).count == ToolBox.all.count, "tool names must be unique")
    }

    @Test func newOrbsGetMacAccessButSavedOnesKeepTheirSettings() throws {
        #expect(Bot(name: "Novo", role: "", orb: OrbConfig()).capabilities.contains(.computerUse))
        let saved = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Velho","capabilities":["terminal"]}"#.utf8))
        #expect(saved.capabilities == [.terminal])
    }

    // MARK: AppleScript errors

    @Test func extractsTheErrorNumberWhateverTheLanguage() {
        #expect(AppleScript.errorCode(in: "27:30: execution error: Not authorized to send Apple events to Mail. (-1743)\n") == -1743)
        #expect(AppleScript.errorCode(in: "execution error: Não é permitido enviar eventos da Apple para o Mail. (-1743)") == -1743)
        #expect(AppleScript.errorCode(in: "syntax error: Expected end of line. (-2741)") == -2741)
        #expect(AppleScript.errorCode(in: "no number here") == nil)
        #expect(AppleScript.errorCode(in: "the (12) is not at the end") == nil)
    }

    @Test func translatesPermissionAndAvailabilityErrors() {
        let automation = AppleScript.explain("execution error: Not authorized to send Apple events to Mail. (-1743)")
        #expect(automation.contains("Automação"))
        #expect(automation.contains("Privacidade e Segurança"))
        #expect(automation.contains("(-1743)"), "keeps the system detail")

        for code in [-1719, -25211] {
            let advice = AppleScript.explain("execution error: osascript is not allowed assistive access. (\(code))")
            #expect(advice.contains("Acessibilidade"))
        }
        let notRunning = AppleScript.explain("execution error: Application isn’t running. (-600)")
        #expect(notRunning.contains("não está aberto"))
        #expect(notRunning.contains("open"))
        #expect(AppleScript.timeoutMessage(seconds: 60).contains("aviso de permissão"))
    }

    @Test func unknownErrorsPassThroughUnchanged() {
        let message = "27:30: execution error: A variável foo não está definida. (-2753)"
        #expect(AppleScript.explain(message) == message)
        #expect(AppleScript.explain("", status: 7).contains("código 7"))
    }

    // MARK: applescript tool

    @Test func runsJavaScriptForAutomationAndStructuredOutput() async throws {
        let tool = AppleScriptTool()
        let js = try await run(tool, ["script": .string("[1, 2, 3].map(n => n * 2).join('-')"), "language": .string("javascript")])
        #expect(js == "2-4-6")

        let plain = try await run(tool, ["script": .string("return {\"a\", 1}")])
        let structured = try await run(tool, ["script": .string("return {\"a\", 1}"), "output": .string("structured")])
        #expect(plain == "a, 1")
        #expect(structured == "{\"a\", 1}")
    }

    @Test func rejectsUnknownLanguageAndOutputBeforeRunning() async {
        let language = await message { try await run(AppleScriptTool(), ["script": .string("1"), "language": .string("ruby")]) }
        #expect(language.contains("ruby"))
        let output = await message { try await run(AppleScriptTool(), ["script": .string("1"), "output": .string("xml")]) }
        #expect(output.contains("xml"))
    }

    @Test func scriptErrorsComeBackAsToolErrors() async {
        let syntax = await message { try await run(AppleScriptTool(), ["script": .string("this is not valid ((")]) }
        #expect(!syntax.isEmpty)
    }

    // MARK: open

    @Test func hostAndPortIsNotParsedAsAScheme() {
        #expect(OpenTarget.classify("localhost:3000") == .url(URL(string: "http://localhost:3000")!))
        #expect(OpenTarget.classify("localhost:5173/app?x=1") == .url(URL(string: "http://localhost:5173/app?x=1")!))
        #expect(OpenTarget.classify("127.0.0.1:8080") == .url(URL(string: "http://127.0.0.1:8080")!))
        #expect(OpenTarget.classify("minha-maquina.local:9000") == .url(URL(string: "http://minha-maquina.local:9000")!))
        #expect(OpenTarget.classify("example.com:8443/x") == .url(URL(string: "https://example.com:8443/x")!))
    }

    @Test func realUrlsPathsAndNamesKeepWorking() {
        #expect(OpenTarget.classify("https://example.com/a?b=c") == .url(URL(string: "https://example.com/a?b=c")!))
        #expect(OpenTarget.classify("obsidian://open?vault=x") == .url(URL(string: "obsidian://open?vault=x")!))
        #expect(OpenTarget.classify("mailto:a@b.com") == .url(URL(string: "mailto:a@b.com")!))
        #expect(OpenTarget.classify("x-apple.systempreferences:com.apple.preference.security") != .pathOrName("x-apple.systempreferences:com.apple.preference.security"))
        #expect(OpenTarget.opaqueURL("spotify:track:4uLU6hMCjMI75M1A2tKUQC") == URL(string: "spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        #expect(OpenTarget.opaqueURL("magnet:?xt=urn:btih:abc") != nil)
        #expect(OpenTarget.opaqueURL("about:blank") != nil)
        #expect(OpenTarget.opaqueURL("localhost:3000") == nil, "host and port")
        #expect(OpenTarget.opaqueURL("Safari") == nil)
        #expect(OpenTarget.opaqueURL("Nota: lista de compras") == nil)
        #expect(OpenTarget.opaqueURL("C:/Users/x") == nil)
        #expect(OpenTarget.classify("www.apple.com") == .url(URL(string: "https://www.apple.com")!))
        #expect(OpenTarget.classify("~/Desktop/a.png") == .pathOrName("~/Desktop/a.png"))
        #expect(OpenTarget.classify("relatorio.pdf") == .pathOrName("relatorio.pdf"))
        #expect(OpenTarget.classify("  Safari ") == .pathOrName("Safari"))
        #expect(OpenTarget.classify("com.apple.Safari") == .pathOrName("com.apple.Safari"))
    }

    @Test func picksTheRightAppAmongSpotlightResults() {
        let paths = [
            "/Applications/Xcode.app/Contents/Applications/Instruments.app",
            "/Users/x/Downloads/Safari.app",
            "/Users/x/Applications/Safari.app",
            "/Applications/Safari.app",
            "/System/Volumes/Data/Applications/Safari.app/Contents/helper.txt",
            "/Users/x/.Trash/Safari.app",
        ]
        #expect(ApplicationLookup.best(in: paths, named: "Safari") == "/Applications/Safari.app")
        #expect(ApplicationLookup.best(in: ["/Applications/Xcode.app/Contents/Applications/Instruments.app"], named: "Instruments") == nil)
        #expect(ApplicationLookup.best(in: [], named: "x") == nil)
        #expect(ApplicationLookup.best(in: ["/Volumes/Disco/Apps/Foo.app", "/Volumes/D/Foo.app"], named: "Foo") == "/Volumes/D/Foo.app")
    }

    @Test func spotlightQueryEscapesTheName() {
        let query = ApplicationLookup.spotlightQuery(for: #"Meu "App" *"#)
        #expect(query.contains(#"kMDItemDisplayName == "Meu \"App\" ""#))
        #expect(!query.contains("*"))
        #expect(ApplicationLookup.spotlightQuery(for: "Notes.app").contains(#"== "Notes"cd"#))
    }

    @Test func openingWithAnUnknownAppFailsClearly() async {
        let missing = await message {
            try await run(OpenTool(), ["target": .string("https://example.com"), "app": .string("Aplicativo Que Nao Existe 9271")])
        }
        #expect(missing.contains("Não encontrei o app"))
        let nothing = await message { try await run(OpenTool(), ["target": .string("arquivo-que-nao-existe-9271.txt")]) }
        #expect(nothing.contains("Não encontrei"))
    }

    @Test func browserTabReadsTheFrontBrowserOnlyWhenOneIsInFront() {
        let open: [DesktopBrowser] = [.safari, .chrome]
        #expect(BrowserTabTool.choose(open, frontmostBundleID: DesktopBrowser.chrome.bundleID) == [.chrome])
        #expect(BrowserTabTool.choose(open, frontmostBundleID: DesktopBrowser.safari.bundleID) == [.safari])
        // The Orb (or any other app) is in front: the user may be looking at either, so both are read.
        #expect(BrowserTabTool.choose(open, frontmostBundleID: "com.example.orb") == open)
        #expect(BrowserTabTool.choose(open, frontmostBundleID: nil) == open)
        // A front browser that is not among the open ones changes nothing.
        #expect(BrowserTabTool.choose([.safari], frontmostBundleID: DesktopBrowser.arc.bundleID) == [.safari])
        // The Orb in front: the browser whose window is nearest the front is the one the user means.
        let owners = ["com.example.orb", DesktopBrowser.chrome.bundleID, "com.apple.finder", DesktopBrowser.safari.bundleID]
        #expect(BrowserTabTool.choose(open, frontmostBundleID: "com.example.orb", windowOwners: owners) == [.chrome])
        #expect(BrowserTabTool.choose(open, frontmostBundleID: nil, windowOwners: owners.reversed()) == [.safari])
        // A browser with no window on screen is not picked over the others; a front browser still wins over the order.
        #expect(BrowserTabTool.choose(open, frontmostBundleID: "com.example.orb", windowOwners: ["com.apple.finder"]) == open)
        #expect(BrowserTabTool.choose([.safari], frontmostBundleID: "com.example.orb", windowOwners: [DesktopBrowser.arc.bundleID]) == [.safari])
        #expect(BrowserTabTool.choose(open, frontmostBundleID: DesktopBrowser.safari.bundleID, windowOwners: owners) == [.safari])
        #expect(BrowserTabTool().spec.parameters.jsonString.contains("all"))
    }

    @Test func openingProgramsInstallersAndShortcutLinksIsDangerous() {
        let home = "/Users/maria"
        for target in ["~/Downloads/instalar.command", "/tmp/x.sh", "run.zsh", "Instalador.PKG", "disco.dmg", "file:///tmp/a.scpt",
                       "~/Downloads/Coisa.app", "/Volumes/USB/Coisa.app/", "shortcuts://run-shortcut?name=Teste",
                       "shortcuts://x-callback-url/run-shortcut?name=a", "shortcuts:run-shortcut?name=b"] {
            #expect(OpenTool.danger(target: target, home: home) != nil, Comment(rawValue: target))
        }
        for target in ["https://example.com", "localhost:3000", "~/Documents/relatorio.pdf", "/Applications/Safari.app",
                       "/System/Applications/Calculator.app", "/Users/maria/Applications/Meu.app", "Safari", "Safari.app", "Notas",
                       "mailto:a@b.com", "shortcuts://open-shortcut?name=Teste", "x-apple.systempreferences:com.apple.preference.security"] {
            #expect(OpenTool.danger(target: target, home: home) == nil, Comment(rawValue: target))
        }
        let call = PermissionPolicy.call(for: OpenTool(), arguments: .object(["target": .string("~/Downloads/instalar.command")]), context: context)
        #expect(call.danger != nil)
        #expect(PermissionPolicy.evaluate(mode: .auto, call: call, rules: [], workspace: nil) == .ask(.dangerous(call.danger ?? "")))
    }

    @Test func openingAnExecutableOrAnAppThroughDotDotIsDangerous() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "instalar")
        try Data("#!/bin/sh\necho oi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let note = folder.appending(path: "leia-me")
        try Data("texto".utf8).write(to: note)
        try FileManager.default.createDirectory(at: folder.appending(path: "Documentos"), withIntermediateDirectories: true)

        #expect(OpenTool.danger(target: script.path, home: "/Users/maria") != nil)
        #expect(OpenTool.danger(target: "instalar", home: "/Users/maria", directory: folder) != nil, "a relative path resolves in the Orb's folder")
        #expect(OpenTool.danger(target: "./instalar", home: "/Users/maria", directory: folder) != nil)
        #expect(OpenTool.danger(target: note.path, home: "/Users/maria") == nil, "not executable")
        #expect(OpenTool.danger(target: folder.appending(path: "Documentos").path, home: "/Users/maria") == nil, "a folder")
        #expect(OpenTool.danger(target: "instalar", home: "/Users/maria") == nil, "a bare name is an app name when there is no folder to look in")
        // `..` cannot make a path look like it is in /Applications.
        #expect(OpenTool.danger(target: "/Applications/../Users/maria/Downloads/Evil.app", home: "/Users/maria") != nil)
        #expect(OpenTool.danger(target: "/Applications/./Safari.app", home: "/Users/maria") == nil)
        #expect(OpenTool.danger(target: "~/Applications/../Downloads/Evil.app", home: NSHomeDirectory()) != nil)
        #expect(OpenTool.danger(target: "Evil.app", home: "/Users/maria", directory: folder) == nil, "no such file here: the system looks the app up")
        try FileManager.default.createDirectory(at: folder.appending(path: "Evil.app"), withIntermediateDirectories: true)
        #expect(OpenTool.danger(target: "Evil.app", home: "/Users/maria", directory: folder) != nil, "an app in the Orb's folder is opened from there")
        // Through the permission policy the working folder is the Orb's.
        let ctx = ToolContext(workingDirectory: folder)
        let call = PermissionPolicy.call(for: OpenTool(), arguments: .object(["target": .string("instalar")]), context: ctx)
        #expect(call.danger != nil)
    }

    @Test func aShortcutLinkNeedsTheMacCapability() async {
        var off = context
        off.computerUseAllowed = false
        let refused = await message { try await OpenTool().run(.object(["target": .string("shortcuts://run-shortcut?name=Teste")]), context: off) }
        #expect(refused.contains("Controlar apps do Mac"))
        // Everything else `open` does stays available.
        #expect(!OpenTool.runsShortcut("https://example.com"))
        #expect(OpenTool.runsShortcut(" Shortcuts://run-shortcut?name=x "))
    }

    @Test func theMCPServerContextCarriesTheMacSwitch() {
        let directory = URL(fileURLWithPath: "/tmp/m")
        #expect(OrbToolsMCPServer.Options(memoryDirectory: directory, mac: true).context.computerUseAllowed)
        #expect(!OrbToolsMCPServer.Options(memoryDirectory: directory).context.computerUseAllowed)
    }

    @Test func findsApplicationsThroughLaunchServices() async throws {
        let finder = await OpenTool.application(named: "com.apple.finder")
        #expect(finder?.lastPathComponent == "Finder.app")
        let calculator = await OpenTool.application(named: "com.apple.calculator")
        #expect(calculator != nil)
        let unknown = await OpenTool.application(named: "Aplicativo Que Nao Existe 9271")
        #expect(unknown == nil)
    }

    // MARK: Shortcuts

    @Test func formatsTheShortcutsList() {
        let output = "Adicionar Água\nNovo Atalho\n\n  Enviar Localização  \n"
        let all = ShortcutsFormatter.listing(output, filter: nil)
        #expect(all.hasPrefix("3 atalhos:"))
        #expect(all.contains("- Enviar Localização"))
        #expect(ShortcutsFormatter.listing(output, filter: "agua").contains("- Adicionar Água"))
        #expect(ShortcutsFormatter.listing(output, filter: "xyz") == "Nenhum atalho com \"xyz\" no nome (3 no total).")
        #expect(ShortcutsFormatter.listing("", filter: nil) == "O usuário não tem nenhum atalho.")

        let many = (1...400).map { "Atalho \($0)" }.joined(separator: "\n")
        #expect(ShortcutsFormatter.listing(many, filter: nil).contains("mais 100"))
    }

    @Test func formatsTheShortcutResult() {
        #expect(ShortcutsFormatter.result(name: "A", output: Data("olá\n".utf8), console: "") == "olá")
        #expect(ShortcutsFormatter.result(name: "A", output: nil, console: "").contains("não devolveu resultado"))
        #expect(ShortcutsFormatter.result(name: "A", output: Data([0xFF, 0xFE, 0x00]), console: "").contains("não é texto"))
    }

    @Test func shortcutNamesCannotBeOptions() async {
        let text = await message { try await run(ShortcutsRunTool(), ["name": .string("--help")]) }
        #expect(text.contains("inválido"))
    }

    // MARK: Clipboard

    @Test func clipboardFormatting() {
        #expect(ClipboardFormatter.describe(ClipboardSnapshot()).contains("vazia"))
        let text = ClipboardFormatter.describe(ClipboardSnapshot(text: "oi"))
        #expect(text == "Texto (2 caracteres):\noi")
        let files = ClipboardFormatter.describe(ClipboardSnapshot(text: "a.txt", files: ["/tmp/a.txt", "/tmp/b.txt"]))
        #expect(files.contains("Arquivos copiados (2):\n- /tmp/a.txt\n- /tmp/b.txt"))
        #expect(ClipboardFormatter.describe(ClipboardSnapshot(hasImage: true)).contains("imagem"))
        let long = ClipboardFormatter.describe(ClipboardSnapshot(text: String(repeating: "x", count: 30_000)))
        #expect(long.contains("caracteres omitidos"))
    }

    @MainActor @Test func clipboardRoundTripOnAPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.orb.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(ClipboardSnapshot.read(from: pasteboard).text == nil)
        #expect(ClipboardSnapshot.write("olá, mundo", to: pasteboard))
        #expect(ClipboardSnapshot.read(from: pasteboard) == ClipboardSnapshot(text: "olá, mundo"))

        let file = FileManager.default.temporaryDirectory.appending(path: "orb-clip-\(UUID().uuidString).txt")
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(ClipboardSnapshot.read(from: pasteboard).files == [file.path])
    }

    // MARK: Apps and processes

    private let apps = [
        RunningAppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 10, isActive: true, isHidden: false, isRegular: true),
        RunningAppInfo(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 20, isActive: false, isHidden: true, isRegular: true),
        RunningAppInfo(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 21, isActive: false, isHidden: true, isRegular: true),
        RunningAppInfo(name: "Calendário", bundleID: "com.apple.iCal", pid: 30, isActive: false, isHidden: false, isRegular: true),
        RunningAppInfo(name: "Google Drive", bundleID: "com.google.drivefs", pid: 40, isActive: false, isHidden: false, isRegular: false),
    ]

    @Test func matchesRunningAppsByNameOrBundleId() {
        #expect(RunningAppMatcher.match("safari", in: apps) == .found([apps[0]]))
        #expect(RunningAppMatcher.match("COM.APPLE.SAFARI", in: apps) == .found([apps[0]]))
        #expect(RunningAppMatcher.match("calendario", in: apps) == .found([apps[3]]))
        #expect(RunningAppMatcher.match("Google Chrome", in: apps) == .found([apps[1], apps[2]]), "all instances")
        #expect(RunningAppMatcher.match("chrome", in: apps) == .found([apps[1], apps[2]]), "partial, one app")
        #expect(RunningAppMatcher.match("google", in: apps) == .ambiguous([apps[1], apps[2], apps[4]]))
        #expect(RunningAppMatcher.match("Pages", in: apps) == .none)
        #expect(RunningAppMatcher.match("  ", in: apps) == .none)
    }

    @Test func formatsTheRunningAppsList() {
        let text = AppListFormatter.format([apps[1], apps[0], apps[4]])
        #expect(text.hasPrefix("3 apps abertos:"))
        #expect(text.contains("- Safari (com.apple.Safari) · pid 10 · em primeiro plano"))
        #expect(text.contains("- Google Chrome (com.google.Chrome) · pid 20 · oculto"))
        #expect(text.contains("em segundo plano"))
        #expect(text.range(of: "Google Chrome")!.lowerBound < text.range(of: "Safari")!.lowerBound, "sorted by name")
        #expect(AppListFormatter.format([]) == "Nenhum app aberto.")
    }

    @Test func listsTheAppsRunningNow() async throws {
        let text = try await run(AppsListTool(), [:])
        #expect(text.contains("pid") || text == "Nenhum app aberto.")
    }

    @Test func parsesPsOutput() {
        let output = """
          402  39.7  0.5  80032 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        53948  19,0  3.9 660864 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
        garbage line
         1  0.0  0.0  1024 launchd

        """
        let rows = ProcessListParser.parse(output)
        #expect(rows.count == 3)
        #expect(rows[0] == ProcessInfoRow(pid: 402, cpu: 39.7, memoryPercent: 0.5, residentKB: 80032,
                                          command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"))
        #expect(rows[0].name == "WindowServer")
        #expect(rows[1].name == "Google Chrome")
        #expect(rows[1].cpu == 19.0)
        #expect(ProcessListParser.megabytes(660_864) == "645 MB")
        #expect(ProcessListParser.megabytes(2_097_152) == "2.0 GB")
        let table = ProcessListParser.format(rows, sortedBy: "cpu")
        #expect(table.hasPrefix("Maiores consumidores de CPU"))
        #expect(table.contains("402 · 39.7% · 78 MB (0.5%) · WindowServer"))
    }

    @Test func processesToolReturnsTheBusiestOnes() async throws {
        let text = try await run(ProcessesTool(), ["limit": .number(5)])
        #expect(text.split(separator: "\n").count == 6)
        let byMemory = try await run(ProcessesTool(), ["sort": .string("memory"), "limit": .number(3)])
        #expect(byMemory.contains("memória"))
    }

    // MARK: app_quit

    @Test func forcedQuitIsDangerousButANormalOneIsNot() {
        let tool = AppQuitTool()
        #expect(tool.danger(.object(["app": .string("Safari"), "force": .bool(true)])) != nil)
        #expect(tool.danger(.object(["app": .string("Safari"), "force": .bool(false)])) == nil)
        #expect(tool.danger(.object(["app": .string("Safari")])) == nil)
        #expect(tool.summary(.object(["app": .string("Safari"), "force": .bool(true)])).title == "Forçando o encerramento")
    }

    @Test func quitOnlyAcceptsExactNamesAndOffersSimilarOnes() throws {
        let mail = RunningAppInfo(name: "Mailspring", bundleID: "com.foundry376.mailspring", pid: 50, isActive: false, isHidden: false, isRegular: true)
        let running = apps + [mail]
        #expect(try AppQuitTool.select("safari", in: running, ownPID: 1) == [apps[0]])
        #expect(try AppQuitTool.select("com.google.Chrome", in: running, ownPID: 1) == [apps[1], apps[2]])
        // "Mail" is not running and only Mailspring contains it: nothing is quit, Mailspring is suggested.
        do {
            _ = try AppQuitTool.select("Mail", in: running, ownPID: 1)
            Issue.record("a partial match must not be accepted")
        } catch let error as ToolError {
            #expect(error.message.contains("Mailspring"))
            #expect(error.message.contains("nome exato"))
        }
        #expect(RunningAppMatcher.match("Mail", in: running, exactOnly: true) == .none)
        #expect(RunningAppMatcher.match("mailspring", in: running, exactOnly: true) == .found([mail]))
        #expect(throws: ToolError.self) { try AppQuitTool.select("Pages", in: running, ownPID: 1) }
    }

    @Test func quitRefusesTheOrbItself() {
        do {
            _ = try AppQuitTool.select("safari", in: apps, ownPID: 10)
            Issue.record("the Orb must not quit itself")
        } catch let error as ToolError {
            #expect(error.message.contains("próprio Orb"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func quitReportsUnknownAppsAndRefusesTheOrbItself() async {
        let unknown = await message { try await run(AppQuitTool(), ["app": .string("Aplicativo Que Nao Existe 9271")]) }
        #expect(unknown.contains("apps_list"))
        let nothing = await message { try await run(AppQuitTool(), [:]) }
        #expect(nothing.contains("app"))
    }

    // MARK: Trash

    private func fakeTrash() throws -> (folder: URL, trasher: @Sendable (URL) throws -> URL?) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbFakeTrash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { url in
            let destination = folder.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    @Test func trashMovesItemsAndSaysWhereTheyWent() async throws {
        let (trash, trasher) = try fakeTrash()
        let work = FileManager.default.temporaryDirectory.appending(path: "OrbTrashWork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trash); try? FileManager.default.removeItem(at: work) }
        try "a".write(to: work.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: work.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let tool = TrashTool(trasher: trasher)
        let output = try await tool.run(.object(["paths": .array(["a.txt", work.appending(path: "b.txt").path, "missing.txt"].map(JSONValue.string))]),
                                        context: ToolContext(workingDirectory: work))
        #expect(output.hasPrefix("2 de 3 itens na Lixeira"))
        #expect(output.contains("a.txt → ") && output.contains(trash.lastPathComponent))
        #expect(output.contains("missing.txt: não movido, não existe"))
        #expect(!FileManager.default.fileExists(atPath: work.appending(path: "a.txt").path))
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "b.txt").path))
    }

    @Test func trashFailsWhenNothingMoved() async throws {
        let (trash, trasher) = try fakeTrash()
        defer { try? FileManager.default.removeItem(at: trash) }
        let tool = TrashTool(trasher: trasher)
        let none = await message { try await tool.run(.object(["paths": .array([.string("/nao/existe/9271")])]), context: context) }
        #expect(none.contains("Nada foi movido"))
        let empty = await message { try await tool.run(.object(["paths": .array([])]), context: context) }
        #expect(empty.contains("paths"))
        let single = try await { () async throws -> String in
            let file = FileManager.default.temporaryDirectory.appending(path: "orb-single-\(UUID().uuidString).txt")
            try "x".write(to: file, atomically: true, encoding: .utf8)
            return try await tool.run(.object(["paths": .string(file.path)]), context: context)
        }()
        #expect(single.hasPrefix("1 de 1 item"))
    }

    @Test func trashRefusesHomeAndSystemFolders() async {
        let home = URL(fileURLWithPath: "/Users/ana")
        #expect(TrashGuard.refusal(for: home, home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/System/Library/x"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/Documents"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/Documents/"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/Documents/old.txt"), home: home) == nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/Projetos"), home: home) == nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Applications/Foo.app"), home: home) == nil)
        // The default macOS volume ignores case, so other spellings are the same folders.
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/documents"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/DESKTOP"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/users/ana"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/system/library"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/tmp"), home: home) != nil)
        #expect(TrashGuard.refusal(for: URL(fileURLWithPath: "/Users/ana/documents/old.txt"), home: home) == nil)

        // Even if the trasher would accept it, the tool never gets that far.
        let tool = TrashTool(trasher: { _ in Issue.record("must not be called"); return nil })
        let text = await message { try await tool.run(.object(["paths": .array([.string("~"), .string("/")])]), context: context) }
        #expect(text.contains("é a pasta pessoal"))
        #expect(text.contains("é uma pasta do sistema"))
    }

    // MARK: Screenshot

    @Test func picksTheFrontWindowOfAnotherApp() {
        let windows = [
            WindowCandidate(id: 1, pid: 100, layer: 25, width: 1440, height: 24, alpha: 1),
            WindowCandidate(id: 2, pid: 999, layer: 0, width: 900, height: 700, alpha: 1),
            WindowCandidate(id: 3, pid: 200, layer: 0, width: 30, height: 30, alpha: 1),
            WindowCandidate(id: 4, pid: 200, layer: 0, width: 800, height: 600, alpha: 0),
            WindowCandidate(id: 5, pid: 300, layer: 0, width: 1000, height: 800, alpha: 1),
            WindowCandidate(id: 6, pid: 200, layer: 0, width: 800, height: 600, alpha: 1),
        ]
        #expect(WindowCandidate.front(in: windows, onlyPID: nil, excludingPID: 999)?.id == 5)
        #expect(WindowCandidate.front(in: windows, onlyPID: 200, excludingPID: 999)?.id == 6)
        #expect(WindowCandidate.front(in: windows, onlyPID: 777, excludingPID: 999) == nil)
        #expect(WindowCandidate.front(in: [], onlyPID: nil, excludingPID: 1) == nil)
    }

    @Test func parsesTheSystemWindowList() {
        let info: [[String: Any]] = [
            ["kCGWindowNumber": 7, "kCGWindowOwnerPID": 55, "kCGWindowLayer": 0, "kCGWindowAlpha": 1.0,
             "kCGWindowBounds": ["Width": 640.0, "Height": 480.0, "X": 0, "Y": 0]],
            ["kCGWindowOwnerPID": 56],
        ]
        #expect(WindowCandidate.parse(info) == [WindowCandidate(id: 7, pid: 55, layer: 0, width: 640, height: 480, alpha: 1)])
    }

    private func image(width: Int = 64, height: Int = 64, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test func detectsBlankCaptures() throws {
        let black = try image { $0.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        #expect(ScreenshotImage.isBlank(black))
        let content = try image {
            $0.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            $0.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1)); $0.fill(CGRect(x: 8, y: 8, width: 40, height: 30))
        }
        #expect(!ScreenshotImage.isBlank(content))
    }

    @Test func screenshotFailureBlamesThePermissionOnlyWhenItIsMissing() {
        let granted = ScreenshotImage.failureAdvice(captureOutput: "invalid display", hasPermission: true)
        #expect(!granted.contains("Gravação de Tela"))
        #expect(granted.contains("invalid display"))
    }

    @Test func screenshotFailureAdvisesTheScreenRecordingSetting() {
        let advice = ScreenshotImage.failureAdvice(captureOutput: "could not create image from display")
        #expect(advice.contains("Gravação de Tela"))
        #expect(advice.contains("Privacidade e Segurança"))
        #expect(advice.contains("could not create image"))
        #expect(ScreenshotImage.blankAdvice.contains("Gravação de Tela"))
    }

    @Test func readsImageSizeAndOrdersRecognizedLines() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orb-size-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let picture = try image(width: 120, height: 80) { $0.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 60, height: 80)) }
        let data = try #require(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
        try data.write(to: file)
        let size = try #require(ScreenshotImage.pixelSize(of: file))
        #expect(size.width == 120 && size.height == 80)
        #expect(!ScreenshotImage.isBlank(at: file))

        let ordered = TextRecognizer.lines(from: [
            (text: "baixo", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)),
            (text: "direita", box: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.05)),
            (text: "esquerda", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05)),
        ])
        #expect(ordered == "esquerda\ndireita\nbaixo")
    }

    @Test func recognizesRenderedText() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orb-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = NSSize(width: 600, height: 160)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 160, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Relatorio Orb" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)

        let text = try TextRecognizer.recognize(imageAt: file)
        #expect(text.localizedCaseInsensitiveContains("Orb"))
    }

    // MARK: Browser tab

    @Test func browsersAreFoundByNameAliasOrBundleId() {
        #expect(DesktopBrowser("Safari") == .safari)
        #expect(DesktopBrowser("chrome") == .chrome)
        #expect(DesktopBrowser("Google Chrome") == .chrome)
        #expect(DesktopBrowser("company.thebrowser.Browser") == .arc)
        #expect(DesktopBrowser("EDGE") == .edge)
        #expect(DesktopBrowser("Brave Browser") == .brave)
        #expect(DesktopBrowser("brave") == .brave)
        #expect(DesktopBrowser("Firefox") == nil)
        #expect(DesktopBrowser.allCases.count == 5)
    }

    @Test func browserScriptsUseTheRightVocabularyForEachFamily() {
        let safari = DesktopBrowser.safari
        #expect(safari.tabScript.contains("tell application id \"com.apple.Safari\""))
        #expect(safari.tabScript.contains("current tab of front window"))
        #expect(safari.textScript(limit: 500).contains("do JavaScript"))
        #expect(safari.textScript(limit: 500).contains("slice(0, 500)"))
        for chromium in [DesktopBrowser.chrome, .arc, .edge, .brave] {
            #expect(chromium.tabScript.contains("active tab of front window"))
            #expect(chromium.tabScript.contains("title of theTab"))
            #expect(chromium.textScript(limit: 10).contains("execute active tab of front window javascript"))
            #expect(chromium.javaScriptSetting.contains("Ver"))
        }
        #expect(safari.javaScriptSetting.contains("Desenvolver"))
    }

    @Test func parsesTabOutput() {
        let sep = BrowserTabParser.separator
        #expect(BrowserTabParser.parse("https://a.com/x\(sep)Página A")?.url == "https://a.com/x")
        #expect(BrowserTabParser.parse("https://a.com/x\(sep)Página A")?.title == "Página A")
        let blank = BrowserTabParser.parse("missing value\(sep)")
        #expect(blank?.url == "" && blank?.title == "")
        #expect(BrowserTabParser.parse("https://a.com\(sep)com\(sep)separador")?.title == "com\(sep)separador")
        #expect(BrowserTabParser.parse("") == nil, "no window")
    }

    @Test func recognizesBrowsersBlockingJavaScript() {
        #expect(BrowserTabParser.isJavaScriptBlocked("Executing JavaScript through AppleScript is turned off. To turn it on, choose View > Developer > Allow JavaScript from Apple Events."))
        #expect(BrowserTabParser.isJavaScriptBlocked("O Safari encontrou um erro: Você deve ativar a opção JavaScript de Eventos da Apple. (-1728)"))
        #expect(!BrowserTabParser.isJavaScriptBlocked("execution error: Can’t get window 1. (-1728)"))
    }

    @Test func browserToolRejectsUnknownBrowsersWithoutTouchingAnyApp() async {
        let text = await message { try await run(BrowserTabTool(), ["browser": .string("Netscape")]) }
        #expect(text.contains("Netscape"))
        #expect(text.contains("Safari"))
    }

    // MARK: Permission wiring

    private struct OneCallLLM: LLMClient {
        let call: ToolCallRequest
        func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
            let answered = messages.contains { $0.role == .tool }
            return AsyncThrowingStream { continuation in
                continuation.yield(answered ? .text("fim") : .toolCalls([call]))
                continuation.finish()
            }
        }
        func models() async throws -> [String] { ["fake"] }
    }

    /// Runs one tool call through the real engine, denying any approval; returns whether the user was asked.
    private func asksUser(mode: PermissionMode, tool: some AgentTool, arguments: String) async -> Bool {
        let engine = AgentEngine()
        let bot = Bot(name: "Teste", role: "", orb: OrbConfig(), permissionMode: mode)
        let request = TurnRequest(bot: bot, model: "fake", system: "sys", history: [], prompt: "oi",
                                  client: OneCallLLM(call: ToolCallRequest(id: "c1", name: tool.spec.name, arguments: arguments)),
                                  tools: [tool], context: context)
        var asked = false
        for await event in engine.run(request) {
            if case .approval(let approval) = event {
                asked = true
                await engine.gate.resolve(approvalID: approval.id, decision: .deny)
            }
        }
        return asked
    }

    @Test func forcedQuitStillAsksInAutomaticMode() async {
        let force = #"{"app":"Aplicativo Que Nao Existe 9271","force":true}"#
        let normal = #"{"app":"Aplicativo Que Nao Existe 9271"}"#
        #expect(await asksUser(mode: .auto, tool: AppQuitTool(), arguments: force))
        #expect(!(await asksUser(mode: .auto, tool: AppQuitTool(), arguments: normal)))
        #expect(await asksUser(mode: .ask, tool: AppQuitTool(), arguments: normal))
        #expect(!(await asksUser(mode: .bypass, tool: AppQuitTool(), arguments: force)))
    }
}
