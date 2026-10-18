import Foundation
import CryptoKit
import os

/// What the installer needs from the network, so tests answer without one.
protocol InstallNetwork: Sendable {
    /// A small document (a release's JSON).
    func data(from url: URL) async throws -> Data
    /// Downloads `url` into `file` (replacing it), reporting bytes received and expected as it goes, and returns the SHA-256
    /// of what was written, in lowercase hexadecimal.
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String
}

enum Checksum {
    /// The SHA-256 of a file, read in pieces (the files are tens of megabytes).
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The real network: `URLSession`, with a download that reports its progress and survives being cancelled.
struct URLSessionInstallNetwork: InstallNetwork {
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Whether a redirect may be followed: only to an `https` address. A download the app is about to run must not travel in the
    /// clear at any step, whatever the server it started from says.
    static func allowsRedirect(to url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    /// Follows redirects to `https` only, and remembers that one was refused.
    final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var refusedAddress: String?
        var refused: String? { lock.withLock { refusedAddress } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if URLSessionInstallNetwork.allowsRedirect(to: request.url) {
                completionHandler(request)
            } else {
                lock.withLock { refusedAddress = request.url?.absoluteString ?? "?" }
                completionHandler(nil)
            }
        }
    }

    static func refusal(_ address: String) -> BrowserInstallError {
        .failed("arquivo", detail: "o servidor mandou baixar de um endereço sem HTTPS (\(address.clipped(to: 60))); por segurança nada foi baixado.")
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orb", forHTTPHeaderField: "User-Agent")
        let redirects = HTTPSOnlyRedirects()
        do {
            let (data, response) = try await session.data(for: request, delegate: redirects)
            if let refused = redirects.refused { throw Self.refusal(refused) }
            try Self.check(response)
            return data
        } catch {
            throw Self.translate(error)
        }
    }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Orb", forHTTPHeaderField: "User-Agent")
        let delegate = DownloadDelegate(progress: progress)
        do {
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let refused = delegate.redirects.refused { throw Self.refusal(refused) }
            try Self.check(response)
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: file)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: temporary, to: file)
            return try Checksum.sha256(of: file)
        } catch {
            throw Self.translate(error)
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 403, 429: throw BrowserInstallError.rateLimited
        case 404: throw BrowserInstallError.failed("arquivo", detail: "o endereço não existe mais (HTTP 404).")
        default: throw BrowserInstallError.failed("arquivo", detail: "o servidor respondeu HTTP \(http.statusCode).")
        }
    }

    /// The error as the person should read it.
    static func translate(_ error: Error) -> Error {
        if error is CancellationError || error is BrowserInstallError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed, .cannotLoadFromNetwork:
                return BrowserInstallError.noNetwork
            default: return BrowserInstallError.failed("arquivo", detail: urlError.localizedDescription)
            }
        }
        if BrowserInstaller.isOutOfSpace(error) { return BrowserInstallError.diskFull(needed: nil) }
        return error
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64, Int64?) -> Void
        let redirects = HTTPSOnlyRedirects()
        init(progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.progress = progress }

        /// didWriteData fires hundreds of times a second: pass on at most ~10 a second, or when the fraction moves 1%.
        /// The first and the last (everything received) always go through. Callbacks arrive serially on the session queue.
        private let throttle = OSAllocatedUnfairLock(initialState: (at: ContinuousClock.Instant?.none, fraction: -1.0))

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            let fraction = total.map { Double(totalBytesWritten) / Double($0) } ?? -1
            let now = ContinuousClock.now
            let pass = throttle.withLock { state -> Bool in
                let isLast = total != nil && totalBytesWritten >= total!
                guard state.at == nil || isLast || now - state.at! >= .milliseconds(100) || fraction - state.fraction >= 0.01 else { return false }
                state = (now, fraction)
                return true
            }
            if pass { progress(totalBytesWritten, total) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
