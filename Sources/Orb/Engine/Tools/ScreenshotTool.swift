import AppKit
import ImageIO
import Vision

struct ScreenshotTool: AgentTool {
    let spec = ToolSpec(
        name: "screenshot",
        description: """
        Capture a display or the front window of another app (PNG); returns its path, size and the text on it \
        (OCR), plus the picture itself if your model sees images. target "window" skips the Orb's own window; \
        `app` picks that app's window. Needs Screen Recording.
        """,
        parameters: .schema([
            "target": .object(["type": .string("string"),
                               "enum": .array(["display", "window"].map(JSONValue.string)),
                               "description": .string("Default display.")]),
            "display": .property("integer", "Display number (1 = main, default)."),
            "app": .property("string", "With window: app name or bundle identifier."),
        ]))

    var kind: ToolCall.Kind { .computer }
    var capability: Capability? { .computerUse }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        arguments["target"]?.string == "window" ? ("Capturando a janela", arguments["app"]?.string ?? "")
            : ("Capturando a tela", "")
    }

    /// Text found on a capture the model also gets to see, which says most of it already: just enough for exact
    /// strings (error codes, file names). Without the picture the text is all there is, so it gets more room.
    static let ocrLimitWithPicture = 1_500
    static let ocrLimitTextOnly = 8_000

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await capture(arguments).report(ocrLimit: Self.ocrLimitTextOnly)
    }

    /// The report as `run` gives it, plus the picture (shrunk) when the model can look at it. A picture that
    /// cannot be prepared or saved leaves the text-only result.
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let captured = try await capture(arguments)
        guard context.acceptsImages, let store = context.imageStore, let botID = context.botID else {
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitTextOnly))
        }
        // A capture of a large display can pass the size limit meant for attachments; it is shrunk all the same.
        do {
            let image = try await store.attach(fileAt: captured.file, botID: botID, enforcingLimit: false)
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitWithPicture), images: [image])
        } catch {
            return ToolResult(text: captured.report(ocrLimit: Self.ocrLimitTextOnly)
                + "\nNão consegui anexar a imagem para você ver (\(error.localizedDescription)); só o texto acima foi enviado.")
        }
    }

    /// What a capture found: the text before the OCR (path, size, warnings), the OCR itself, and the file.
    struct Capture {
        var header: String
        var ocr: String
        var file: URL

        func report(ocrLimit: Int) -> String {
            header + (ocr.isEmpty ? "\nNão achei texto legível na imagem." : "\nTexto na imagem (OCR):\n" + ocr.truncated(to: ocrLimit))
        }
    }

    private func capture(_ arguments: JSONValue) async throws -> Capture {
        let wantsWindow = arguments["target"]?.string == "window"
        var captureArguments = ["-x", "-t", "png"]
        if wantsWindow {
            let window = try await Self.window(app: arguments.nonEmptyString("app"))
            captureArguments += ["-o", "-l", String(window.id)]
        } else {
            let display = arguments.integer("display", default: 1, in: 1...16)
            let displayCount = await MainActor.run { max(NSScreen.screens.count, 1) }
            guard display <= displayCount else {
                throw ToolError("Este Mac tem \(displayCount) \(displayCount == 1 ? "tela" : "telas"); a tela \(display) não existe.")
            }
            if display > 1 { captureArguments += ["-D", String(display)] }
        }

        let hadAccess = CGPreflightScreenCaptureAccess()
        if !hadAccess { CGRequestScreenCaptureAccess() }
        let file = try Self.newFile()
        let result = try await ProcessRunner.run("/usr/sbin/screencapture", captureArguments + [file.path], timeout: .seconds(20))
        guard !result.timedOut else { throw ToolError("A captura demorou demais e foi interrompida.") }
        guard result.status == 0, let size = ScreenshotImage.pixelSize(of: file), size.width > 0 else {
            throw ToolError(ScreenshotImage.failureAdvice(captureOutput: result.output, hasPermission: hadAccess))
        }
        if ScreenshotImage.isBlank(at: file) {
            throw ToolError(ScreenshotImage.blankAdvice)
        }

        let text = await Task.detached { (try? TextRecognizer.recognize(imageAt: file)) ?? "" }.value
        var report = "Captura salva em \(file.path) (\(size.width)×\(size.height) px)."
        if !hadAccess {
            report += "\nWarning: Orb does not have Screen Recording yet, so the capture may show only the wallpaper, without "
                + "windows. " + ScreenshotImage.permissionAdvice
        }
        return Capture(header: report, ocr: text, file: file)
    }

    /// The front window of `app`, or the front-most ordinary window that is not the Orb's.
    private static func window(app: String?) async throws -> WindowCandidate {
        var pid: Int32?
        if let app {
            let apps = await MainActor.run { RunningAppInfo.current(includeBackground: false) }
            switch RunningAppMatcher.match(app, in: apps) {
            case .none: throw ToolError("Não há nenhum app aberto chamado \"\(app)\". Use apps_list para ver os nomes.")
            case .ambiguous(let candidates):
                throw ToolError("\"\(app)\" combina com vários apps (\(Set(candidates.map(\.name)).sorted().joined(separator: ", "))); diga o nome exato.")
            case .found(let found): pid = found[0].pid
            }
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = WindowCandidate.front(in: WindowCandidate.parse(info), onlyPID: pid,
                                                 excludingPID: ProcessInfo.processInfo.processIdentifier) else {
            throw ToolError(app.map { "O app \($0) não tem nenhuma janela visível." } ?? "Não achei nenhuma janela visível de outro app.")
        }
        return window
    }

    /// A fresh path in a temp folder, clearing captures older than a day so they don't pile up.
    private static func newFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbScreenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date.now.addingTimeInterval(-86_400)
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in old where ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
        return folder.appending(path: "screenshot-\(UUID().uuidString.prefix(8)).png")
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

    /// The top-most normal window (layer 0, visible, not a sliver such as a toolbar strip), optionally of one app,
    /// never of `excludingPID`.
    static func front(in windows: [WindowCandidate], onlyPID: Int32?, excludingPID: Int32) -> WindowCandidate? {
        windows.first { window in
            window.layer == 0 && window.alpha > 0 && window.width >= 80 && window.height >= 60
                && window.pid != excludingPID && (onlyPID.map { $0 == window.pid } ?? true)
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

/// On-device text recognition (Vision) for screenshots.
enum TextRecognizer {
    static func recognize(imageAt url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["pt-BR", "en-US"]
        try VNImageRequestHandler(url: url).perform([request])
        return lines(from: (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
        })
    }

    /// Reading order: top to bottom, then left to right (Vision's origin is the bottom left).
    static func lines(from found: [(text: String, box: CGRect)]) -> String {
        found.sorted { a, b in
            abs(a.box.maxY - b.box.maxY) > 0.01 ? a.box.maxY > b.box.maxY : a.box.minX < b.box.minX
        }.map(\.text).joined(separator: "\n")
    }
}
