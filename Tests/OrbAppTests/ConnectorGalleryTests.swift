import Foundation
import Testing
@testable import Orb

// The gallery of services, the Slack app the person creates, and Supabase: no real service, no login, no macOS permission.

struct ConnectorGalleryTests {
    @Test func theGalleryHoldsTheServicesPeopleAskFor() {
        let services = ConnectorGallery.services
        #expect(Set(services.map(\.id)).count == services.count)
        let names = services.map(\.name)
        for wanted in ["Gmail", "Google Agenda", "Slack", "Notion", "GitHub", "Supabase", "Linear", "Lembretes"] { #expect(names.contains(wanted), Comment(rawValue: wanted)) }
        for service in services {
            #expect(!service.summary.isEmpty && !service.how.isEmpty && service.mark.symbol != nil || !service.mark.monogram.isEmpty, Comment(rawValue: service.id))
            // A template card points at a template that is offered; every local connector has a card.
            if case .template(let id) = service.source { #expect(ConnectorTemplate.all.contains { $0.id == id }, Comment(rawValue: id)) }
        }
        #expect(Set(services.compactMap(\.localKind)) == Set(LocalConnectorKind.allCases))
        // Notion and Linear need a login the Orb does not do yet.
        #expect(services.filter { $0.source == .soon }.map(\.name) == ["Notion", "Linear"])
        // Nothing the gallery offers runs an abandoned package.
        #expect(!services.compactMap(\.template).contains { $0.config.arguments.joined().contains("server-slack") || $0.config.arguments.joined().contains("notion-mcp-server") })
        // Every template is on the page, so none is only reachable by a code path nobody can click.
        #expect(Set(ConnectorTemplate.all.map(\.id)) == Set(services.compactMap { $0.template?.id }))
    }

    @Test func aCardSaysWhereTheServiceStands() throws {
        func service(_ id: String) -> ConnectorService { ConnectorGallery.services.first { $0.id == id }! }
        let github = ConnectorTemplate.all.first { $0.id == "github" }!.config.withNewID()
        var gmail = LocalConnectorKind.gmail.config
        func status(_ id: String, _ connectors: [MCPServerConfig], _ statuses: [UUID: MCPStatus] = [:], local: [LocalConnectorKind: LocalConnectorState] = [:]) -> ServiceStatus {
            ConnectorGallery.status(of: service(id), connectors: connectors, statuses: statuses, local: local)
        }
        #expect(status("github", []) == .available && status("gmail", []) == .available)
        #expect(status("notion", []) == .soon)
        #expect(status("github", [github]) == .connected)
        #expect(status("github", [github], [github.id: .ready(toolCount: 3)]) == .connected)
        guard case .needsAttention(let why) = status("github", [github], [github.id: .failed("Não foi possível conectar ao conector GitHub: HTTP 401: Bad credentials")]) else {
            Issue.record("expected attention"); return
        }
        #expect(why == "HTTP 401: Bad credentials")
        // A connector of this Mac asks for attention when macOS or the account is missing, and not when Mail is only closed.
        #expect(status("gmail", [gmail], local: [.gmail: .ready]) == .connected)
        #expect(status("gmail", [gmail], local: [.gmail: .unchecked]) == .connected)
        #expect(status("gmail", [gmail]) == .connected)
        #expect(status("gmail", [gmail], local: [.gmail: .noAccount]) == .needsAttention(LocalConnectorState.noAccount.message))
        #expect(status("agenda", [LocalConnectorKind.agenda.config], local: [.agenda: .denied]) == .needsAttention(LocalConnectorState.denied.message))
        gmail.isEnabled = false
        #expect(status("gmail", [gmail]) == .off)
        // The connector is found by what it is, not by its name.
        var renamed = github
        renamed.name = "Meu GitHub"
        #expect(ConnectorGallery.installed(service("github"), in: [renamed])?.id == github.id)
    }

    @Test func theOldSlackIsNotTheNewSlack() throws {
        let old = ConnectorTemplate.retired.first { $0.id == "slack" }!.config.withNewID()
        let gallerySlack = ConnectorGallery.services.first { $0.id == "slack" }!
        // The Slack installed from the archived package keeps working and does not make the gallery's Slack look connected.
        #expect(ConnectorGallery.installed(gallerySlack, in: [old]) == nil)
        #expect(ConnectorGallery.status(of: gallerySlack, connectors: [old], statuses: [:], local: [:]) == .available)
        #expect(ConnectorTemplate.matching(old)?.id == "slack")
    }

    @Test func slackAndSupabaseAreTheOfficialServers() throws {
        let slack = try #require(ConnectorTemplate.all.first { $0.id == "slack-oficial" })
        #expect(slack.config.url == "https://mcp.slack.com/mcp" && slack.isRemote && slack.guide == .slack)
        #expect(slack.config.secretKeys == ["Authorization"] && slack.inputs.first?.prefix == "Bearer " && slack.needsKey)
        let supabase = try #require(ConnectorTemplate.all.first { $0.id == "supabase" })
        #expect(supabase.config.url == "https://mcp.supabase.com/mcp?read_only=true")
        #expect(supabase.config.secretKeys == ["Authorization"] && supabase.inputs.first?.prefix == "Bearer ")
        #expect(supabase.note?.contains("read_only") == true && supabase.helpURL?.host == "supabase.com")
        // Taking the read-only query out of the URL does not make the connector a stranger to its guided form.
        var edited = supabase.config.withNewID()
        edited.url = "https://mcp.supabase.com/mcp"
        #expect(ConnectorTemplate.matching(edited)?.id == "supabase")
        #expect(ConnectorDraft(editing: edited).isGuided && ConnectorDraft(editing: edited).note != nil)
        #expect(ConnectorDraft(template: slack).guide == .slack && ConnectorDraft(template: supabase).guide == nil)
        // The token the editor sends is a Bearer header, and both stay in the Keychain.
        #expect(ConnectorSecrets.secretNames(of: slack.config) == ["Authorization"])
    }

    @Test func theServicesThatNeedALoginAreNotInstallable() {
        // The next batch brings the login; until then the card is "Em breve" and no template stands behind it.
        let soon = ConnectorGallery.services.filter { $0.source == .soon }
        #expect(soon.allSatisfy { $0.template == nil && $0.localKind == nil && $0.summary.contains("em breve") })
    }
}

struct SlackAppTests {
    private func decodedManifest(_ preset: SlackApp.Preset) throws -> JSONValue {
        let url = SlackApp.creationURL(preset)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "api.slack.com" && components.path == "/apps")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["new_app"] == "1")
        let text = try #require(items["manifest_json"])
        return try #require(JSONValue.parse(text))
    }

    @Test func theLinkCarriesTheManifestWithMCPUserScopesAndPKCE() throws {
        for preset in SlackApp.Preset.allCases {
            let manifest = try decodedManifest(preset)
            #expect(manifest == SlackApp.manifest(preset))
            #expect(manifest["settings"]?["is_mcp_enabled"]?.bool == true)
            #expect(manifest["settings"]?["socket_mode_enabled"]?.bool == false && manifest["settings"]?["org_deploy_enabled"]?.bool == false)
            #expect(manifest["oauth_config"]?["pkce_enabled"]?.bool == true)
            #expect(manifest["oauth_config"]?["redirect_urls"]?.array?.compactMap(\.string) == [SlackApp.redirectURL])
            #expect(manifest["oauth_config"]?["scopes"]?["user"]?.array?.compactMap(\.string) == SlackApp.scopes(preset))
            // Only user scopes: the MCP server takes the token of a person, and a bot would see only where it was invited.
            #expect(manifest["oauth_config"]?["scopes"]?["bot"] == nil)
            // Slack's limits on the display information.
            #expect((manifest["display_information"]?["name"]?.string?.count ?? 99) <= 35)
            #expect((manifest["display_information"]?["description"]?.string?.count ?? 999) <= 140)
        }
        #expect(SlackApp.redirectURL.hasPrefix("http://localhost:"))
    }

    @Test func theTwoPresetsDifferOnlyByWriting() throws {
        let read = Set(SlackApp.scopes(.readOnly)), all = Set(SlackApp.scopes(.readAndSend))
        #expect(read.isSubset(of: all) && !read.contains { $0.hasSuffix(":write") } && all.subtracting(read) == Set(SlackApp.writeScopes))
        #expect(all.contains("chat:write") && !read.contains("chat:write"))
        for scope in ["search:read.public", "channels:history", "im:history", "users:read"] { #expect(read.contains(scope), Comment(rawValue: scope)) }
        // Nothing that creates channels or conversations, nothing of a bot.
        #expect(!all.contains { $0 == "channels:write" || $0 == "groups:write" || $0 == "im:write" || $0 == "mpim:write" })
        #expect(SlackApp.Preset.allCases.map(\.label) == ["Só leitura", "Leitura e envio"])
    }

    @Test func theLinkIsSafeInAURL() {
        let text = SlackApp.creationURL(.readAndSend).absoluteString
        #expect(text.hasPrefix("https://api.slack.com/apps?new_app=1&manifest_json=%7B"))
        // Nothing of the manifest can end the query early.
        let query = text.dropFirst("https://api.slack.com/apps?new_app=1&manifest_json=".count)
        #expect(!query.contains { "&?# {}\"".contains($0) })
    }

    @Test func onlyAUserTokenCounts() {
        #expect(SlackApp.looksLikeUserToken("xoxp-1234567890-abcdef"))
        #expect(SlackApp.looksLikeUserToken("  xoxp-1234567890-abcdef\n"))
        #expect(!SlackApp.looksLikeUserToken("xoxb-1234567890-abcdef") && !SlackApp.looksLikeUserToken("xoxp-") && !SlackApp.looksLikeUserToken(""))
        #expect(!SlackApp.looksLikeUserToken("Bearer xoxp-1234567890-abcdef"))
    }
}

@MainActor
struct LocalConnectorInstallTests {
    private func model(_ fake: LocalConnectorEnvironment? = nil) -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "OrbGallery-\(UUID().uuidString)")
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        if let fake { model.localEnvironment = fake }
        return (model, root)
    }

    @Test func installingAddsTheConnectorForTheChosenOrbsAndTurnsConnectorsOn() throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let orb = try #require(model.bots.first)
        model.bots[0].capabilities.remove(.connectors)
        let config = model.installLocalConnector(.agenda, orbIDs: [orb.id])
        #expect(model.connectors.contains { $0.id == config.id } && config.local == "agenda" && config.orbIDs == [orb.id])
        #expect(model.bots[0].capabilities.contains(.connectors))
        #expect(model.installedLocalConnector(.agenda)?.id == config.id && model.installedLocalConnector(.gmail) == nil)
        // Again: the same connector, with another scope; nothing is added twice.
        let again = model.installLocalConnector(.agenda, orbIDs: nil)
        #expect(again.id == config.id && again.orbIDs == nil && model.connectors.filter { $0.local == "agenda" }.count == 1)
    }

    @Test func theCardsStatesComeFromTheEnvironmentAndNeverAsk() async {
        let calendar = FakeCalendar(), mail = FakeMail()
        calendar.calendarList = [CalendarInfo(id: "i", title: "Casa", account: "iCloud", isWritable: true)]
        mail.permission = .notDetermined
        let (model, root) = model(LocalConnectorEnvironment(calendar: calendar, mail: mail))
        defer { try? FileManager.default.removeItem(at: root) }
        model.installLocalConnector(.agenda, orbIDs: nil)
        model.installLocalConnector(.gmail, orbIDs: nil)
        await model.refreshLocalStates()
        #expect(model.localStates == [.agenda: .noAccount, .gmail: .needsPermission])
        #expect(calendar.requests.isEmpty && mail.requestCount == 0)
        // A connector that is not installed is not looked at.
        #expect(model.localStates[.lembretes] == nil)
        // The click is what asks: yes this time, and the gallery's card follows.
        calendar.calendarList.append(CalendarInfo(id: "g", title: "Trabalho", account: "Google", isWritable: true))
        await model.refreshLocalStates()
        #expect(model.localStates[.agenda] == .ready)
        let agenda = ConnectorGallery.services.first { $0.id == "agenda" }!
        #expect(ConnectorGallery.status(of: agenda, connectors: model.connectors, statuses: [:], local: model.localStates) == .connected)
    }

    /// A Workspace calendar is named by its address: "Conectar assim mesmo" is remembered, so the card is not stuck on "Resolver".
    @Test func theChoiceToConnectAnywayIsKeptAndSurvivesTheDataFile() async throws {
        let calendar = FakeCalendar()
        calendar.calendarList = [CalendarInfo(id: "w", title: "Trabalho", account: "maria@empresa.com.br", isWritable: true)]
        let (model, root) = model(LocalConnectorEnvironment(calendar: calendar, mail: FakeMail()))
        defer { try? FileManager.default.removeItem(at: root) }
        model.installLocalConnector(.agenda, orbIDs: nil)
        await model.refreshLocalStates()
        #expect(model.localStates[.agenda] == .noAccount)
        let config = model.installLocalConnector(.agenda, orbIDs: nil, anyAccount: true)
        #expect(config.anyAccount && model.connectors.filter { $0.local == "agenda" }.count == 1)
        await model.refreshLocalStates()
        #expect(model.localStates[.agenda] == .ready)
        // Installing again without the choice does not take it back.
        #expect(model.installLocalConnector(.agenda, orbIDs: nil).anyAccount)
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(config)).anyAccount)
        #expect(try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"x"}"#.utf8)).anyAccount == false)
    }

    @Test func aLocalConnectorStartsThroughTheModelWithTheFakeEnvironment() async throws {
        let calendar = FakeCalendar()
        let (model, root) = model(LocalConnectorEnvironment(calendar: calendar, mail: FakeMail()))
        defer { try? FileManager.default.removeItem(at: root) }
        let config = model.installLocalConnector(.agenda, orbIDs: nil)
        #expect(await model.connectAndWait(config.id) == .ready(toolCount: 6))
        let catalog = try #require(await model.mcp.catalog(config.id))
        #expect(catalog.tools.contains { $0.name == "delete_event" && $0.annotations.destructive == true })
        // The catalog is what the Claude Code turn judges by, with no server started for it.
        let names = ClaudeCodeTurn.mcpNames([config])
        let found = await model.connectorAnnotations(for: [config.id], cliNames: names)
        #expect(found.destructive.keys.contains("google_agenda__delete_event") || found.destructive.keys.contains("google-agenda__delete_event")
                || found.destructive.keys.contains { $0.hasSuffix("__delete_event") })
        #expect(found.known.contains { $0.hasSuffix("__search_events") })
    }
}
