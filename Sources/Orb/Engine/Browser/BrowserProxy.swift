import Foundation

/// The proxy an Orb sends its browser through (`browse_proxy`). The Orb picks it, the app only passes it on (`AGENT_BROWSER_PROXY`) and shows it:
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

    // MARK: The password, in the Keychain

    /// The Keychain account of the password of an Orb's proxy (`SecretVault`): the Orb's file keeps the address without it.
    static func keychainAccount(botID: UUID) -> String { "browser.proxy.\(botID.uuidString)" }

    /// The proxy as the Orb's file keeps it (`scheme://[user@]host:port`) and its password (percent-encoded, as it was given), if
    /// it has one.
    static func split(_ proxy: String) -> (address: String, password: String?) {
        guard var components = URLComponents(string: proxy), let password = components.percentEncodedPassword, !password.isEmpty else {
            return (proxy, nil)
        }
        components.percentEncodedPassword = nil
        return (components.string ?? display(proxy), password)
    }

    /// The address the Orb's file keeps with the password from the Keychain put back, as the browser takes it.
    static func joined(_ address: String, password: String?) -> String {
        guard let password, !password.isEmpty, var components = URLComponents(string: address),
              components.percentEncodedUser?.isEmpty == false, components.percentEncodedPassword == nil else { return address }
        components.percentEncodedPassword = password
        return components.string ?? address
    }

    /// Whether the address names a user, the only kind whose password may be in the Keychain.
    static func hasUser(_ proxy: String?) -> Bool {
        guard let proxy else { return false }
        return URLComponents(string: proxy)?.percentEncodedUser?.isEmpty == false
    }

    /// `text` with the password of `proxy` hidden: for the browser's own words, which may quote the address it was given.
    static func redacting(_ text: String, proxy: String?) -> String {
        guard let proxy, let password = split(proxy).password else { return text }
        var result = text.replacingOccurrences(of: proxy, with: display(proxy))
        // A very short password would turn every such letter of the message into dots; the whole address is already hidden.
        for form in Set([password, password.removingPercentEncoding ?? password]) where form.count >= 3 {
            result = result.replacingOccurrences(of: form, with: "•••")
        }
        return result
    }

    /// The text of an IP-check page as an address, or nil when it is anything else (an error page, a block).
    static func address(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count <= 45, !candidate.isEmpty, candidate.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }),
              candidate.contains(".") || candidate.contains(":") else { return nil }
        return candidate
    }
}
