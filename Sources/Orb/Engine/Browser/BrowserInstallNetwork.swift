import Foundation
import CryptoKit

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

    /// "sha256:abc..." (GitHub's `digest` of a release asset) -> "abc...", nil for anything else.
    static func parseDigest(_ digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).trimmingCharacters(in: .whitespaces).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
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

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orb", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
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
        init(progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
