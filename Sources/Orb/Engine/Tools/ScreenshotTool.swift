import AppKit
import ImageIO
import os
import Vision

struct ScreenshotTool: AgentTool {
    let spec = ToolSpec(
        name: "screenshot",
        description: """
        Capture a display or one window (JPEG; also when covered or on another Space). Returns its path, size and \
        px/pt, and for a window numbered marks over what can be clicked with a legend such as [12] w1.3.2 button \
        “Salvar” (ui_act takes "#12" or x,y in the picture's pixels), plus the text on it (OCR) when the \
        Accessibility tree names few elements. `app`/`window` pick the window like ui_read; max_side 640-1568. Needs \
        Screen Recording; marks need Accessibility.
        """,
        parameters: .schema([
            "target": .object(["type": .string("string"),
                               "enum": .array(["display", "window"].map(JSONValue.string)),
                               "description": .string("Default display; window when app or window is given.")]),
            "display": .property("integer", "Display number (1 = main, default)."),
            "app": .property("string", "With window: app name or bundle identifier (default: the front window of another app)."),
            "window": .property("string", "Number (1 = frontmost) or part of the title."),
            "marks": .property("boolean", "Number the clickable elements (default true)."),
            "max_side": .property("integer", "Longest side in pixels (default 1280)."),
            "ocr": .object(["type": .string("string"), "enum": .array(["auto", "on", "off"].map(JSONValue.string))]),
        ]))

    let system: any AccessibilitySystem
    let store: UISnapshotStore
    let screenAccess: ScreenCaptureAccess
    /// Where pictures are saved.
    let folder: URL
    /// The app with the front-most ordinary window that is not one of the given processes' (the Orb's own).
    let frontWindowPID: @Sendable (_ excluding: Set<Int32>) -> Int32?
    let ownPID: Int32
    /// The app's Accessibility calls (its window, the marks) go through its session like ui_read's: one at a time per app,
    /// with a deadline, and failing at once while a call to a hung app has not come back.
    let sessions: AXSessions

    init(system: any AccessibilitySystem = LiveAccessibilitySystem(), store: UISnapshotStore = .shared,
         screenAccess: ScreenCaptureAccess = .live,
         folder: URL = FileManager.default.temporaryDirectory.appending(path: "OrbScreenshots"),
         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         frontWindowPID: @escaping @Sendable (_ excluding: Set<Int32>) -> Int32? = ScreenshotTool.liveFrontWindowPID,
         sessions: AXSessions = .shared) {
        self.system = system
        self.store = store
        self.sessions = sessions
        self.screenAccess = screenAccess
        self.folder = folder
        self.ownPID = ownPID
        self.frontWindowPID = frontWindowPID
    }

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        Self.wantsWindow(arguments)
            ? ("Capturando a janela", [arguments.nonEmptyString("app"), Self.windowSelector(arguments)].compactMap { $0 }.joined(separator: " · "))
            : ("Capturando a tela", "")
    }

    /// Text found on a capture the model also gets to see, which says most of it already: just enough for exact
    /// strings (error codes, file names). Without the picture the text is all there is, so it gets more room.
    static let ocrLimitWithPicture = 1_500
    static let ocrLimitTextOnly = 8_000

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await capture(arguments, context: context).report(ocrLimit: Self.ocrLimitTextOnly)
    }

    /// The report as `run` gives it, plus the picture (shrunk) when the model can look at it. A picture that
    /// cannot be prepared or saved leaves the text-only result.
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let captured = try await capture(arguments, context: context)
        guard let file = captured.file, context.acceptsImages, let store = context.imageStore, let botID = context.botID else {
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitTextOnly))
        }
        // A capture of a large display can pass the size limit meant for attachments; it is shrunk all the same.
        do {
            let image = try await store.attach(fileAt: file, botID: botID, enforcingLimit: false)
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitWithPicture), images: [image])
        } catch {
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitTextOnly)
                + "\nNão consegui anexar a imagem para você ver (\(error.localizedDescription)); só o texto acima foi enviado.")
        }
    }

    /// What a capture found: the text before the OCR (path, size, warnings), the marks' legend, the OCR itself, and the file.
    struct Capture {
        var header: String
        var ocr: String
        /// The picture; nil when only the legend could be made (no Screen Recording).
        var file: URL?
        var legend = ""
        /// The OCR was not asked for, or `auto` found the Accessibility tree enough: nothing to say about it.
        var ocrSkipped = false
        /// The OCR was asked for and failed or ran out of time: "no text" would be a false statement about the picture.
        var ocrFailed = false

        func report(ocrLimit: Int) -> String {
            var text = header
            if !legend.isEmpty { text += "\n" + legend }
            if ocrSkipped { return text }
            if ocr.isEmpty {
                return text + (ocrFailed ? "\nNão consegui ler o texto da imagem (a leitura falhou ou demorou demais); isso não quer dizer que não haja texto nela."
                                         : "\nNão achei texto legível na imagem.")
            }
            return text + "\nTexto na imagem (OCR):\n" + ocr.truncated(to: ocrLimit)
        }
    }

    // MARK: Arguments

    static func windowSelector(_ arguments: JSONValue) -> String? {
        arguments["window"]?.int.map(String.init) ?? arguments.nonEmptyString("window")
    }

    /// A window is wanted when asked for, or when an app or window is named without saying display.
    static func wantsWindow(_ arguments: JSONValue) -> Bool {
        switch arguments["target"]?.string {
        case "window": true
        case "display": false
        default: arguments.nonEmptyString("app") != nil || windowSelector(arguments) != nil
        }
    }

    private func capture(_ arguments: JSONValue, context: ToolContext) async throws -> Capture {
        let ocrMode = arguments["ocr"]?.string
        if Self.wantsWindow(arguments) { return try await captureWindow(arguments, context: context, ocrMode: ocrMode) }
        return try await captureDisplay(arguments, ocrMode: ocrMode)
    }

    // MARK: A display

    private func captureDisplay(_ arguments: JSONValue, ocrMode: String?) async throws -> Capture {
        var captureArguments = ["-x", "-t", "png"]
        let display = arguments.integer("display", default: 1, in: 1...16)
        let displayCount = await MainActor.run { max(NSScreen.screens.count, 1) }
        guard display <= displayCount else {
            throw ToolError("Este Mac tem \(displayCount) \(displayCount == 1 ? "tela" : "telas"); a tela \(display) não existe.")
        }
        if display > 1 { captureArguments += ["-D", String(display)] }

        let hadAccess = screenAccess.isGranted()
        if !hadAccess { screenAccess.request() }
        let file = try Self.newFile(in: folder, extension: "png")
        let result = try await ProcessRunner.run("/usr/sbin/screencapture", captureArguments + [file.path], timeout: .seconds(20))
        guard !result.timedOut else { throw ToolError("A captura demorou demais e foi interrompida.") }
        guard result.status == 0, let size = ScreenshotImage.pixelSize(of: file), size.width > 0 else {
            throw ToolError(ScreenshotImage.failureAdvice(captureOutput: result.output, hasPermission: hadAccess))
        }
        if ScreenshotImage.isBlank(at: file) {
            throw ToolError(ScreenshotImage.blankAdvice)
        }

        let wantsText = OCRPolicy.shouldRun(mode: ocrMode, labeledElements: nil)
        var text = ""
        var ocrFailed = false
        if wantsText {
            do {
                text = try await withDeadline(Self.ocrDeadline, "a leitura do texto da imagem") {
                    try await TextRecognizer.recognizeWithTables(imageAt: file)
                }
            } catch { ocrFailed = true }
        }
        var report = "Captura salva em \(file.path) (\(size.width)×\(size.height) px)."
        if !hadAccess {
            report += "\nWarning: Orb does not have Screen Recording yet, so the capture may show only the wallpaper, without "
                + "windows. " + ScreenshotImage.permissionAdvice
        }
        return Capture(header: report, ocr: text, file: file, ocrSkipped: !wantsText, ocrFailed: ocrFailed)
    }

    // MARK: A window

    /// The window as Accessibility sees it.
    private struct AXWindowInfo: Sendable {
        var element: any AccessibilityElement
        /// From 0.
        var index: Int
        var title: String
        var frame: CGRect?
        var minimized: Bool
        var role: String
        /// Its `CGWindowID`, when Accessibility tells it.
        var windowID: UInt32?
    }

    /// The app's windows as Accessibility lists them (at most `maxAXWindows`), and which of them was asked for (or is focused).
    private struct AXWindowList: Sendable {
        var all: [AXWindowInfo]
        var chosen: Int
    }

    static let maxAXWindows = 24

    private func resolveApp(_ query: String?) async throws -> AccessibilityApp {
        let apps = await system.runningApps(withFrontmost: false)
        let found: RunningAppInfo?
        if let query {
            switch RunningAppMatcher.match(query, in: apps) {
            case .none: throw ToolError("Não há nenhum app aberto chamado \"\(query)\". Use apps_list para ver os nomes.")
            case .ambiguous(let candidates):
                throw ToolError("\"\(query)\" combina com vários apps (\(Set(candidates.map(\.name)).sorted().joined(separator: ", "))); diga o nome exato.")
            case .found(let matches): found = matches[0]
            }
        } else {
            // Not the Orb's own windows (nor those of another instance of the same app).
            var own: Set<Int32> = [ownPID]
            if let bundle = Bundle.main.bundleIdentifier { own.formUnion(apps.filter { $0.bundleID == bundle }.map(\.pid)) }
            guard let pid = frontWindowPID(own) else { throw ToolError("Não achei nenhuma janela visível de outro app.") }
            found = apps.first { $0.pid == pid }
        }
        guard let found else { throw ToolError("Não consegui identificar o app dono da janela.") }
        return AccessibilityApp(name: found.name, bundleID: found.bundleID, pid: found.pid,
                                launchDate: NSRunningApplication(processIdentifier: found.pid)?.launchDate)
    }

    private static func axWindows(root: any AccessibilityElement, selector: String?) throws -> AXWindowList? {
        let top = root.attributes(["AXWindows", "AXFocusedWindow"])
        guard let windows = top["AXWindows"]?.elements, !windows.isEmpty else { return nil }
        let chosen = try UIWindowChooser.choose(from: windows, selector: selector, focused: top["AXFocusedWindow"]?.element)
        let indices = [chosen] + windows.indices.filter { $0 != chosen }.prefix(maxAXWindows - 1)
        let all = indices.map { index in
            let window = windows[index]
            let attributes = window.attributes(["AXRole", "AXTitle", "AXPosition", "AXSize", "AXMinimized"])
            var frame: CGRect?
            if case .point(let origin)? = attributes["AXPosition"], case .size(let size)? = attributes["AXSize"] { frame = CGRect(origin: origin, size: size) }
            return AXWindowInfo(element: window, index: index, title: attributes["AXTitle"]?.string ?? "", frame: frame,
                                minimized: attributes["AXMinimized"]?.bool ?? false, role: attributes["AXRole"]?.string ?? "",
                                windowID: window.windowID)
        }
        return AXWindowList(all: all, chosen: chosen)
    }

    /// The window to photograph, and the Accessibility window that goes with it. The window read is the one asked for, else
    /// the focused one; when no window was named and that one has no picture (Finder's desktop is an "AXWindows" entry
    /// with no window behind it), the next Accessibility window that does is taken. A last resort, for the window read
    /// only, is the app's single plausible window.
    private static func pair(_ axList: AXWindowList?, selector: String?, among list: [CapturableWindow]) -> (ax: AXWindowInfo?, target: CapturableWindow?) {
        guard let axList, let chosen = axList.all.first else { return (nil, WindowMatcher.choose(from: list, selector: selector)) }
        func strict(_ info: AXWindowInfo) -> CapturableWindow? {
            guard let found = WindowMatcher.match(windowID: info.windowID, frame: info.frame, title: info.title, among: list) else { return nil }
            // The lone-window fallback is not a match.
            let byNumber = info.windowID == found.windowID
            let byFrame = info.frame.map { WindowMatcher.close($0, found.frame) } ?? false
            let byTitle = !info.title.isEmpty && UIText.fold(info.title) == UIText.fold(found.title)
            return byNumber || byFrame || byTitle ? found : nil
        }
        if chosen.minimized { return (chosen, nil) }
        if let found = strict(chosen) { return (chosen, found) }
        if selector == nil {
            for info in axList.all.dropFirst() where info.role == "AXWindow" && !info.minimized {
                if let found = strict(info) { return (info, found) }
            }
        }
        return (chosen, WindowMatcher.match(windowID: chosen.windowID, frame: chosen.frame, title: chosen.title, among: list))
    }

    private func captureWindow(_ arguments: JSONValue, context: ToolContext, ocrMode: String?) async throws -> Capture {
        let selector = Self.windowSelector(arguments)
        let maxSide = arguments.integer("max_side", default: 1280, in: 640...1568)
        let wantsMarks = arguments.flag("marks", default: true)
        let accessibilityGranted = system.isTrusted()
        let hasScreen = screenAccess.isGranted()
        if !hasScreen { screenAccess.request() }
        if !hasScreen, !accessibilityGranted { throw ToolError(MacPermissionProblem.screenRecording.modelMessage) }

        let app = try await resolveApp(arguments.nonEmptyString("app"))
        // The Orb's own window can be photographed, but its interface is not read (as ui_read refuses it).
        let isOrb = app.pid == ownPID || (Bundle.main.bundleIdentifier.map { app.bundleID == $0 } ?? false)
        if !hasScreen, isOrb { throw ToolError(MacPermissionProblem.screenRecording.modelMessage) }
        let trusted = accessibilityGranted && !isOrb
        var notes: [String] = []

        var axList: AXWindowList?
        if trusted {
            let system = system, appSessions = self.sessions
            let session = appSessions.session(for: app.pid)
            // A window that does not exist is the model's to fix (thrown); an app that does not answer only costs the marks.
            var lookup: Result<AXWindowList?, ToolError>?
            do {
                lookup = try await UIAccess.mapped(app) {
                    try await appSessions.run(app, within: appSessions.deadlines.action) { () -> Result<AXWindowList?, ToolError> in
                        let root = system.root(of: app)
                        // Asked once per app, as ui_read does (Electron and Chromium build their tree on demand).
                        if session.state.withLock({ $0.manualAccessibility == nil }) {
                            system.prepare(root)
                            let accepted = root.attribute("AXManualAccessibility")?.bool == true
                            session.state.withLock { $0.manualAccessibility = accepted }
                        }
                        do { return .success(try Self.axWindows(root: root, selector: selector)) } catch let error as ToolError {
                            return .failure(error)
                        } catch {
                            return .failure(ToolError(error.localizedDescription))
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notes.append("Sem marcas: " + Self.message(error))
            }
            if let lookup {
                axList = try lookup.get()
                if axList == nil { notes.append("Sem marcas: \(app.name) não expôs janelas pela Acessibilidade.") }
            }
        } else {
            notes.append(isOrb ? "Sem marcas: o Orb não lê a própria interface." : "Sem marcas: " + MacPermissionProblem.accessibility.modelMessage)
        }

        // The window to photograph. A listing that fails is a failed capture: the marks can still be given.
        var ax = axList?.all.first
        var target: CapturableWindow?
        var listingFailure: (any Error)?
        if hasScreen {
            var list: [CapturableWindow] = []
            do {
                list = try await system.capturer.windows(pid: app.pid)
                (ax, target) = Self.pair(axList, selector: selector, among: list)
                if target == nil, ax?.minimized != true {
                    // The listing may be from a moment before the window appeared (it is kept 1.5 s): once more, fresh.
                    list = try await system.capturer.refreshedWindows(pid: app.pid)
                    (ax, target) = Self.pair(axList, selector: selector, among: list)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                listingFailure = error
            }
            if listingFailure == nil {
                if ax?.minimized == true {
                    notes.append("A janela está minimizada: não há imagem dela (o macOS não captura janela minimizada).")
                    target = nil
                } else if target == nil {
                    let names = list.map { $0.title.isEmpty ? "(sem título)" : UIText.quoted(UIText.clean($0.title, limit: 40)) }
                    throw ToolError(list.isEmpty ? "\(app.name) não tem nenhuma janela que possa ser capturada."
                                    : "Não achei essa janela de \(app.name) entre as que dá para capturar: " + names.joined(separator: " · ") + ".")
                }
            }
        } else {
            notes.append("Sem imagem: " + MacPermissionProblem.screenRecording.modelMessage)
        }

        // Taking the picture and reading the marks overlap: both wait on other processes.
        let capturer = system.capturer
        let capturing = target
        async let pictured: Result<CGImage, any Error>? = {
            guard let capturing else { return nil }
            do { return .success(try await capturer.capture(capturing, maxSide: maxSide)) } catch { return .failure(error) }
        }()
        let axWindow = ax
        let sessions = sessions
        async let readMarks: Result<UIMarkReading, any Error>? = {
            guard wantsMarks, let axWindow, let frame = axWindow.frame else { return nil }
            let element = axWindow.element, prefix = "w\(axWindow.index + 1)"
            do {
                // The walk stops by itself a little before the deadline: a slow app gives fewer marks, not none.
                let limits = UIMarkCollector.Limits(seconds: max(0.1, UIReadTool.seconds(sessions.deadlines.read) - 0.5))
                return .success(try await sessions.run(app, within: sessions.deadlines.read) {
                    UIMarkCollector.collect(window: element, prefix: prefix, origin: frame.origin, size: frame.size, limits: limits)
                })
            } catch {
                return .failure(error)
            }
        }()
        let (pictureResult, marksResult) = await (pictured, readMarks)
        try Task.checkCancellation()
        var reading: UIMarkReading?
        switch marksResult {
        case .success(let read)?: reading = read
        case .failure(let error)?: notes.append("Sem marcas: " + Self.message(error))
        case nil: break
        }

        var image: CGImage?
        switch pictureResult ?? listingFailure.map({ .failure($0) }) {
        case .success(let taken)?:
            if ScreenshotImage.isBlank(taken) { throw ToolError(ScreenshotImage.blankAdvice) }
            image = taken
        case .failure(let error)?:
            if reading == nil { throw error }
            notes.append("Não consegui capturar a imagem: " + ((error as? ToolError)?.message ?? error.localizedDescription))
        case nil:
            break
        }
        if let failure = reading?.failure {
            notes.append(UIAccess.error(for: failure, app: app).message + " As marcas podem estar incompletas.")
        }

        // Marks, against the window's size on screen.
        let frame = target?.frame ?? ax?.frame
        let selected = reading.flatMap { reading in frame.map { UIMarkSelector.select(reading.candidates, windowSize: $0.size) } }
        let marks = selected?.marks ?? []

        // OCR on the raw picture (badges would be read as text), only when the tree says too little.
        let wantsText = image != nil && OCRPolicy.shouldRun(mode: ocrMode, labeledElements: trusted && ax != nil ? reading?.labeled : nil)
        var text = ""
        var ocrFailed = false
        if wantsText, let image {
            do {
                let found = try await Self.recognize(image)
                // Tables first: they are what the lines cannot show, and the limit on the OCR cuts from the end.
                text = (found.tables.map { $0 + "\nTexto corrido (com a posição):\n" } ?? "") + TextRecognizer.format(found.lines)
            } catch { ocrFailed = true }
        }

        // The picture the model gets: the marks on it, as a JPEG that fits.
        var geometry: ShotGeometry?
        var file: URL?
        var pixelSize = ""
        if let image, let target {
            let initial = ShotGeometry(imageWidth: image.width, imageHeight: image.height, windowFrame: target.frame, windowID: target.windowID)
            let encoded = try await runDetached { () -> JPEGPicture? in
                guard let drawn = UIOverlay.render(image, marks: marks, geometry: initial),
                      let result = ScreenshotJPEG.encode(fitting: drawn) else { return nil }
                return JPEGPicture(data: result.data, width: result.image.width, height: result.image.height)
            }
            guard let encoded else { throw ToolError("Não consegui preparar a imagem da janela.") }
            let saved = try Self.newFile(in: folder, extension: "jpg")
            try encoded.data.write(to: saved, options: .atomic)
            file = saved
            let final = ShotGeometry(imageWidth: encoded.width, imageHeight: encoded.height, windowFrame: target.frame, windowID: target.windowID)
            geometry = final
            pixelSize = "\(encoded.width)×\(encoded.height) px, \(Self.format(final.scale)) px/pt, \((encoded.data.count + 500) / 1000) KB"
        }

        // What ui_act will use: the marks and where the picture sits.
        if trusted, let ax, let reading, frame != nil {
            let remembered = ScreenshotReading(app: app, windowIndex: ax.index + 1, windowTitle: ax.title,
                                               candidates: Array(reading.candidates.prefix(400)), marks: marks, shot: geometry)
            store.save(UISnapshot.merging(remembered, into: store.snapshot(bot: context.botID, app: app)), bot: context.botID)
        }

        var header: String
        let windowName = ax.map { $0.title.isEmpty ? "janela \($0.index + 1)" : "janela \(UIText.quoted(UIText.clean($0.title, limit: 60)))" } ?? "janela"
        if let file {
            header = "Captura salva em \(file.path) (\(pixelSize)). \(windowName) de \(app.name)."
        } else {
            header = "Sem imagem. \(windowName) de \(app.name)."
        }
        if !notes.isEmpty { header += "\n" + notes.joined(separator: "\n") }
        var legend = ""
        if let selected, !marks.isEmpty {
            let use = geometry == nil ? "ui_act aceita \"#n\"" : "ui_act aceita \"#n\" ou x,y em pixels desta imagem"
            legend = "Marcas (\(use)):\n" + UIMarkLegend.text(for: marks, total: selected.total)
        } else if wantsMarks, reading != nil {
            legend = "Nenhum elemento clicável visível nesta janela."
        }
        return Capture(header: header, ocr: text, file: file, legend: legend, ocrSkipped: !wantsText, ocrFailed: ocrFailed)
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private struct JPEGPicture: Sendable {
        var data: Data
        var width: Int
        var height: Int
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.2f", number)
    }

    /// Vision for one picture at a time per process: it is heavy.
    private static let visionGate = AsyncGate(limit: 1)

    /// Vision that never answers lets go of the gate after `ocrDeadline` (the picture is still returned, without its text).
    private static func recognize(_ image: CGImage) async throws -> (lines: [OCRLine], tables: String?) {
        try await visionGate.run {
            try await withDeadline(ocrDeadline, "a leitura do texto da imagem") {
                let start = ContinuousClock.now
                let lines = try await runDetached { try TextRecognizer.recognize(image, fast: true) }
                let boxes = lines.map { line in
                    CGRect(x: line.box.minX / Double(image.width), y: line.box.minY / Double(image.height),
                           width: line.box.width / Double(image.width), height: line.box.height / Double(image.height))
                }
                let tables = try await TableRecognizer.tables(in: image, boxes: boxes,
                                                              budget: TableRecognizer.budget(deadline: ocrDeadline, since: start))
                return (lines, tables)
            }
        }
    }

    static let ocrDeadline: TimeInterval = 20

    /// The app with the front-most ordinary window that is not one of `excluding`, from the system's on-screen window list.
    static let liveFrontWindowPID: @Sendable (Set<Int32>) -> Int32? = { excluding in
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return WindowCandidate.front(in: WindowCandidate.parse(info), excludingPIDs: excluding)?.pid
    }

    /// When each folder was last cleared: listing a day of captures on every capture costs more than the capture's own
    /// bookkeeping, so it happens at most every `cleanupInterval`.
    private static let lastCleanup = OSAllocatedUnfairLock(initialState: [String: ContinuousClock.Instant]())
    static let cleanupInterval: Duration = .seconds(600)

    /// A fresh path in a temp folder, clearing captures older than a day (now and then) so they don't pile up.
    static func newFile(in folder: URL, extension ext: String, now: ContinuousClock.Instant = .now) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let due = lastCleanup.withLock { cleared in
            guard cleared[folder.path].map({ now - $0 >= cleanupInterval }) ?? true else { return false }
            cleared[folder.path] = now
            return true
        }
        if due {
            let cutoff = Date.now.addingTimeInterval(-86_400)
            let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in old where ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now) < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return folder.appending(path: "screenshot-\(UUID().uuidString.prefix(8)).\(ext)")
    }
}

/// A window from the system's on-screen list (ordered front to back).
struct WindowCandidate: Equatable, Sendable {
    var id: Int
    var pid: Int32
    var layer: Int
    var width: Double
    var height: Double
    var alpha: Double

    static func parse(_ info: [[String: Any]]) -> [WindowCandidate] {
        info.compactMap { entry in
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            return WindowCandidate(id: id, pid: pid,
                                   layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                   width: (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0,
                                   height: (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0,
                                   alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// The top-most normal window (layer 0, visible, not a sliver such as a toolbar strip), never of `excludingPIDs`.
    static func front(in windows: [WindowCandidate], excludingPIDs: Set<Int32>) -> WindowCandidate? {
        windows.first { window in
            window.layer == 0 && window.alpha > 0 && window.width >= 80 && window.height >= 60 && !excludingPIDs.contains(window.pid)
        }
    }
}

enum ScreenshotImage {
    /// What to tell the user when Screen Recording is the problem (the model-facing instruction, English).
    static let permissionAdvice = MacPermissionProblem.screenRecording.instruction

    /// Blames the permission when it is missing, or when a display capture fails with "could not create image" even
    /// though the check passed. A window capture trusts the check: the window may simply have closed since it was listed
    /// (screencapture prints the same words then), and the system's own message is the best clue.
    static func failureAdvice(captureOutput: String, hasPermission: Bool = false) -> String {
        let detail = captureOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "\n\nmacOS said: " + detail
        if hasPermission, MacPermissionProblem.detect(in: detail) != .screenRecording { return "Could not capture the screen." + suffix }
        return "Could not capture the screen. " + MacPermissionProblem.screenRecording.modelMessage + suffix
    }

    static let blankAdvice = "The capture came out blank (a single flat colour). That usually means Orb lacks the Screen Recording "
        + "permission. " + MacPermissionProblem.screenRecording.instruction
        + " (If the screen or window really is a single colour, it is not a permission problem.)"

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func isBlank(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return true }
        return isBlank(image)
    }

    /// True when the picture is a single flat colour (all black without the permission, or all one tint): shrinks it
    /// to 24×24 and checks that every pixel is about the same.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        for channel in 0..<3 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }
            if let low = values.min(), let high = values.max(), high - low > 6 { return false }
        }
        return true
    }
}

/// A line of text found on a picture. The box is in the picture's pixels, origin at the top left.
struct OCRLine: Sendable, Equatable {
    var text: String
    var box: CGRect

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// On-device text recognition (Vision) for screenshots.
enum TextRecognizer {
    static func recognize(imageAt url: URL) throws -> String { try read(imageAt: url).text }

    /// The text of a picture in reading order, and where each line sits (fractions of the picture).
    static func read(imageAt url: URL) throws -> (text: String, boxes: [CGRect]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["pt-BR", "en-US"]
        try VNImageRequestHandler(url: url).perform([request])
        let found = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
        }
        return (lines(from: found), found.map(\.box))
    }

    /// `recognize(imageAt:)`, with the tables on the picture (rows and columns, markdown) ahead of the plain text when it
    /// has any and the Mac can read them (`TableRecognizer`). `budget` is the OCR time allowed; the tables get what the text
    /// left, up to `tableSeconds`.
    static func recognizeWithTables(imageAt url: URL, budget: TimeInterval = ScreenshotTool.ocrDeadline,
                                    tableSeconds: TimeInterval = TableRecognizer.maxSeconds) async throws -> String {
        let start = ContinuousClock.now
        let ocr = try await runDetached { try Self.read(imageAt: url) }
        guard TableRecognizer.looksTabular(ocr.boxes), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let tables = try await TableRecognizer.tables(in: image, boxes: ocr.boxes,
                                                            budget: TableRecognizer.budget(deadline: budget, since: start, cap: tableSeconds)) else { return ocr.text }
        return tables + "\nTexto corrido:\n" + ocr.text
    }

    /// Reading order: top to bottom, then left to right (Vision's origin is the bottom left).
    static func lines(from found: [(text: String, box: CGRect)]) -> String {
        found.sorted { a, b in
            abs(a.box.maxY - b.box.maxY) > 0.01 ? a.box.maxY > b.box.maxY : a.box.minX < b.box.minX
        }.map(\.text).joined(separator: "\n")
    }

    /// Reads a picture. `fast` is Vision's quick level (what the window screenshot uses, on a picture already shrunk);
    /// the boxes come back in pixels of that picture.
    static func recognize(_ image: CGImage, fast: Bool = true) throws -> [OCRLine] {
        func perform(languages: [String]?) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !fast
            if let languages { request.recognitionLanguages = languages }
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }
        let observations: [VNRecognizedTextObservation]
        do { observations = try perform(languages: ["pt-BR", "en-US"]) } catch { observations = try perform(languages: nil) }
        let found = observations.compactMap { observation in
            observation.topCandidates(1).first.map {
                OCRLine(text: $0.string, box: pixelBox(fromNormalized: observation.boundingBox, width: image.width, height: image.height))
            }
        }
        return readingOrder(found)
    }

    /// Vision's box (fractions of the picture, origin at the bottom left) as pixels with the origin at the top left.
    static func pixelBox(fromNormalized box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: box.minX * Double(width), y: (1 - box.maxY) * Double(height),
               width: box.width * Double(width), height: box.height * Double(height))
    }

    /// Top to bottom, then left to right; lines whose tops are within half a line's height count as one row.
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted { a, b in
            let tolerance = min(a.box.height, b.box.height) / 2
            return abs(a.box.minY - b.box.minY) > tolerance ? a.box.minY < b.box.minY : a.box.minX < b.box.minX
        }
    }

    /// `(412,88) Relatório`: the centre of the line in the picture's pixels, which is what an x,y click takes.
    static func format(_ lines: [OCRLine]) -> String {
        lines.map { "(\(Int($0.center.x.rounded())),\(Int($0.center.y.rounded()))) \($0.text)" }.joined(separator: "\n")
    }
}
