import Foundation
import Testing
@testable import Orb

/// A stand-in `claude` for the model list: answers `initialize`, `set_model` and `get_context_usage` as Claude Code 2.1.322
/// did in headless probes, and logs every request. `FAKE_MODE`: "old" refuses what an older CLI does not know, "dies" ends
/// after the list, "empty" lists no model.
private let fakeListingClaude = #"""
#!/usr/bin/python3
import json, os, sys

mode = os.environ.get("FAKE_MODE", "")
windows = {"default": 1000000, "big": 1000000, "small": 200000}
current = None
log = open(os.environ["FAKE_LOG"], "a")

def reply(rid, body=None, error=None):
    response = {"subtype": "error", "request_id": rid, "error": error} if error else {"subtype": "success", "request_id": rid, "response": body or {}}
    print(json.dumps({"type": "control_response", "response": response}), flush=True)

for line in sys.stdin:
    try:
        message = json.loads(line)
    except Exception:
        continue
    request, rid = message.get("request", {}), message.get("request_id")
    subtype = request.get("subtype")
    log.write("%s %s\n" % (subtype, request.get("model", "")))
    log.flush()
    if subtype == "initialize":
        names = [] if mode == "empty" else ["default", "big", "small", "broken", "wide[1m]", "silent"]
        reply(rid, {"models": [{"value": name, "displayName": name} for name in names]})
        if mode in ("dies", "empty"):
            sys.exit(0)
    elif mode == "old":
        reply(rid, error="Unsupported control request subtype: %s" % subtype)
    elif subtype == "set_model":
        if request.get("model") == "broken":
            reply(rid, error="Model 'broken' not found")
        else:
            current = request.get("model")
            reply(rid)
    elif subtype == "get_context_usage":
        # Other lines come between a request and its answer.
        print(json.dumps({"type": "system", "subtype": "status"}), flush=True)
        window = windows.get(current)
        # `maxTokens` is what the CLI plans by, which a setting can shrink; `rawMaxTokens` is the model's.
        reply(rid, {"model": current, "rawMaxTokens": window, "maxTokens": 400000} if window else {"model": current})
"""#

/// The windows of Claude Code's models are asked from the CLI when the list is read, so they are known before any turn.
@Suite final class ClaudeCodeModelWindowTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "orb-claude-windows-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { removeTestFolder(root) }

    private var log: URL { root.appending(path: "requests.log") }

    private func listed(mode: String = "") async throws -> [ProviderModel] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appending(path: "claude")
        try writeExecutable(fakeListingClaude, to: script)
        let process = try LineProcess(executable: script, arguments: [], directory: root,
                                      environment: ["PATH": "/usr/bin:/bin", "FAKE_LOG": log.path, "FAKE_MODE": mode])
        process.terminate(after: 20)
        defer {
            process.closeInput()
            process.terminate(after: 1)
        }
        return await ClaudeCode.models(asking: process)
    }

    private var requests: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func eachListedModelGetsTheWindowTheCLIStatesForIt() async throws {
        let models = try await listed()
        #expect(models.map(\.id) == ["default", "big", "small", "broken", "wide[1m]", "silent"])
        // The model's own window, not the one the CLI plans by; a model the CLI refuses, or says no window for, has none.
        #expect(models.map(\.contextLength) == [1_000_000, 1_000_000, 200_000, nil, 1_000_000, nil])
        // One model at a time, each asked only after it was chosen; nothing is asked about a refused model, and the
        // million-token id already says its window.
        #expect(requests == ["initialize", "set_model default", "get_context_usage", "set_model big", "get_context_usage",
                             "set_model small", "get_context_usage", "set_model broken", "set_model silent", "get_context_usage"])
    }

    @Test func aCLIThatDoesNotKnowTheRequestsStillListsItsModels() async throws {
        let models = try await listed(mode: "old")
        #expect(models.map(\.id) == ["default", "big", "small", "broken", "wide[1m]", "silent"])
        #expect(models.map(\.contextLength) == [nil, nil, nil, nil, 1_000_000, nil])
    }

    @Test func aCLIThatEndsAfterTheListLeavesTheWindowsUnknown() async throws {
        let models = try await listed(mode: "dies")
        #expect(models.map(\.id) == ["default", "big", "small", "broken", "wide[1m]", "silent"])
        #expect(models.map(\.contextLength) == [nil, nil, nil, nil, 1_000_000, nil])
    }

    @Test func aCLIThatListsNoModelFallsBackToTheDocumentedAliases() async throws {
        #expect(try await listed(mode: "empty") == ClaudeCodeModels.fallback)
    }

    @Test func theWireAsksForAModelAndReadsTheWindowOfTheAnswer() throws {
        let chosen = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_7", subtype: "set_model", model: "opus")))
        #expect(chosen["request"] == .object(["subtype": .string("set_model"), "model": .string("opus")]))
        let asked = try #require(JSONValue.parse(ClaudeCodeWire.controlRequest(id: "req_8", subtype: "get_context_usage")))
        #expect(asked["request"] == .object(["subtype": .string("get_context_usage")]))

        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"req_8","response":{"model":"claude-opus-5-5","maxTokens":400000,"rawMaxTokens":1000000}}}"#
        let answer = try #require(ClaudeCodeWire.controlResponse(line, requestID: "req_8"))
        #expect(ClaudeCodeWire.window(fromContextUsage: answer) == 1_000_000)
        #expect(ClaudeCodeWire.controlResponse(line, requestID: "req_9") == nil)
        #expect(ClaudeCodeWire.controlResponse(#"{"type":"system","subtype":"status"}"#, requestID: "req_8") == nil)
        // Only the window the CLI plans by, an error, a window that is none.
        func window(_ response: String) throws -> Int? { ClaudeCodeWire.window(fromContextUsage: try #require(JSONValue.parse(response))) }
        #expect(try window(#"{"subtype":"success","response":{"maxTokens":200000}}"#) == 200_000)
        #expect(try window(#"{"subtype":"error","error":"Unsupported control request subtype: get_context_usage"}"#) == nil)
        #expect(try window(#"{"subtype":"success","response":{"rawMaxTokens":0}}"#) == nil)
    }
}
