import AppKit
import WebKit

/// The one way a web page is made in the app. What runs in one was written by a model, or by a page a model read, so it gets no
/// memory, no network and no way out: a data store that dies with it, a rule list that refuses every request a page can make,
/// a Content Security Policy written before its own text, no navigation past the first load and no permission ever granted.
@MainActor
enum PageSandbox {
    /// Longest HTML a page may have. Past it the block stays code.
    nonisolated static let maxHTML = 512_000
    /// A page's width, and the height a drawing of it stops at.
    nonisolated static let width: CGFloat = 720
    nonisolated static let maxHeight: CGFloat = 2_000

    /// The policy of a page, scripts or not. `connect-src` and the rest fall to `default-src 'none'`: only what is written
    /// in the page itself loads.
    nonisolated static func policy(scripts: Bool) -> String {
        ["default-src 'none'", scripts ? "script-src 'unsafe-inline'" : nil, "style-src 'unsafe-inline'", "img-src data:", "font-src data:",
         "media-src data:", "form-action 'none'", "base-uri 'none'", "frame-src 'none'", "child-src 'none'", "worker-src 'none'"]
            .compactMap { $0 }.joined(separator: "; ")
    }

    /// `html` as a document that starts with the policy, so it covers all that was written: a second policy can only add limits.
    nonisolated static func document(_ html: String, scripts: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="\(policy(scripts: scripts))">\
        <style>html{color-scheme:dark}body{margin:0;padding:12px;background:#222222;color:#FCFCFC;font:14px -apple-system,sans-serif}</style>\
        </head><body>\(html)</body></html>
        """
    }

    /// Every address a page could reach, refused before it leaves: the rule list holds even where a policy has a gap.
    nonisolated static let blockedRequests = #"""
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
    """#

    /// Removed before the page's first line: a peer connection reaches the network without asking the policy.
    nonisolated static let closesLeaks = """
    for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "WebSocket", "EventSource", "Worker", \
    "SharedWorker", "fetch", "XMLHttpRequest"]) { try { Object.defineProperty(window, name, { value: undefined, writable: false, \
    configurable: false }); } catch {} }
    for (const name of ["sendBeacon", "clipboard"]) { try { Object.defineProperty(navigator, name, { value: undefined, writable: false, \
    configurable: false }); } catch {} }
    try { Object.defineProperty(Document.prototype, "execCommand", { value() { return false; }, writable: false, configurable: false }); } catch {}
    """

    /// All a page can say to the app: text for the person to see, who decides whether it goes to the composer.
    nonisolated static let proposes = """
    Object.defineProperty(window, "orb", { value: Object.freeze({ propose(text) { \
    window.webkit?.messageHandlers?.orb?.postMessage(String(text).slice(0, \(proposalLimit))); } }), writable: false, configurable: false });
    """
    nonisolated static let proposalLimit = 2_000
    /// Ajustes → Geral: replies can show interactive pages. Off, a ```page fence stays code.
    nonisolated static let settingKey = "interactivePages"

    private static var rules: WKContentRuleList?

    private static func ruleList() async -> WKContentRuleList? {
        if let rules { return rules }
        let list = try? await WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "orb-pagina", encodedContentRuleList: blockedRequests)
        rules = list
        return list
    }

    /// A web view with nothing of the app in it, or nil when the rules that keep it off the network could not be made: no
    /// page without them. `messages`: the one thing a live page may do (`orb.propose`).
    static func makeView(javaScript: Bool, frame: CGSize = CGSize(width: width, height: 400),
                         messages: WKScriptMessageHandler? = nil) async -> WKWebView? {
        guard let rules = await ruleList() else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(source: closesLeaks, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.addUserScript(WKUserScript(source: proposes, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let messages { configuration.userContentController.add(messages, name: "orb") }
        let view = WKWebView(frame: CGRect(origin: .zero, size: frame), configuration: configuration)
        view.navigationDelegate = Guard.shared
        view.uiDelegate = Guard.shared
        return view
    }

    /// Loads one document and waits for it. Whether it finished before `deadline`.
    static func load(_ view: WKWebView, deadline: Duration, start: () -> Void) async -> Bool {
        let result: Bool? = await withDeadline(deadline) { done in
            Guard.shared.expect(view) { done($0) }
            // The first load is the only one `Guard` lets through.
            start()
        }
        if result == nil { Guard.shared.forget(view) }
        return result ?? false
    }

    /// The picture of a page, as tall as it is, up to `maxHeight`. Never with scripts: nothing of a page runs until the person
    /// opens it.
    static func draw(html: String) async -> RichRenderer.Drawn {
        guard html.utf8.count <= maxHTML else { return .failed("Página longa demais") }
        guard let view = await makeView(javaScript: false) else { return .notNow("Não consegui isolar a página") }
        let loaded = await load(view, deadline: .seconds(10)) { view.loadHTMLString(document(html, scripts: false), baseURL: nil) }
        guard loaded else { return .timedOut }
        let measured: CGFloat? = await withDeadline(.seconds(3)) { done in
            // The body, not the document: a document is at least as tall as the view.
            view.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().bottom) + 12") { value, _ in
                done((value as? NSNumber).map { CGFloat($0.doubleValue) } ?? 240)
            }
        }
        guard let measured else { return .timedOut }
        let size = CGSize(width: width, height: max(min(measured, maxHeight), 40))
        return await picture(of: view, size: size, scale: 2, zooms: true) ?? .timedOut
    }

    /// `view` as a PNG of `size` points. The page draws itself `scale` times larger (`zooms` here, by `render.js` otherwise), so a
    /// picture is as sharp on a Mac as off a screen, where a web view draws at one pixel per point.
    static func picture(of view: WKWebView, size: CGSize, scale: CGFloat, zooms: Bool = false) async -> RichRenderer.Drawn? {
        let usable = min(scale, RichRenderer.maxPixels / max(size.width, size.height))
        if usable != scale, !zooms { _ = try? await view.evaluateJavaScript("document.getElementById('stage').style.zoom = \(usable)") }
        if zooms { view.pageZoom = usable }
        view.setFrameSize(CGSize(width: (size.width + 8) * usable, height: (size.height + 8) * usable))
        view.layoutSubtreeIfNeeded()
        // The new size reaches the page on its next frame.
        try? await Task.sleep(for: .milliseconds(60))
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(x: 0, y: 0, width: size.width * usable, height: size.height * usable)
        let png: Data?? = await withDeadline(.seconds(5)) { done in
            view.takeSnapshot(with: shot) { image, _ in
                done(image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
            }
        }
        return (png ?? nil).map { .image($0, size) }
    }

    /// Runs `start`, which ends by calling what it is given, and gives up on it after `deadline`.
    static func withDeadline<Value: Sendable>(_ deadline: Duration, start: (@escaping @MainActor (Value) -> Void) -> Void) async -> Value? {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: @MainActor (Value?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            start { finish($0) }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                finish(nil)
            }
        }
    }

    /// Lets a view's first document through and nothing after it: no link, no redirect, no window, no permission.
    final class Guard: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let shared = Guard()
        private var waiting: [ObjectIdentifier: (Bool) -> Void] = [:]
        /// Weak: a closed view's identifier can come back in a new one.
        private let opened = NSHashTable<WKWebView>.weakObjects()

        func expect(_ view: WKWebView, _ finished: @escaping (Bool) -> Void) {
            waiting[ObjectIdentifier(view)] = finished
            opened.remove(view)
        }

        func forget(_ view: WKWebView) { waiting[ObjectIdentifier(view)] = nil }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true, !opened.contains(webView) else { return .cancel }
            opened.add(webView)
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            waiting.removeValue(forKey: ObjectIdentifier(webView))?(true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            waiting.removeValue(forKey: ObjectIdentifier(webView))?(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            waiting.removeValue(forKey: ObjectIdentifier(webView))?(false)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }

    }
}
