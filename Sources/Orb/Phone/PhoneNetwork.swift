import Foundation
import Network
import Security

// Who may reach the phone server and how it is paired (docs/CELULAR.md). Pure checks, kept apart from the socket so they
// are tested on their own.

enum PhonePeer {
    /// Tailscale's addresses (100.64.0.0/10 and fd7a:115c:a1e0::/48) and this Mac's own loopback. Anything else (the home
    /// network, the internet through a forwarded port) is refused before a byte is read: the token is the second lock,
    /// not the only one.
    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isAllowed(bytes: [UInt8](address.rawValue))
        case .ipv6(let address): return isAllowed(bytes: [UInt8](address.rawValue))
        default: return false
        }
    }

    static func isAllowed(bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return bytes[0] == 127 || isTailscale(ipv4: bytes)
        case 16:
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true } // ::1
            // An IPv4 client on a dual-stack socket can arrive as ::ffff:a.b.c.d.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isAllowed(bytes: Array(bytes[12..<16]))
            }
            return bytes[0..<6] == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        default:
            return false
        }
    }

    /// 100.64.0.0/10: the shared address space Tailscale gives its devices.
    static func isTailscale(ipv4 bytes: [UInt8]) -> Bool {
        bytes.count == 4 && bytes[0] == 100 && bytes[1] & 0xC0 == 64
    }

    /// A short name for the peer, to count failed logins per address (never shown with the token).
    static func key(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        return "\(host)"
    }

    /// This Mac's Tailscale address, read from its network interfaces; nil while Tailscale is off or not installed.
    static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                withUnsafeBytes(of: inet.pointee.sin_addr.s_addr) { [UInt8]($0) }
            }
            if isTailscale(ipv4: bytes) { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
    }
}

enum PhonePairing {
    /// 32 random bytes in base64url without padding: 43 characters.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }

    /// Compares in time that does not depend on where the strings differ, so a wrong token says nothing about the right one.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<b.count {
            difference |= (index < a.count ? a[index] : 0) ^ b[index]
        }
        return difference == 0
    }

    /// What the QR code holds. Every value is percent-encoded beyond what `URLComponents` does (`+` included), so a
    /// Mac named "Mac + iPad" reaches the phone as written.
    static func link(host: String, port: UInt16, token: String, mac: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "orb://parear?host=\(encode(host))&port=\(port)&token=\(encode(token))&mac=\(encode(mac))"
    }
}

/// Counts wrong tokens per address: after `limit` in a `window`, that address is turned away until the window passes.
struct PhoneFailureLimiter {
    var limit = 5
    var window: TimeInterval = 60
    private var failures: [String: [Date]] = [:]

    mutating func record(_ peer: String, at now: Date = .now) {
        failures[peer, default: []].append(now)
        prune(now)
    }

    func isBlocked(_ peer: String, at now: Date = .now) -> Bool {
        (failures[peer] ?? []).filter { now.timeIntervalSince($0) < window }.count >= limit
    }

    private mutating func prune(_ now: Date) {
        for (peer, dates) in failures {
            let recent = dates.filter { now.timeIntervalSince($0) < window }
            failures[peer] = recent.isEmpty ? nil : recent
        }
    }
}
