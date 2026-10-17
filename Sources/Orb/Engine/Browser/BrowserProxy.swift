import Foundation

/// The proxy an Orb sends its browser through (`browse_proxy`). The Orb picks it, the app only passes it on (`--proxy`) and shows it:
/// it does not start or manage tunnels (a WireGuard or VPN client that listens on `socks5://127.0.0.1:1080` is the Orb's own business).
enum BrowserProxy {
    static let schemes: Set<String> = ["http", "https", "socks4", "socks5", "socks5h"]
    /// Where the address a page sees comes from, to prove the proxy took effect.
    static let ipCheckURL = "https://api.ipify.org/"

    /// The proxy as the browser takes it (`scheme://[user:password@]host:port`), or why it is not one.
    static func normalized(_ text: String) -> Result<String, ToolError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return .failure(ToolError("`proxy` is an address like socks5://127.0.0.1:1080 or http://host:8080, with no spaces."))
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              let host = components.host, !host.isEmpty, let port = components.port, (1...65_535).contains(port),
              components.path.isEmpty || components.path == "/", components.query == nil, components.fragment == nil else {
            return .failure(ToolError("`proxy` is an address like socks5://127.0.0.1:1080 or http://host:8080 "
                                      + "(scheme http, https, socks4 or socks5; a host; a port)."))
        }
        var rebuilt = "\(scheme)://"
        if let user = components.percentEncodedUser, !user.isEmpty {
            rebuilt += user + (components.percentEncodedPassword.map { ":" + $0 } ?? "") + "@"
        }
        rebuilt += (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        return .success(rebuilt)
    }

    /// The proxy without its password, for the screen and the conversation.
    static func display(_ proxy: String) -> String {
        proxy.replacingOccurrences(of: #"(://[^:/@]+):[^@]*@"#, with: "$1:•••@", options: .regularExpression)
    }

    /// The text of an IP-check page as an address, or nil when it is anything else (an error page, a block).
    static func address(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count <= 45, !candidate.isEmpty, candidate.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }),
              candidate.contains(".") || candidate.contains(":") else { return nil }
        return candidate
    }
}
