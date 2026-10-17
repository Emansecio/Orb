import Foundation
import Testing
@testable import Orb

/// Stands in for the system's TCC calls: scripted answers, and a record of every question (and whether it could prompt).
final class StubMacPermissionSystem: MacPermissionSystem, @unchecked Sendable {
    struct Ask: Equatable { var bundleID: String; var prompts: Bool }

    private let lock = NSLock()
    private var automation: [String: OSStatus] = [:]
    private var afterPrompt: [String: OSStatus] = [:]
    private var running: [String: String] = [:]
    private var probes: [String: MacFileProbe] = [:]
    private var asked: [Ask] = []
    private var requests: [String] = []
    private var promptGate: DispatchSemaphore?
    var accessibility = false
    var screenRecording = false
    let homeDirectory = URL(filePath: "/Users/teste")

    /// What `AEDetermine…` answers without prompting, and what it answers after the user responds to the dialog.
    func setAutomation(_ bundleID: String, _ status: OSStatus, afterPrompt: OSStatus? = nil) {
        lock.withLock { automation[bundleID] = status; self.afterPrompt[bundleID] = afterPrompt }
    }
    /// Makes every prompting `AEDetermine…` wait until the test signals the semaphore, like a dialog nobody answers.
    func holdPrompts(until gate: DispatchSemaphore) { lock.withLock { promptGate = gate } }
    func setRunning(_ name: String, bundleID: String) { lock.withLock { running[name] = bundleID } }
    func setProbe(_ relativePath: String, _ probe: MacFileProbe) {
        lock.withLock { probes[homeDirectory.appending(path: relativePath).path] = probe }
    }
    var asks: [Ask] { lock.withLock { asked } }
    var promptCount: Int { lock.withLock { asked.filter(\.prompts).count } }
    var recordedRequests: [String] { lock.withLock { requests } }

    func automationStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        if askUserIfNeeded, let gate = lock.withLock({ promptGate }) { gate.wait() }
        return lock.withLock {
            asked.append(Ask(bundleID: bundleID, prompts: askUserIfNeeded))
            let current = automation[bundleID] ?? -600
            return askUserIfNeeded && current == -1744 ? (afterPrompt[bundleID] ?? -1743) : current
        }
    }
    func isAccessibilityTrusted() -> Bool { accessibility }
    func requestAccessibility() -> Bool { lock.withLock { requests.append("accessibility") }; return accessibility }
    func hasScreenRecording() -> Bool { screenRecording }
    func requestScreenRecording() -> Bool { lock.withLock { requests.append("screen") }; return screenRecording }
    func probe(_ url: URL) -> MacFileProbe { lock.withLock { probes[url.path] ?? .missing } }
    func runningBundleID(named name: String) -> String? { lock.withLock { running[name] } }
    /// Apps that start when asked: what `AEDetermine…` answers once they run (bundle id -> status).
    private var launchable: [String: OSStatus] = [:]
    private var launched: [String] = []
    func setLaunchable(_ bundleID: String, thenAutomation status: OSStatus) { lock.withLock { launchable[bundleID] = status } }
    var launches: [String] { lock.withLock { launched } }
    func launchHidden(bundleID: String) -> Bool {
        lock.withLock {
            guard let status = launchable[bundleID] else { return false }
            launched.append(bundleID)
            automation[bundleID] = status
            return true
        }
    }
}

/// Status mapping, failure detection, script app extraction and the AppleScript pre-flight. The real TCC calls are never
/// made here: they would prompt the person running the tests.
struct MacPermissionsTests {
    private func checker(_ stub: StubMacPermissionSystem) -> MacPermissionChecker { MacPermissionChecker(system: stub) }

    // MARK: Status mapping

    @Test func mapsEveryAutomationStatusCode() {
        #expect(MacPermissionStatus(automationStatus: 0) == .granted)
        #expect(MacPermissionStatus(automationStatus: -1743) == .denied)
        #expect(MacPermissionStatus(automationStatus: -1744) == .notDetermined)
        #expect(MacPermissionStatus(automationStatus: -600) == .appNotRunning)
        #expect(MacPermissionStatus(automationStatus: -50) == .unknown)
        #expect(MacPermissionStatus(automationStatus: 12345) == .unknown)
    }

    @Test func checkingNeverPrompts() {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744)
        stub.setAutomation("com.apple.finder", 0)
        let mail = AutomationTarget.known(named: "Mail")!
        let finder = AutomationTarget.known(named: "Finder")!
        let checker = checker(stub)
        #expect(checker.status(of: .automation(mail)) == .notDetermined)
        #expect(checker.status(of: .automation(finder)) == .granted)
        #expect(checker.status(of: .automation(AutomationTarget.known(named: "Notas")!)) == .appNotRunning)
        #expect(checker.status(of: .accessibility) == .notGranted)
        #expect(checker.status(of: .screenRecording) == .notGranted)
        #expect(stub.promptCount == 0)
        #expect(stub.recordedRequests.isEmpty)
    }

    @Test func accessibilityAndScreenRecordingFollowTheirBooleans() {
        let stub = StubMacPermissionSystem()
        stub.accessibility = true
        stub.screenRecording = true
        #expect(checker(stub).status(of: .accessibility) == .granted)
        #expect(checker(stub).status(of: .screenRecording) == .granted)
    }

    @Test func asksOnlyThroughRequest() {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: 0)
        let mail = AutomationTarget.known(named: "Mail")!
        #expect(checker(stub).request(.automation(mail)) == .granted)
        #expect(stub.asks == [.init(bundleID: "com.apple.mail", prompts: true)])
        #expect(checker(stub).request(.accessibility) == .notGranted)
        #expect(checker(stub).request(.screenRecording) == .notGranted)
        #expect(stub.recordedRequests == ["accessibility", "screen"])
        // Full Disk Access has no prompt: asking only re-reads it.
        #expect(checker(stub).request(.fullDiskAccess) == .unknown)
    }

    // MARK: Full Disk Access heuristic

    @Test func fullDiskAccessIsDeducedFromTheFirstProtectedItemThatExists() {
        let blocked = StubMacPermissionSystem()
        blocked.setProbe("Library/Mail", .blocked)
        blocked.setProbe("Library/Safari/Bookmarks.plist", .readable)
        #expect(checker(blocked).fullDiskAccessStatus() == .notGranted, "the first existing item decides")

        let readable = StubMacPermissionSystem()
        readable.setProbe("Library/Mail", .readable)
        #expect(checker(readable).fullDiskAccessStatus() == .granted)

        let safariOnly = StubMacPermissionSystem()
        safariOnly.setProbe("Library/Safari/Bookmarks.plist", .blocked)
        #expect(checker(safariOnly).fullDiskAccessStatus() == .notGranted)
        safariOnly.setProbe("Library/Safari/Bookmarks.plist", .readable)
        #expect(checker(safariOnly).fullDiskAccessStatus() == .granted)

        #expect(checker(StubMacPermissionSystem()).fullDiskAccessStatus() == .unknown, "nothing to try is not a guess")
    }

    @Test func theSettingsTabListsEveryPermissionInOrder() {
        let kinds = MacPermissionChecker.allKinds
        let titles = kinds.map(\.title)
        #expect(titles == ["Mail", "Calendário", "Notas", "Lembretes", "Finder", "System Events", "Mensagens", "Safari", "Música",
                           "Acessibilidade", "Gravação do Áudio do Sistema e da Tela", "Acesso Total ao Disco"])
        #expect(Set(kinds).count == kinds.count)
        #expect(MacPermissionKind.fullDiskAccess.canBeAskedNow == false)
        #expect(MacPermissionKind.accessibility.canBeAskedNow)
    }

    @Test func theAutomationLinesNameTheAppWithoutAnArticleThatDisagreesWithIt() {
        for target in AutomationTarget.known where !["com.apple.finder", "com.apple.systemevents"].contains(target.bundleID) {
            let detail = MacPermissionKind.automation(target).detail
            #expect(detail == "Controlar o app \(target.name) quando você pede", "\(detail)")
        }
        #expect(!MacPermissionKind.automation(AutomationTarget.known(named: "Notas")!).detail.contains("o Notas"))
    }

    @Test func statusesSayWhetherTheSystemPromptCanStillAppear() {
        #expect(MacPermissionStatus.notDetermined.canShowSystemPrompt)
        #expect(MacPermissionStatus.notGranted.canShowSystemPrompt)
        for status in [MacPermissionStatus.granted, .denied, .appNotRunning, .unknown] { #expect(!status.canShowSystemPrompt) }
        #expect(Set([MacPermissionStatus.granted, .denied, .notDetermined, .notGranted, .appNotRunning, .unknown].map(\.label)).count == 6)
    }

    @Test func statusesLoadOffTheMainActorWithoutPrompting() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", 0)
        let result = await checker(stub).statuses()
        #expect(result.count == MacPermissionChecker.allKinds.count)
        #expect(result[.automation(AutomationTarget.known(named: "Mail")!)] == .granted)
        #expect(stub.promptCount == 0)
    }

    // MARK: Deep links

    @Test func deepLinksPointAtTheRightPrivacyPanes() {
        let prefix = "x-apple.systempreferences:com.apple.preference.security?"
        #expect(MacPrivacyPane.automation.url.absoluteString == prefix + "Privacy_Automation")
        #expect(MacPrivacyPane.accessibility.url.absoluteString == prefix + "Privacy_Accessibility")
        #expect(MacPrivacyPane.screenRecording.url.absoluteString == prefix + "Privacy_ScreenCapture")
        #expect(MacPrivacyPane.fullDiskAccess.url.absoluteString == prefix + "Privacy_AllFiles")
        #expect(MacPermissionProblem.automation(app: "Mail").pane == .automation)
        #expect(MacPermissionProblem.screenRecording.pane.url == MacPermissionKind.screenRecording.pane.url)
        #expect(MacPermissionKind.fullDiskAccess.pane == .fullDiskAccess)
    }

    // MARK: Detecting problems

    @Test func recognizesAutomationRefusalsInAnyLanguage() {
        #expect(MacPermissionProblem.detect(in: "27:30: execution error: Not authorized to send Apple events to Mail. (-1743)")
                == .automation(app: "Mail"))
        #expect(MacPermissionProblem.detect(in: "execution error: Não é permitido enviar eventos da Apple para o Notas. (-1743)")
                == .automation(app: "Notas"))
        #expect(MacPermissionProblem.detect(in: "execution error: System Events got an error: Not authorized to send Apple events to System Events. (-1743)")
                == .automation(app: "System Events"))
        #expect(MacPermissionProblem.detect(in: "execution error: algo bloqueado (-1743)") == .automation(app: nil))
    }

    @Test func namesTheAppInTheRealPortugueseWordingOfTheSystem() {
        // The strings of AppleScript.component's Localizable.loctable: Brazilian ("eventos Apple para") and European Portuguese.
        for text in ["execution error: Não autorizado a enviar eventos Apple para Mail. (-1743)",
                     "execution error: Não autorizado a enviar eventos Apple ao Mail. (-1743)",
                     "execution error: Não tem autorização para enviar eventos Apple para o Mail. (-1743)",
                     "execution error: Não autorizado a enviar eventos da Apple para Mail. (-1743)"] {
            #expect(MacPermissionProblem.detect(in: text) == .automation(app: "Mail"), Comment(rawValue: text))
        }
        #expect(MacPermissionProblem.detect(in: "execution error: Não autorizado a enviar eventos Apple para Calendário. (-1743)")
                == .automation(app: "Calendário"))
    }

    @Test func aRefusalWithoutAnAppNameFallsBackToTheOnlyAppTheScriptAddresses() {
        let text = "execution error: algo bloqueado (-1743)"
        #expect(AppleScript.explain(text, scriptApps: ["Reminders"]).contains("Reminders"))
        // Two candidates: no guess.
        let two = AppleScript.explain(text, scriptApps: ["Reminders", "Notes"])
        #expect(!two.contains("Reminders") && two.contains("Automação"))
        #expect(AppleScript.explain(text).contains("Automação"))
    }

    @Test func theTranscriptOffersTheButtonForFailuresAndForOrbsOwnPermissionWarnings() {
        func call(_ kind: ToolCall.Kind, _ state: ToolCall.State, _ output: String?) -> ToolCall {
            ToolCall(kind: kind, title: "t", detail: "", state: state, output: output)
        }
        // A failure: anything the detector knows.
        #expect(call(.computer, .failed, "execution error: Not authorized to send Apple events to Mail. (-1743)").permissionProblemToShow
                == .automation(app: "Mail"))
        // A screenshot that went through with only the wallpaper, carrying Orb's own instruction: the button shows.
        let wallpaper = "Captura salva em /tmp/a.png (10×10 px).\nWarning: Orb does not have Screen Recording yet. " + ScreenshotImage.permissionAdvice
        #expect(call(.computer, .done, wallpaper).permissionProblemToShow == .screenRecording)
        // The browser tab tool embeds a refusal in an otherwise good result.
        let embedded = "Safari\nTítulo: x\n\nNão consegui ler o texto da página: " + MacPermissionProblem.automation(app: "Safari").modelMessage
        #expect(call(.browser, .done, embedded).permissionProblemToShow == .automation(app: "Safari"))
        // Successful output that merely mentions an error, a setting or a file path never shows it.
        #expect(call(.computer, .done, "erro (-1743) no log").permissionProblemToShow == nil)
        #expect(call(.file, .done, "veja Ajustes do Sistema → Privacidade e Segurança → Acessibilidade").permissionProblemToShow == nil)
        #expect(call(.computer, .running, wallpaper).permissionProblemToShow == nil)
        #expect(call(.computer, .done, nil).permissionProblemToShow == nil)
    }

    @Test func recognizesAccessibilityRefusalsButNotInvalidIndexes() {
        #expect(MacPermissionProblem.detect(in: "execution error: osascript is not allowed assistive access. (-25211)") == .accessibility)
        #expect(MacPermissionProblem.detect(in: "execution error: System Events got an error: osascript is not allowed assistive access. (-1719)") == .accessibility)
        #expect(MacPermissionProblem.detect(in: "execution error: O osascript não tem acesso assistiva. (-1719)") == .accessibility)
        #expect(MacPermissionProblem.detect(in: "execution error: System Events got an error: Can’t get window 1 of process \"Finder\". Invalid index. (-1719)") == nil)
        // A selector that merely mentions accessibility is the script's bug, not a missing permission.
        let selector = "execution error: System Events got an error: Can’t get button 1 of window 1 of process \"Safari\" whose accessibility description = \"Fechar\". Invalid index. (-1719)"
        #expect(MacPermissionProblem.detect(in: selector) == nil)
        #expect(MacPermissionProblem.detect(in: "erro: Can’t get button 1 whose acessibilidade = \"x\". (-1719)") == nil)
    }

    @Test func recognizesFullDiskAccessRefusalsOnlyForProtectedLibraryFolders() {
        #expect(MacPermissionProblem.detect(in: "ls: /Users/ana/Library/Mail: Operation not permitted") == .fullDiskAccess)
        #expect(MacPermissionProblem.detect(in: "cat: /Users/ana/Library/Safari/Bookmarks.plist: Operation not permitted") == .fullDiskAccess)
        #expect(MacPermissionProblem.detect(in: "sqlite3: unable to open /Users/ana/Library/Messages/chat.db (EPERM)") == .fullDiskAccess)
        #expect(MacPermissionProblem.detect(in: "ls: /Users/ana/Library/Messages: Operação não permitida") == .fullDiskAccess)
        #expect(MacPermissionProblem.detect(in: "rm: /usr/bin/true: Operation not permitted") == nil, "SIP, not something to grant")
        #expect(MacPermissionProblem.detect(in: "cat: /Users/ana/Library/Mail/x: No such file or directory") == nil)
    }

    @Test func recognizesScreenCaptureFailures() {
        #expect(MacPermissionProblem.detect(in: "could not create image from display 69733248") == .screenRecording)
        // The same words for a window that closed, so only the tool (which knows the permission) may blame the permission.
        #expect(MacPermissionProblem.detect(in: "screencapture: could not create image from window 1234") == nil)
        #expect(MacPermissionProblem.detect(in: "invalid display") == nil)
    }

    @Test func unrelatedFailuresAreNotPermissionProblems() {
        for text in ["", "27:30: execution error: A variável foo não está definida. (-2753)", "syntax error: Expected end of line. (-2741)",
                     "Application isn’t running. (-600)", "command not found: foo"] {
            #expect(MacPermissionProblem.detect(in: text) == nil, "\(text)")
        }
    }

    @Test func theMessageForTheModelNamesWhatIsMissingAndWhereToEnableIt() {
        let problems: [(MacPermissionProblem, pane: String)] = [
            (.automation(app: "Mail"), "Automação"), (.accessibility, "Acessibilidade"),
            (.screenRecording, "Gravação do Áudio do Sistema e da Tela"), (.fullDiskAccess, "Acesso Total ao Disco"),
        ]
        for (problem, pane) in problems {
            let message = problem.modelMessage
            #expect(message.contains("Ajustes do Sistema → Privacidade e Segurança → \(pane)"), "\(pane)")
            #expect(message.contains("Do not retry"))
            #expect(message.contains("Tell the user"))
            // The row in the transcript works from this very text.
            #expect(MacPermissionProblem.detect(in: message)?.pane == problem.pane)
        }
        #expect(MacPermissionProblem.automation(app: "Mail").modelMessage.contains("Mail"))
        #expect(MacPermissionProblem.screenRecording.modelMessage.contains("reopen Orb"))
        #expect(!MacPermissionProblem.accessibility.modelMessage.contains("reopen"))
    }

    @Test func theOldNameOfTheScreenRecordingPaneIsStillRecognized() {
        let former = "Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela"
        #expect(MacPermissionProblem.detect(in: former) == .screenRecording)
        #expect(!MacPermissionProblem.screenRecording.settingsPath.contains(former))
    }

    @Test func osascriptFailuresReachTheModelAsPermissionMessages() {
        let message = AppleScript.explain("27:30: execution error: Not authorized to send Apple events to Mail. (-1743)")
        #expect(message.hasPrefix("macOS blocked Orb from controlling Mail"))
        #expect(message.contains("Privacidade e Segurança → Automação"))
        #expect(message.contains("(-1743)"), "the system's own text stays as detail")
        #expect(MacPermissionProblem.detect(in: message) == .automation(app: "Mail"))
    }

    @Test func screenshotFailuresMapToScreenRecording() {
        for hasPermission in [true, false] {
            let advice = ScreenshotImage.failureAdvice(captureOutput: "could not create image from display", hasPermission: hasPermission)
            #expect(MacPermissionProblem.detect(in: advice) == .screenRecording)
        }
        let noPermission = ScreenshotImage.failureAdvice(captureOutput: "", hasPermission: false)
        #expect(MacPermissionProblem.detect(in: noPermission) == .screenRecording)
        let other = ScreenshotImage.failureAdvice(captureOutput: "invalid display", hasPermission: true)
        #expect(MacPermissionProblem.detect(in: other) == nil)
        // The permission is granted and the window closed after it was listed: not a permission problem, and no row button.
        let closed = ScreenshotImage.failureAdvice(captureOutput: "could not create image from window", hasPermission: true)
        #expect(MacPermissionProblem.detect(in: closed) == nil)
        #expect(!closed.contains("Do not retry"))
        #expect(closed.contains("could not create image from window"))
        // Without the permission a window capture is still blamed on it.
        let blocked = ScreenshotImage.failureAdvice(captureOutput: "could not create image from window", hasPermission: false)
        #expect(MacPermissionProblem.detect(in: blocked) == .screenRecording)
        #expect(MacPermissionProblem.detect(in: ScreenshotImage.blankAdvice) == .screenRecording)
    }

    // MARK: Apps named by a script

    @Test func findsAppsInAppleScript() {
        let script = """
        tell application "Mail"
            set n to count of messages of inbox
        end tell
        tell application "System Events" to keystroke "a"
        tell app "Finder" to get name of startup disk
        set v to window 1 of application "Safari"
        tell application "Mail" to activate
        """
        #expect(AutomationPreflight.appNames(in: script, language: .applescript) == ["Mail", "System Events", "Finder", "Safari"])
    }

    @Test func ignoresAppReferencesThatSendNoEvents() {
        let script = """
        if application "Spotify" is running then return "aberto"
        if application "Notes" is not running then return "fechado"
        set a to name of application "Safari"
        set b to id of application "Mail"
        set c to version of the application "Finder"
        """
        #expect(AutomationPreflight.appNames(in: script, language: .applescript).isEmpty)
        // The same app used for real later in the script still counts.
        let both = """
        if application "Mail" is running then
            tell application "Mail" to get name
        end if
        """
        #expect(AutomationPreflight.appNames(in: both, language: .applescript) == ["Mail"])
        #expect(AutomationPreflight.appNames(in: #"get name of application "Mail" & name of window 1 of application "Finder""#, language: .applescript) == ["Finder"])
    }

    @Test func appleScriptExtractionHandlesIdsCaseCommentsAndPlainScripts() {
        #expect(AutomationPreflight.appNames(in: #"tell application id "com.apple.mail" to activate"#, language: .applescript) == ["com.apple.mail"])
        #expect(AutomationPreflight.appNames(in: #"TELL APPLICATION "Notes" to get name"#, language: .applescript) == ["Notes"])
        let commented = """
        -- tell application "Mail" to quit
        # tell application "Notes" to quit
        tell application "Música" to playpause
        """
        #expect(AutomationPreflight.appNames(in: commented, language: .applescript) == ["Música"])
        for plain in ["return 1 + 1", #"display dialog "Choose an apple""#, #"set theApp to "x""#, ""] {
            #expect(AutomationPreflight.appNames(in: plain, language: .applescript).isEmpty, "\(plain)")
        }
    }

    @Test func findsAppsInJavaScriptForAutomation() {
        let script = """
        const mail = Application("Mail");
        const events = Application('System Events');
        const me = Application.currentApplication();
        // const x = Application("Notes");
        const again = Application( "Mail" );
        mail.inbox.messages.length
        """
        #expect(AutomationPreflight.appNames(in: script, language: .javascript) == ["Mail", "System Events"])
        #expect(AutomationPreflight.appNames(in: "[1, 2].map(n => n * 2)", language: .javascript).isEmpty)
        // An AppleScript phrase means nothing in JXA, and the other way round.
        #expect(AutomationPreflight.appNames(in: #"tell application "Mail" to activate"#, language: .javascript).isEmpty)
        #expect(AutomationPreflight.appNames(in: #"Application("Mail")"#, language: .applescript).isEmpty)
    }

    @Test func resolvesScriptNamesToBundleIdentifiers() {
        let stub = StubMacPermissionSystem()
        stub.setRunning("Preview", bundleID: "com.apple.Preview")
        let checker = checker(stub)
        #expect(checker.target(forScriptName: "Calendar")?.bundleID == "com.apple.iCal")
        #expect(checker.target(forScriptName: "calendário")?.bundleID == "com.apple.iCal")
        #expect(checker.target(forScriptName: "Messages")?.bundleID == "com.apple.MobileSMS")
        #expect(checker.target(forScriptName: "com.apple.Notes")?.bundleID == "com.apple.Notes")
        #expect(checker.target(forScriptName: "com.example.Thing")?.bundleID == "com.example.Thing")
        #expect(checker.target(forScriptName: "Preview")?.bundleID == "com.apple.Preview", "an app that is open, found by name")
        #expect(checker.target(forScriptName: "Not Open") == nil)
    }

    @Test func localizedNamesOfAppleAppsFindTheirOwnBundle() {
        #expect(AutomationTarget.known(named: "Atalhos")?.bundleID == "com.apple.shortcuts")
        #expect(AutomationTarget.known(named: "Shortcuts")?.bundleID == "com.apple.shortcuts")
        #expect(AutomationTarget.known(named: "Shortcuts Events")?.bundleID == "com.apple.shortcuts.events")
        #expect(AutomationTarget.known(named: "Música")?.bundleID == "com.apple.Music")
        #expect(AutomationTarget.known(named: "musica")?.bundleID == "com.apple.Music")
        #expect(AutomationTarget.known(named: "Music")?.bundleID == "com.apple.Music")
    }

    // MARK: Pre-flight decisions

    private func preflight(_ script: String, _ stub: StubMacPermissionSystem, language: AppleScript.Language = .applescript) async -> MacPermissionProblem? {
        await AutomationPreflight.blockingProblem(for: script, language: language, checker: checker(stub), patience: .seconds(5), settle: .milliseconds(1))
    }

    @Test func asksFirstWhenMacOSHasNeverBeenAsked() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: 0)
        let problem = await preflight(#"tell application "Mail" to get name"#, stub)
        #expect(problem == nil, "the user said yes: the script may run")
        #expect(stub.asks == [.init(bundleID: "com.apple.mail", prompts: false), .init(bundleID: "com.apple.mail", prompts: true)])
    }

    @Test func stopsWithATranslatedErrorWhenTheUserRefusesTheDialog() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: -1743)
        let problem = await preflight(#"tell application "Mail" to get name"#, stub)
        #expect(problem == .automation(app: "Mail"))
        #expect(stub.promptCount == 1)
    }

    @Test func doesNotRunOrAskWhenAlreadyDenied() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1743)
        stub.setAutomation("com.apple.finder", -1744, afterPrompt: 0)
        let problem = await preflight("""
        tell application "Mail" to get name
        tell application "Finder" to get name of startup disk
        """, stub)
        #expect(problem == .automation(app: "Mail"))
        #expect(stub.promptCount == 0, "a refusal never shows the dialog again, and the next app waits until this one is fixed")
        #expect(problem?.modelMessage.contains("Privacidade e Segurança → Automação") == true)
    }

    @Test func letsAGrantedAppRunWithoutAnyPrompt() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", 0)
        #expect(await preflight(#"tell application "Mail" to get name"#, stub) == nil)
        #expect(stub.promptCount == 0)
    }

    @Test func skipsClosedAndUnknownApps() async {
        let stub = StubMacPermissionSystem()   // Mail answers -600: not running
        #expect(await preflight(#"tell application "Mail" to launch"#, stub) == nil)
        #expect(await preflight(#"tell application "App Que Nao Existe" to launch"#, stub) == nil)
        #expect(stub.promptCount == 0)
    }

    @Test func opensAClosedKnownAppHiddenSoItsConsentComesBeforeTheScriptClock() async {
        let stub = StubMacPermissionSystem()   // System Events answers -600 until it runs
        stub.setLaunchable("com.apple.systemevents", thenAutomation: -1744)
        stub.setAutomation("com.apple.systemevents", -600, afterPrompt: 0)
        let script = #"tell application "System Events" to keystroke "a""#
        #expect(await preflight(script, stub) == nil)
        #expect(stub.launches == ["com.apple.systemevents"])
        #expect(stub.asks.filter(\.prompts).map(\.bundleID) == ["com.apple.systemevents"], "asked after it started, before the script")
    }

    @Test func aClosedAppThatWasRefusedEarlierFailsRightAfterTheHiddenLaunch() async {
        let stub = StubMacPermissionSystem()
        stub.setLaunchable("com.apple.iCal", thenAutomation: -1743)
        let problem = await preflight(#"tell application "Calendar" to get name of calendars"#, stub)
        #expect(problem == .automation(app: "Calendário"))
        #expect(stub.promptCount == 0, "a refusal never shows the dialog again")
    }

    @Test func anAppThatDoesNotStartOrIsNotWellKnownIsLeftToTheScript() async {
        let stub = StubMacPermissionSystem()
        #expect(await preflight(#"tell application "Notes" to get name"#, stub) == nil)   // cannot be launched
        #expect(await preflight(#"tell application "App Que Nao Existe" to launch"#, stub) == nil)
        #expect(stub.launches.isEmpty && stub.promptCount == 0)
    }

    @Test func anOpenAppIsNeverRelaunched() async {
        let stub = StubMacPermissionSystem()
        stub.setLaunchable("com.apple.mail", thenAutomation: 0)
        stub.setAutomation("com.apple.mail", 0)
        #expect(await preflight(#"tell application "Mail" to get name"#, stub) == nil)
        #expect(stub.launches.isEmpty)
    }

    @Test func asksForEachUndecidedAppBeforeTheScriptStarts() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: 0)
        stub.setAutomation("com.apple.systemevents", -1744, afterPrompt: 0)
        stub.setAutomation("com.apple.finder", 0)
        let script = """
        const mail = Application("Mail");
        const events = Application("System Events");
        const finder = Application("Finder");
        """
        #expect(await preflight(script, stub, language: .javascript) == nil)
        #expect(stub.asks.filter(\.prompts).map(\.bundleID) == ["com.apple.mail", "com.apple.systemevents"])
    }

    @Test func aDeniedAppThatIsOnlyAskedIfItIsRunningStillLetsTheScriptRun() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1743)
        let script = """
        if application "Mail" is running then return "aberto"
        return "fechado"
        """
        #expect(await preflight(script, stub) == nil)
        #expect(stub.asks.isEmpty)
    }

    @Test func aDialogNobodyAnswersDoesNotHoldTheScriptForever() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: -1743)
        let gate = DispatchSemaphore(value: 0)
        stub.holdPrompts(until: gate)
        let problem = await AutomationPreflight.blockingProblem(for: #"tell application "Mail" to get name"#, language: .applescript,
                                                                checker: checker(stub), patience: .milliseconds(50))
        gate.signal()
        #expect(problem == nil, "no answer in time is not a refusal: the script runs and its own error explains")
    }

    @Test func anUnverifiableStatusLetsTheScriptRun() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -50)
        #expect(await preflight(#"tell application "Mail" to get name"#, stub) == nil)
        #expect(stub.promptCount == 0)
    }

    @Test func aScriptWithoutAppsNeverTouchesTheSystem() async {
        let stub = StubMacPermissionSystem()
        #expect(await preflight("return 1 + 1", stub) == nil)
        #expect(stub.asks.isEmpty)
    }

    @Test func aDeniedAppFailsTheToolCallBeforeOsascriptRuns() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1743)
        do {
            _ = try await AppleScript.run(#"tell application "Mail" to get name"#, permissions: checker(stub))
            Issue.record("should have failed")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Mail") && message.contains("Do not retry") && message.contains("Privacidade e Segurança → Automação"))
            // osascript never ran: its own failure text would be appended as "macOS said: …".
            #expect(!message.contains("macOS said"))
        }
    }

    // MARK: Waiting for a blocking call

    // The blocked call waits on a semaphore the test releases afterwards, so the outcome never depends on timing.
    @Test func aBlockingCallThatTakesTooLongYieldsTheFallback() async {
        let release = DispatchSemaphore(value: 0)
        let value = await Blocking.run(fallback: "tempo", timeout: .milliseconds(50)) {
            release.wait()
            return "resposta"
        }
        release.signal()
        #expect(value == "tempo")
        #expect(await Blocking.run(fallback: "tempo", timeout: .seconds(30)) { "resposta" } == "resposta")
    }

    @Test func aTaskCancelledBeforeTheCallNeverStartsIt() async {
        let started = RaisedFlag()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await Blocking.run(fallback: "cancelado") { started.raise(); return "resposta" }
        }
        task.cancel()
        #expect(await task.value == "cancelado")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!started.isRaised, "no system dialog for a call nobody waits for")
    }

    @Test func cancellingTheTaskStopsWaitingForTheDialog() async {
        let release = DispatchSemaphore(value: 0)
        let task = Task { await Blocking.run(fallback: "cancelado") { release.wait(); return "resposta" } }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let value = await task.value
        release.signal()
        #expect(value == "cancelado")
    }
}

/// The settings tab's model, driven by the stub: no prompt ever reaches the system.
@MainActor
struct MacPermissionsModelTests {
    @Test func refreshReadsEveryRowAndOffersToAskOnlyWhereItCanHelp() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744)
        stub.setAutomation("com.apple.finder", 0)
        let model = MacPermissionsModel(checker: MacPermissionChecker(system: stub))
        await model.refresh()
        #expect(model.status(of: .accessibility) == .notGranted)
        #expect(model.canAsk(.automation(AutomationTarget.known[0])), "Mail was never asked")
        #expect(!model.canAsk(.automation(AutomationTarget.known[4])), "Finder is already granted")
        #expect(!model.canAsk(.fullDiskAccess), "Full Disk Access has no system prompt")
        #expect(stub.promptCount == 0)
    }

    @Test func askingKeepsTheAnswerAndMergesItWithTheOtherRows() async {
        let stub = StubMacPermissionSystem()
        stub.setAutomation("com.apple.mail", -1744, afterPrompt: 0)
        stub.setAutomation("com.apple.finder", 0)
        let model = MacPermissionsModel(checker: MacPermissionChecker(system: stub))
        await model.refresh()
        let mail = MacPermissionKind.automation(AutomationTarget.known[0])
        await model.ask(mail)
        #expect(stub.promptCount == 1)
        #expect(model.asking.isEmpty)
        #expect(model.status(of: .automation(AutomationTarget.known[4])) == .granted, "the other rows survive the merge")
        #expect(model.status(of: .accessibility) == .notGranted)
    }

    @Test func screenRecordingStopsOfferingTheButtonOnceMacOSHasNothingMoreToShow() async {
        let stub = StubMacPermissionSystem()
        let model = MacPermissionsModel(checker: MacPermissionChecker(system: stub))
        await model.refresh()
        #expect(model.canAsk(.screenRecording))
        await model.ask(.screenRecording)
        #expect(model.status(of: .screenRecording) == .notGranted)
        #expect(model.awaitsRelaunch.contains(.screenRecording))
        #expect(!model.canAsk(.screenRecording), "only Reabrir and Abrir Ajustes are left")
        #expect(model.canAsk(.accessibility))
        stub.screenRecording = true
        await model.refresh()
        #expect(model.status(of: .screenRecording) == .granted)
        #expect(model.awaitsRelaunch.isEmpty)
    }
}
