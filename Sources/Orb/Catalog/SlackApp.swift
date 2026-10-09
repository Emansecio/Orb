import Foundation

/// The Slack app the person creates for the Orb. Slack's official MCP server (`mcp.slack.com/mcp`) only answers apps that
/// are registered: published in the Marketplace, or internal to one workspace. The Orb has no server to be the first, so the
/// person creates an internal app in one click, from a manifest that already holds everything: MCP turned on, the scopes of
/// a user token in one of two sizes, and PKCE with the redirect the Orb signs in with (`MCPAuth`: the person gives the app's Client ID
/// and signs in in the browser, with nothing to copy). The User OAuth Token (`xoxp-…`) the app also shows can be pasted instead,
/// and goes in the Keychain like any other connector secret.
enum SlackApp {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case readOnly, readAndSend

        var id: String { rawValue }

        var label: String {
            switch self {
            case .readOnly: "Só leitura"
            case .readAndSend: "Leitura e envio"
            }
        }

        var detail: String {
            switch self {
            case .readOnly: "O Orb busca e lê mensagens, canais, arquivos e canvases. Não escreve nada."
            case .readAndSend: "Além de ler, o Orb pode enviar mensagens, reagir e editar canvases e listas. Enviar sempre pergunta antes."
            }
        }
    }

    static let readScopes = [
        "search:read.public", "search:read.private", "search:read.im", "search:read.mpim", "search:read.files", "search:read.users",
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "users:read", "users:read.email", "files:read", "reactions:read", "canvases:read", "lists:read", "emoji:read",
    ]
    static let writeScopes = ["chat:write", "reactions:write", "canvases:write", "lists:write", "files:write"]

    /// The user-token scopes of a preset.
    static func scopes(_ preset: Preset) -> [String] { preset == .readOnly ? readScopes : readScopes + writeScopes }

    /// Where Slack sends the person back after the login in the browser. A loopback address on a fixed
    /// port: Slack compares the redirect exactly, port included, and with PKCE it allows plain `http://localhost`.
    static let redirectURL = "http://localhost:47821/slack/callback"

    static let serverURL = "https://mcp.slack.com/mcp"
    static let appsURL = URL(string: "https://api.slack.com/apps")!

    /// The manifest, as Slack's reference describes it (`display_information`, `oauth_config`, `settings`).
    static func manifest(_ preset: Preset) -> JSONValue {
        .object([
            "display_information": .object([
                "name": .string("Orb"),
                "description": .string("O Orb lê e escreve no Slack por você, com as suas permissões."),
                "background_color": .string("#111111"),
            ]),
            "oauth_config": .object([
                "redirect_urls": .array([.string(redirectURL)]),
                "scopes": .object(["user": .array(scopes(preset).map(JSONValue.string))]),
                "pkce_enabled": .bool(true),
            ]),
            "settings": .object([
                "org_deploy_enabled": .bool(false),
                "socket_mode_enabled": .bool(false),
                "token_rotation_enabled": .bool(false),
                "is_mcp_enabled": .bool(true),
            ]),
        ])
    }

    /// `api.slack.com/apps?new_app=1&manifest_json=…`: Slack's link that opens "create an app" with the manifest filled in.
    static func creationURL(_ preset: Preset) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = manifest(preset).jsonString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://api.slack.com/apps?new_app=1&manifest_json=\(encoded)") ?? appsURL
    }

    /// A User OAuth Token. The bot tokens (`xoxb-`) cannot use the MCP server, and `xoxp-` is what the guide asks for.
    static func looksLikeUserToken(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.hasPrefix("xoxp-") && token.count > 12 && !token.contains(" ")
    }
}
