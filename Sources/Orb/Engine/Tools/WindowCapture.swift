import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

// Images of single windows (docs/USO-DO-COMPUTADOR.md, "Capturar janela"): ScreenCaptureKit one-shot capture, which works
// for a covered window and one on another Space, with `screencapture -o -l <id>` as the fallback. Never
// `CGWindowListCreateImage`. The live capturer is a thin shell over a `CaptureBackend`, so the policies around it (the
// 1.5 s window cache, at most two captures at once, when to fall back) are tested without the screen.

// MARK: - Limits shared by capture and OCR

/// Lets at most `limit` pieces of work run at once; the rest wait their turn. Used for captures (2 per process) and
/// text recognition (1).
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The most that ever ran together (for tests).
    private(set) var peak = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        peak = max(peak, running)
        defer { release() }
        return try await body()
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // The permit passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

/// Runs something the first time only. `CGRequestScreenCaptureAccess` shows the system dialog and must not be repeated on
/// every capture.
final class RequestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Calls `body` the first time; returns whether it did.
    @discardableResult
    func fire(_ body: () -> Void) -> Bool {
        let first = lock.withLock { () -> Bool in
            defer { fired = true }
            return !fired
        }
        if first { body() }
        return first
    }
}

/// Screen Recording permission: whether it is granted, and a request that is made at most once per process.
struct ScreenCaptureAccess: Sendable {
    var isGranted: @Sendable () -> Bool
    /// Asks macOS to show its dialog (it appears at most once per process).
    var request: @Sendable () -> Void

    private static let once = RequestOnce()

    static let live = ScreenCaptureAccess(
        isGranted: { CGPreflightScreenCaptureAccess() },
        request: { once.fire { _ = CGRequestScreenCaptureAccess() } })
}

// MARK: - Sizes

enum ImageScaling {
    /// `width`×`height` shrunk so the longer side is at most `maxSide`; never enlarged.
    static func targetSize(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxSide, maxSide > 0 else { return (max(width, 1), max(height, 1)) }
        let ratio = Double(maxSide) / Double(longest)
        return (max(1, Int((Double(width) * ratio).rounded())), max(1, Int((Double(height) * ratio).rounded())))
    }

    /// The image shrunk to `maxSide` on its longer side (the same image when it already fits).
    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let target = targetSize(width: image.width, height: image.height, maxSide: maxSide)
        guard target.width != image.width || target.height != image.height,
              let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage() ?? image
    }
}

// MARK: - Which window is which

/// Finds the capturable window that is a given window of the Accessibility tree: the two APIs share no identifier, so
/// they are matched by frame (within a couple of points) and title.
enum WindowMatcher {
    static let tolerance: CGFloat = 2

    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = tolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The window of `windows` (all of one app) that has this frame and title; nil when none can be told. Several windows
    /// on the same spot (tabbed windows) are told apart by title, then by being on screen. With no frame match, a title
    /// match of about the same size is used, and the only window of the app is taken as it is.
    static func match(frame: CGRect?, title: String, among windows: [CapturableWindow]) -> CapturableWindow? {
        guard !windows.isEmpty else { return nil }
        let wanted = UIText.fold(title)
        func titled(_ list: [CapturableWindow]) -> [CapturableWindow] {
            wanted.isEmpty ? [] : list.filter { UIText.fold($0.title) == wanted }
        }
        func best(_ list: [CapturableWindow]) -> CapturableWindow? {
            titled(list).first ?? list.first { $0.isOnScreen } ?? list.first
        }
        if let frame {
            let byFrame = windows.filter { close($0.frame, frame) }
            if let found = best(byFrame) { return found }
            let sameSize = titled(windows).filter { abs($0.frame.width - frame.width) <= tolerance && abs($0.frame.height - frame.height) <= tolerance }
            if let found = sameSize.first { return found }
        } else if let found = titled(windows).first {
            return found
        }
        return windows.count == 1 ? windows[0] : nil
    }

    /// A window picked without the Accessibility tree: `selector` is a position from 1 (front to back, as listed) or part
    /// of a title; without one, the first window on screen.
    static func choose(from windows: [CapturableWindow], selector: String?) -> CapturableWindow? {
        let wanted = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty { return windows.first { $0.isOnScreen } ?? windows.first }
        if let position = Int(wanted) { return windows.indices.contains(position - 1) ? windows[position - 1] : nil }
        let folded = UIText.fold(wanted)
        return windows.first { UIText.fold($0.title).contains(folded) }
    }
}

// MARK: - The live capturer

enum WindowCaptureError: Error, Equatable {
    /// The window closed between listing and capturing.
    case windowGone(UInt32)
    case failed(String)
}

/// What the capturer needs from macOS: the windows, the preferred capture and the fallback.
struct CaptureBackend: Sendable {
    var windows: @Sendable () async throws -> [CapturableWindow]
    var primary: @Sendable (CapturableWindow, Int) async throws -> CGImage
    var fallback: @Sendable (CapturableWindow, Int) async throws -> CGImage
}

enum CaptureFallbackPolicy {
    /// Whether `screencapture` should be tried after ScreenCaptureKit failed with `error`. A missing permission would fail
    /// the same way (and the person must hear about it), a cancelled task must stop, and a window that is gone cannot be
    /// captured by anyone.
    static func shouldFallBack(after error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return false }
        if let error = error as? WindowCaptureError, case .windowGone = error { return false }
        if isPermissionDenied(error) { return false }
        return true
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801
    }
}

final class LiveWindowCapturer: WindowCapturer, @unchecked Sendable {
    /// One per process: the window cache and the limit on captures at once are meant to be shared by every tool.
    static let shared = LiveWindowCapturer(backend: .screenCaptureKit)

    /// Windows are listed at most this often: listing is the slow part of a capture.
    static let cacheLifetime: Duration = .milliseconds(1_500)
    static let maxConcurrentCaptures = 2

    private let backend: CaptureBackend
    private let gate: AsyncGate
    private let lifetime: Duration
    private let lock = NSLock()
    private var cache: (windows: [CapturableWindow], at: ContinuousClock.Instant)?

    init(backend: CaptureBackend, lifetime: Duration = LiveWindowCapturer.cacheLifetime,
         maxConcurrent: Int = LiveWindowCapturer.maxConcurrentCaptures) {
        self.backend = backend
        self.lifetime = lifetime
        gate = AsyncGate(limit: maxConcurrent)
    }

    func windows(pid: Int32) async throws -> [CapturableWindow] {
        try await allWindows().filter { $0.pid == pid }
    }

    private func allWindows(refresh: Bool = false) async throws -> [CapturableWindow] {
        let now = ContinuousClock.now
        if !refresh, let hit = lock.withLock({ cache.flatMap { now - $0.at < lifetime ? $0.windows : nil } }) { return hit }
        do {
            let listed = try await backend.windows()
            lock.withLock { cache = (listed, ContinuousClock.now) }
            return listed
        } catch {
            throw Self.explain(error)
        }
    }

    func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage {
        let backend = backend
        return try await gate.run {
            do {
                return try await backend.primary(window, maxSide)
            } catch {
                guard CaptureFallbackPolicy.shouldFallBack(after: error) else { throw Self.explain(error) }
                do {
                    return try await backend.fallback(window, maxSide)
                } catch {
                    throw Self.explain(error)
                }
            }
        }
    }

    /// What the model is told: the permission when that is the problem, the window's end when it closed.
    private static func explain(_ error: any Error) -> any Error {
        if CaptureFallbackPolicy.isPermissionDenied(error) { return ToolError(MacPermissionProblem.screenRecording.modelMessage) }
        if let error = error as? WindowCaptureError {
            switch error {
            case .windowGone: return ToolError("A janela fechou antes de ser capturada. Leia a interface de novo (ui_read) e tente outra vez.")
            case .failed(let detail): return ToolError(ScreenshotImage.failureAdvice(captureOutput: detail, hasPermission: CGPreflightScreenCaptureAccess()))
            }
        }
        return error
    }
}

extension CaptureBackend {
    /// ScreenCaptureKit for listing and capturing, `screencapture -o -l` when that fails.
    static let screenCaptureKit = CaptureBackend(
        windows: { try await SCKSession.shared.windows() },
        primary: { window, maxSide in try await SCKSession.shared.capture(window, maxSide: maxSide) },
        fallback: { window, maxSide in try await ScreencaptureCommand.capture(window, maxSide: maxSide) })
}

// MARK: - ScreenCaptureKit

/// Holds the `SCWindow`s of the last listing (a capture needs the object, not just its number).
actor SCKSession {
    static let shared = SCKSession()

    private var objects: [UInt32: SCWindow] = [:]

    func windows() async throws -> [CapturableWindow] {
        // Every window, also those on other Spaces and minimized ones; the desktop's own are of no use.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        var listed: [CapturableWindow] = []
        var fresh: [UInt32: SCWindow] = [:]
        for window in content.windows {
            guard window.windowLayer == 0, let owner = window.owningApplication else { continue }
            fresh[window.windowID] = window
            listed.append(CapturableWindow(windowID: window.windowID, pid: owner.processID, frame: window.frame,
                                           title: window.title ?? "", isOnScreen: window.isOnScreen))
        }
        objects = fresh
        return listed
    }

    func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage {
        if objects[window.windowID] == nil { _ = try await windows() }
        guard let object = objects[window.windowID] else { throw WindowCaptureError.windowGone(window.windowID) }
        let filter = SCContentFilter(desktopIndependentWindow: object)
        let scale = max(1, CGFloat(SCShareableContent.info(for: filter).pointPixelScale))
        let size = ImageScaling.targetSize(width: Int((window.frame.width * scale).rounded()),
                                           height: Int((window.frame.height * scale).rounded()), maxSide: maxSide)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.captureResolution = .nominal
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

// MARK: - screencapture

enum ScreencaptureCommand {
    static func capture(_ window: CapturableWindow, maxSide: Int) async throws -> CGImage {
        let file = FileManager.default.temporaryDirectory.appending(path: "orb-window-\(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: file) }
        // -x: no sound, -o: no window shadow, -l: this window only (also when covered).
        let result = try await ProcessRunner.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.windowID), file.path], timeout: .seconds(20))
        guard !result.timedOut else { throw WindowCaptureError.failed("A captura demorou demais e foi interrompida.") }
        guard result.status == 0, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WindowCaptureError.failed(result.output)
        }
        return ImageScaling.scaled(image, maxSide: maxSide)
    }
}
