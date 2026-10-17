import Foundation
import os
@testable import Orb

/// A browser that answers from a script and writes down what it was asked, for the `browse_*` tools.
final class FakeBrowserDriver: BrowserDriver, @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var url = "https://example.com/"
        var title = "Example"
        var snapshot = BrowserSnapshot(url: "https://example.com/", tree: "- link \"More\" [ref=e1]", refs: ["e1": BrowserRef(role: "link", name: "More")])
        var readContent = "Hello"
        var attributes: [String: String] = [:]
        var evaluation = ""
        var tabs: [BrowserTab] = [BrowserTab(id: "t1", title: "Example", url: "https://example.com/", isActive: true)]
        var failure: BrowserDriverError?
        var hasPage = true
        var headed = false
        var screenshotBytes: Data?
        /// What `command` answers (its `data`), and what `manual` says.
        var commandReply: JSONValue = .null
        var manualText = "Core Commands:\n  open <url>\n  get title\n\nStreaming:\n  stream enable\n\nSnapshot Options:\n  -i"
        /// `BrowserDriver.generation`: a test raises it for a browser that closed and opened again.
        var generation = 0
        /// Commands that fail (by their words, "tab close c1"), the others answering as usual.
        var failingCommands: [String: BrowserDriverError] = [:]
    }

    var generation: Int { state.withLock { $0.generation } }

    let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [String] { state.withLock { $0.calls } }

    @discardableResult
    private func note(_ call: String) throws -> State {
        try state.withLock { state in
            state.calls.append(call)
            if let failure = state.failure { throw failure }
            return state
        }
    }

    func open(_ url: String) async throws -> BrowserPage {
        try note("open \(url)")
        state.withLock { $0.url = url; $0.hasPage = true }
        return BrowserPage(url: url, title: state.withLock { $0.title })
    }

    func snapshot(interactive: Bool, selector: String?) async throws -> BrowserSnapshot {
        try note("snapshot interactive=\(interactive) selector=\(selector ?? "-")").snapshot
    }

    func click(_ ref: String) async throws { try note("click \(ref)") }
    func fill(_ ref: String, text: String) async throws { try note("fill \(ref) \(text)") }
    func select(_ ref: String, value: String) async throws { try note("select \(ref) \(value)") }
    func press(_ key: String) async throws { try note("press \(key)") }
    func scroll(_ direction: BrowserScrollDirection, pixels: Int) async throws { try note("scroll \(direction.rawValue) \(pixels)") }

    func read() async throws -> BrowserReadout {
        let state = try note("read")
        return BrowserReadout(url: state.url, content: state.readContent)
    }

    func screenshot(to file: URL) async throws {
        let state = try note("screenshot")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (state.screenshotBytes ?? Data()).write(to: file)
    }

    func back() async throws -> BrowserPage {
        let state = try note("back")
        return BrowserPage(url: state.url, title: state.title)
    }

    func tabs() async throws -> [BrowserTab] { try note("tabs").tabs }
    func newTab(_ url: String?) async throws { try note("newTab \(url ?? "-")") }
    func selectTab(_ id: String) async throws { try note("selectTab \(id)") }
    func closeTab(_ id: String?) async throws { try note("closeTab \(id ?? "-")") }

    func attribute(_ name: String, of ref: String) async throws -> String? {
        try note("attribute \(name) \(ref)").attributes["\(ref).\(name)"]
    }

    func evaluate(_ script: String) async throws -> String {
        try note("evaluate").evaluation
    }

    func currentURL() async throws -> String? {
        let state = try note("currentURL")
        return state.hasPage ? state.url : nil
    }

    func setHeaded(_ headed: Bool) async throws -> BrowserPage {
        let state = try note("setHeaded \(headed)")
        self.state.withLock { $0.headed = headed }
        return BrowserPage(url: state.url, title: state.title)
    }

    func close() async throws { try note("close") }

    func command(_ arguments: [String], text: Bool) async throws -> JSONValue {
        let state = try note("command " + arguments.joined(separator: " ") + (text ? " (text)" : ""))
        if let failure = state.failingCommands[arguments.joined(separator: " ")] { throw failure }
        return state.commandReply
    }

    func manual(_ topic: String?) async throws -> String {
        try note("manual \(topic ?? "-")").manualText
    }
}

/// A hub whose browser is `driver`, installed as far as the tools can tell, and the tool context that reaches it.
struct FakeBrowserSetup {
    let driver = FakeBrowserDriver()
    let hub: BrowserHub
    let botID = UUID()
    let mode: BrowserMode
    /// The configurations the hub asked drivers for.
    let configs = OSAllocatedUnfairLock<[AgentBrowserConfig]>(initialState: [])

    init(mode: BrowserMode = .background, ready: Bool = true, profiles: URL? = nil) {
        self.mode = mode
        let driver = driver
        let configs = configs
        hub = BrowserHub(
            profilesDirectory: profiles,
            locate: {
                var status = BrowserStatus(agentBrowser: "/fake/agent-browser",
                                           program: BrowserProgram(kind: .chrome, executable: "/fake/chrome", major: 155))
                if !ready { status.missing = [.init(name: "Chrome")] }
                return status
            },
            makeDriver: { config in
                configs.withLock { $0.append(config) }
                return driver
            })
    }

    func context(directory: URL = FileManager.default.temporaryDirectory, provider: SearchProvider = .duckduckgo,
                 keys: SearchKeys? = nil) -> ToolContext {
        var context = ToolContext(workingDirectory: directory, botID: botID)
        context.browser = BrowserAccess(hub: hub, available: true, mode: mode, searchProvider: provider, searchKeys: keys)
        return context
    }
}

/// Answers the requests of the search tests from a closure (the status and body for a request). Tests that use it run one
/// at a time, because the closure is shared.
final class SearchStubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)
    static let handler = OSAllocatedUnfairLock<Handler>(initialState: { _ in (404, Data()) })
    static let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static func session(_ handler: @escaping Handler) -> URLSession {
        self.handler.withLock { $0 = handler }
        requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        Self.requests.withLock { $0.append(request) }
        let answer = Self.handler.withLock { $0 }(request)
        // Status 0 stands for a network that fails.
        if answer.status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
