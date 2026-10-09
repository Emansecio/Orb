import Foundation
import Testing
@testable import Orb

/// The Server-Sent Events reader.
struct SSEDecoderTests {
    private func decode(_ text: String, chunk: Int = .max) -> [SSEEvent] {
        decode(Array(text.utf8), chunk: chunk)
    }

    private func decode(_ bytes: [UInt8], chunk: Int = .max) -> [SSEEvent] {
        var decoder = SSEDecoder()
        var events: [SSEEvent] = []
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start.addingReportingOverflow(chunk).partialValue)
            events += decoder.feed(bytes[start..<end])
            start = end
        }
        if let last = decoder.finish() { events.append(last) }
        return events
    }

    private func data(_ events: [SSEEvent]) -> [String] { events.map(\.data) }

    @Test func readsDataLinesWithOrWithoutTheSpace() {
        #expect(data(decode("data: {\"a\":1}\n\ndata:{\"a\":2}\n\n")) == [#"{"a":1}"#, #"{"a":2}"#])
    }

    @Test func recognisesTheDoneSentinel() {
        let events = decode("data: {}\n\ndata: [DONE]\n\n")
        #expect(events.map(\.isDone) == [false, true])
    }

    @Test func dropsCommentsBlankLinesAndEventsWithoutData() {
        #expect(decode(": OPENROUTER PROCESSING\n\n").isEmpty)
        #expect(decode("\n\n\n").isEmpty)
        #expect(decode("data: \n\n").isEmpty)
        #expect(decode("data:\n\n").isEmpty)
        #expect(decode("event: ping\n\n").isEmpty)
        #expect(decode("retry: 1000\nid: 7\n\n").isEmpty)
        // A comment in the middle of an event does not break it.
        #expect(data(decode("data: a\n: keep-alive\ndata: b\n\n")) == ["a\nb"])
    }

    @Test func carriesTheEventNameAndForgetsItAfterwards() {
        let events = decode("event: message_start\ndata: {\"n\":1}\n\ndata: {\"n\":2}\n\nevent: ping\n\n")
        #expect(events.map(\.name) == ["message_start", nil])
        #expect(data(events) == [#"{"n":1}"#, #"{"n":2}"#])
    }

    @Test func joinsMultiLineDataWithNewlines() {
        let events = decode("data: {\"a\":\ndata: 1}\n\n")
        #expect(data(events) == ["{\"a\":\n1}"])
        #expect(JSONValue.parse(events[0].data)?["a"]?.int == 1)
    }

    @Test func acceptsLFCRLFAndCRLineEndings() {
        let expected = [#"{"a":1}"#, #"{"a":2}"#, #"{"a":3}"#]
        #expect(data(decode("data: {\"a\":1}\n\ndata: {\"a\":2}\n\ndata: {\"a\":3}\n\n")) == expected)
        #expect(data(decode("data: {\"a\":1}\r\n\r\ndata: {\"a\":2}\r\n\r\ndata: {\"a\":3}\r\n\r\n")) == expected)
        #expect(data(decode("data: {\"a\":1}\r\rdata: {\"a\":2}\r\rdata: {\"a\":3}\r\r")) == expected)
        #expect(data(decode("data: {\"a\":1}\r\n\ndata: {\"a\":2}\n\r\ndata: {\"a\":3}\r\r")) == expected)
    }

    @Test func aCRLFSplitBetweenChunksIsOneLineBreak() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Array("data: a\r".utf8)).isEmpty)
        // The LF closes nothing: if it counted as a blank line the event would already be out.
        #expect(decoder.feed(Array("\n".utf8)).isEmpty)
        #expect(data(decoder.feed(Array("\r\n".utf8))) == ["a"])
        #expect(decoder.finish() == nil)
    }

    @Test func partialLinesWaitForTheirEnd() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Array("da".utf8)).isEmpty)
        #expect(decoder.feed(Array("ta: hel".utf8)).isEmpty)
        #expect(decoder.feed(Array("lo\n".utf8)).isEmpty)
        #expect(data(decoder.feed(Array("\n".utf8))) == ["hello"])
    }

    @Test func aCharacterSplitAcrossChunksStaysWhole() {
        let text = "data: Olá, mundo! \u{1F600} ação\n\n"
        let whole = decode(text)
        #expect(data(whole) == ["Olá, mundo! \u{1F600} ação"])
        for size in 1...7 { #expect(decode(text, chunk: size) == whole) }
    }

    @Test func everyChunkingGivesTheSameEvents() {
        let text = ": hi\r\nevent: a\r\ndata: 1\r\ndata: 2\r\n\r\ndata: \u{E9}\n\r\ndata: [DONE]\n\n"
        let whole = decode(text)
        #expect(whole.count == 3)
        for size in 1...text.utf8.count { #expect(decode(text, chunk: size) == whole) }
    }

    @Test func aStreamCutInTheMiddleOfAnEventStillDeliversIt() {
        #expect(data(decode("data: {\"a\":1}\n\ndata: {\"a\":2}\n")) == [#"{"a":1}"#, #"{"a":2}"#])
        #expect(data(decode("data: {\"a\":3}")) == [#"{"a":3}"#])
        #expect(decode("data: x\n\n: trailing comment").count == 1)
    }

    @Test func surroundingWhitespaceOfTheDataIsIgnored() {
        #expect(data(decode("data:   {\"a\":1}  \n\n")) == [#"{"a":1}"#])
    }
}

/// The request/response pipeline the three clients share, exercised through each of them.
struct ProviderTransportTests {
    private enum Format: CaseIterable {
        case chat, messages, responses

        var path: String {
            switch self {
            case .chat: "chat/completions"
            case .messages: "messages"
            case .responses: "responses"
            }
        }

        /// A stream of one text delta and a normal ending, for this wire format.
        var happyStream: String {
            switch self {
            case .chat:
                #"data: {"choices":[{"delta":{"content":"oi"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            case .messages:
                [#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"oi"}}"#,
                 #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"message_stop"}"#]
                    .map { "event: e\ndata: \($0)\n\n" }.joined()
            case .responses:
                [#"{"type":"response.output_text.delta","delta":"oi"}"#, #"{"type":"response.completed","response":{}}"#]
                    .map { "data: \($0)\n\n" }.joined()
            }
        }

        func client(host: String, key: String? = "k") -> any LLMClient {
            let base = URL(string: "https://\(host)/v1")!
            switch self {
            case .chat: return OpenAIClient(baseURL: base, apiKey: key, session: StubProtocol.session)
            case .messages: return AnthropicClient(baseURL: base, apiKey: key, session: StubProtocol.session)
            case .responses: return ResponsesClient(baseURL: base, apiKey: key, session: StubProtocol.session)
            }
        }
    }

    private func run(_ format: Format, host: String, _ stub: StubProtocol.Response) async throws -> [LLMEvent] {
        StubProtocol.queue(host: host, [stub])
        var events: [LLMEvent] = []
        for try await event in format.client(host: host).stream(model: "m", messages: [.user("oi")], tools: []) { events.append(event) }
        return events
    }

    @Test func allThreeClientsSendTheSameKindOfStreamingRequest() async throws {
        for format in Format.allCases {
            let host = "transport-\(format).test"
            _ = try await run(format, host: host, .init(body: format.happyStream))
            let sent = try #require(StubProtocol.sent(to: host).first)
            #expect(sent.request.httpMethod == "POST")
            #expect(sent.request.url?.path() == "/v1/" + format.path)
            #expect(sent.request.timeoutInterval == ProviderTransport.idleTimeout)
            #expect(ProviderTransport.idleTimeout == 300)
            #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(sent.request.value(forHTTPHeaderField: "Accept") == (format == .messages ? nil : "text/event-stream"))
            #expect(sent.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Orb/") == true)
            #expect(sent.body?["stream"] == .bool(true))
        }
    }

    @Test func allThreeClientsReadTheSameStreamWhateverTheLineEndingsAndFraming() async throws {
        for format in Format.allCases {
            let crlf = format.happyStream.replacingOccurrences(of: "\n", with: "\r\n")
            let cr = format.happyStream.replacingOccurrences(of: "\n", with: "\r")
            let comments = ": keep-alive\n\n" + format.happyStream
            let cut = String(format.happyStream.dropLast()) // the last blank line never arrives
            let expected = try await run(format, host: "framing-\(format).test", .init(body: format.happyStream))
            #expect(expected.first == .text("oi"))
            #expect(expected.last == .finished(.done, nil))
            for (index, variant) in [crlf, cr, comments, cut].enumerated() {
                #expect(try await run(format, host: "framing-\(format)-\(index).test", .init(body: variant)) == expected)
            }
        }
    }

    @Test func httpFailuresAreReadableAndCarryRetryAfter() async {
        for format in Format.allCases {
            let stub = StubProtocol.Response(status: 429, body: #"{"error":{"message":"Slow down"}}"#, headers: ["retry-after-ms": "1500"])
            await #expect(throws: LLMError.http(status: 429, message: "Slow down", retryAfter: 1.5)) {
                _ = try await run(format, host: "limit-\(format).test", stub)
            }
        }
    }

    @Test func aTooLongPromptIsAContextOverflowForEveryFormat() async {
        for format in Format.allCases {
            let stub = StubProtocol.Response(status: 400, body: #"{"error":{"message":"maximum context length is 8192 tokens"}}"#)
            await #expect(throws: LLMError.contextExceeded("maximum context length is 8192 tokens")) {
                _ = try await run(format, host: "overflow-\(format).test", stub)
            }
        }
    }

    @Test func aDataLineThatIsNotJSONIsAnInvalidResponse() async {
        for format in Format.allCases {
            await #expect(throws: LLMError.invalidResponse("not json")) {
                _ = try await run(format, host: "garbage-\(format).test", .init(body: "data: not json\n\n"))
            }
        }
    }

    @Test func aReplyThatIsNotAStreamSaysWhatItWasInsteadOfLookingCut() async {
        for format in Format.allCases {
            // A gateway that ignored `stream: true` and answered with its error, with status 200.
            do {
                _ = try await run(format, host: "json-error-\(format).test", .init(body: #"{"error":{"message":"modelo inexistente"}}"#))
                Issue.record("should have thrown")
            } catch let error as LLMError {
                #expect(error.localizedDescription.contains("modelo inexistente"))
            } catch {
                Issue.record("unexpected \(error)")
            }
            // A proxy's page.
            do {
                _ = try await run(format, host: "html-\(format).test", .init(body: "<html>entre no Wi-Fi</html>"))
                Issue.record("should have thrown")
            } catch let error as LLMError {
                #expect(error == .invalidResponse("o provedor não respondeu em streaming: <html>entre no Wi-Fi</html>"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        // Nothing at all, or comments only, stay the cut stream they always were.
        for body in ["", ": keep-alive\n\n"] {
            let events = try? await run(.chat, host: "empty-\(body.count).test", .init(body: body))
            #expect(events == [.finished(.incomplete, nil)])
        }
    }

    @Test func aConnectionClosedInTheMiddleOfAnEventCanBeTriedAgain() async {
        let stream = #"data: {"choices":[{"delta":{"content":"oi"}}]}"# + "\n\n" + #"data: {"choices":[{"del"#
        do {
            _ = try await run(.chat, host: "cut-line.test", .init(body: stream))
            Issue.record("should have thrown")
        } catch let error as LLMError {
            #expect(error.isRetryable) // not "resposta inválida", which is never retried
            if case .network = error {} else { Issue.record("not a network error: \(error)") }
        } catch {
            Issue.record("unexpected \(error)")
        }
        // The last event complete but for its blank line is still delivered.
        let whole = try? await run(.chat, host: "cut-whole.test", .init(body: #"data: {"choices":[{"delta":{"content":"a"}}]}"#))
        #expect(whole?.first == .text("a"))
    }

    @Test func transportFailuresBecomeNetworkErrorsForEveryFormat() async {
        for format in Format.allCases {
            do {
                _ = try await run(format, host: "down-\(format).test", .init(failure: URLError.networkConnectionLost.rawValue))
                Issue.record("should have thrown")
            } catch let error as LLMError {
                #expect(error.isRetryable)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func doneEndsTheReadingAndIsOnlyAStopSignalForChat() async throws {
        let stream = #"data: {"choices":[{"delta":{"content":"a"}}]}"# + "\n\ndata: [DONE]\n\n"
            + #"data: {"choices":[{"delta":{"content":"depois"}}]}"# + "\n\n"
        let events = try await run(.chat, host: "done.test", .init(body: stream))
        #expect(events == [.text("a"), .finished(.done, nil)])
    }

    @Test func aChatStreamWithoutDoneOrFinishReasonIsIncomplete() async throws {
        let events = try await run(.chat, host: "transport-cut.test", .init(body: #"data: {"choices":[{"delta":{"content":"a"}}]}"# + "\n\n"))
        #expect(events == [.text("a"), .finished(.incomplete, nil)])
    }

    @Test func errorsInsideTheStreamAreThrownByTheirMapper() async {
        await #expect(throws: LLMError.stream(type: "error", message: "boom")) {
            _ = try await run(.chat, host: "chat-error.test", .init(body: #"data: {"error":{"message":"boom"}}"# + "\n\n"))
        }
        await #expect(throws: LLMError.stream(type: "overloaded_error", message: "Busy")) {
            _ = try await run(.messages, host: "messages-error.test",
                              .init(body: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Busy"}}"# + "\n\n"))
        }
        await #expect(throws: LLMError.stream(type: "server_error", message: "Down")) {
            _ = try await run(.responses, host: "responses-error.test",
                              .init(body: #"data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"Down"}}}"# + "\n\n"))
        }
    }

    @Test func aChatErrorAfterTheOKIsRetryableLikeTheOtherFormats() async {
        let body = #"data: {"error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"# + "\n\n"
        do {
            _ = try await run(.chat, host: "chat-midstream.test", .init(body: body))
            Issue.record("the error chunk should have been thrown")
        } catch let error as LLMError {
            #expect(error == .stream(type: "server_error", message: "Provider disconnected unexpectedly"))
            #expect(error.isRetryable)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func aNumericChatErrorCodeIsTheHTTPStatus() async {
        for (host, code) in [("chat-429.test", "429"), ("chat-429s.test", #""429""#)] {
            let body = #"data: {"error":{"code":\#(code),"message":"Rate limit exceeded"}}"# + "\n\n"
            do {
                _ = try await run(.chat, host: host, .init(body: body))
                Issue.record("the error chunk should have been thrown")
            } catch let error as LLMError {
                #expect(error == .http(status: 429, message: "Rate limit exceeded"))
                #expect(error.isRetryable)
            } catch { Issue.record("unexpected \(error)") }
        }
    }

    @Test func aCodeOutsideTheHTTPRangeIsNotAStatus() async {
        // A gateway speaking JSON-RPC style codes must not turn into "O provedor respondeu -32000" or be retried as a 503.
        for (host, code) in [("chat-rpc.test", "-32000"), ("chat-zero.test", "0"), ("chat-503-ish.test", "1503")] {
            let body = #"data: {"error":{"code":\#(code),"message":"Upstream failed"}}"# + "\n\n"
            do {
                _ = try await run(.chat, host: host, .init(body: body))
                Issue.record("the error chunk should have been thrown")
            } catch let error as LLMError {
                #expect(error == .stream(type: code, message: "Upstream failed"))
                #expect(!error.isRetryable)
            } catch { Issue.record("unexpected \(error)") }
        }
    }

    @Test func aChatErrorAboutTheContextStillOverflows() async {
        await #expect(throws: LLMError.contextExceeded("maximum context length is 8192 tokens")) {
            _ = try await run(.chat, host: "chat-ctx.test",
                              .init(body: #"data: {"error":{"code":400,"message":"maximum context length is 8192 tokens"}}"# + "\n\n"))
        }
    }

    @Test func aNullErrorFieldOnANormalChatChunkIsIgnored() async throws {
        let body = #"data: {"error":null,"choices":[{"delta":{"content":"a"}}]}"# + "\n\n" + "data: [DONE]\n\n"
        let events = try await run(.chat, host: "chat-null-error.test", .init(body: body))
        #expect(events.contains(.text("a")))
    }

    @Test func modelListsGoThroughTheSameStatusCheck() async {
        StubProtocol.queue(host: "transport-models.test", [.init(status: 403, body: #"{"error":{"message":"nope"}}"#)])
        let request = ProviderTransport.authorizedRequest(URL(string: "https://transport-models.test/v1/models")!, apiKey: "k")
        await #expect(throws: LLMError.http(status: 403, message: "nope")) {
            _ = try await ProviderTransport.fetch(request, session: StubProtocol.session)
        }
    }
}
