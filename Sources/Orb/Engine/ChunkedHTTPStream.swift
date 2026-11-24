import Foundation
import os

/// Streams HTTP response bodies as native `Data` chunks (16–64 KB) via `URLSessionDataDelegate`, eliminating the
/// per-byte async overhead of `URLSession.AsyncBytes` while preserving HTTP/2 + TLS keep-alive on the shared session.
enum ChunkedHTTPStream {
    typealias RedirectHandler = @Sendable (URLSession, URLSessionTask, HTTPURLResponse, URLRequest) async -> URLRequest?

    private static let sharedMultiplex: MultiplexSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return MultiplexSession(configuration: config)
    }()

    /// Dedicated persistent session for remote MCP HTTP calls: no disk cache, keeps HTTP/2 + TLS keep-alive,
    /// and enforces same-host / no-downgrade redirects without creating a fresh `URLSession` per call.
    private static let sharedMCPMultiplex = MultiplexSession(configuration: .ephemeral) { _, task, _, next in
        RedirectGuard.follows(from: task.originalRequest?.url, to: next.url) ? next : nil
    }

    static func open(_ request: URLRequest, using session: URLSession = .shared,
                     onRedirect: RedirectHandler? = nil) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        if session === URLSession.shared, onRedirect == nil {
            return try await sharedMultiplex.open(request)
        }
        if session === HTTPTransport.defaultSession {
            return try await sharedMCPMultiplex.open(request)
        }
        let config = (session.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        let oneShot = MultiplexSession(configuration: config, onRedirect: onRedirect, invalidatesAfterTask: true)
        return try await oneShot.open(request)
    }

    private final class MultiplexSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private final class Entry: @unchecked Sendable {
            var task: URLSessionDataTask?
            var responseCont: CheckedContinuation<(AsyncThrowingStream<Data, Error>, URLResponse), Error>?
            var streamCont: AsyncThrowingStream<Data, Error>.Continuation?
            var cancelled = false
        }

        private let entries = OSAllocatedUnfairLock<[Int: Entry]>(initialState: [:])
        private let onRedirect: RedirectHandler?
        private let invalidatesAfterTask: Bool
        private var urlSession: URLSession!

        init(configuration: URLSessionConfiguration, onRedirect: RedirectHandler? = nil, invalidatesAfterTask: Bool = false) {
            self.onRedirect = onRedirect
            self.invalidatesAfterTask = invalidatesAfterTask
            super.init()
            self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }

        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
            let task = urlSession.dataTask(with: request)
            let id = task.taskIdentifier
            let entry = Entry()
            entry.task = task
            entries.withLock { $0[id] = entry }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled = entries.withLock { map -> Bool in
                        guard let e = map[id], !e.cancelled else { return true }
                        e.responseCont = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        task.resume()
                    }
                }
            } onCancel: {
                self.cancel(taskID: id)
            }
        }

        private func cancel(taskID: Int) {
            let (task, resp, stream) = entries.withLock { map -> (URLSessionDataTask?, CheckedContinuation<(AsyncThrowingStream<Data, Error>, URLResponse), Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
                guard let e = map.removeValue(forKey: taskID) else { return (nil, nil, nil) }
                e.cancelled = true
                let out = (e.task, e.responseCont, e.streamCont)
                e.task = nil; e.responseCont = nil; e.streamCont = nil
                return out
            }
            task?.cancel()
            if invalidatesAfterTask { urlSession.invalidateAndCancel() }
            resp?.resume(throwing: CancellationError())
            stream?.finish(throwing: CancellationError())
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let onRedirect else { return request }
            return await onRedirect(session, task, response, request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let id = dataTask.taskIdentifier
            let (stream, streamCont) = AsyncThrowingStream<Data, Error>.makeStream()
            streamCont.onTermination = { [weak self] _ in self?.cancel(taskID: id) }
            let respCont = entries.withLock { map -> CheckedContinuation<(AsyncThrowingStream<Data, Error>, URLResponse), Error>? in
                guard let e = map[id], !e.cancelled else { return nil }
                e.streamCont = streamCont
                let c = e.responseCont
                e.responseCont = nil
                return c
            }
            if let respCont {
                completionHandler(.allow)
                respCont.resume(returning: (stream, response))
            } else {
                completionHandler(.cancel)
                streamCont.finish(throwing: CancellationError())
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let cont = entries.withLock { $0[dataTask.taskIdentifier]?.streamCont }
            cont?.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (resp, stream) = entries.withLock { map -> (CheckedContinuation<(AsyncThrowingStream<Data, Error>, URLResponse), Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
                guard let e = map.removeValue(forKey: task.taskIdentifier) else { return (nil, nil) }
                let out = (e.responseCont, e.streamCont)
                e.task = nil; e.responseCont = nil; e.streamCont = nil
                return out
            }
            if invalidatesAfterTask { urlSession.finishTasksAndInvalidate() }
            if let error {
                resp?.resume(throwing: error)
                stream?.finish(throwing: error)
            } else {
                resp?.resume(throwing: URLError(.badServerResponse))
                stream?.finish()
            }
        }
    }
}
