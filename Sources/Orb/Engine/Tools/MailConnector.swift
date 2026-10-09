import Foundation

// Gmail as a local connector, through the Mail app. The person adds the Google account in Ajustes do Sistema → Contas de
// Internet (Apple does the login, so the Orb needs no Google review), Mail keeps the mailbox in sync and the Orb talks to
// Mail with AppleScript, the way its `applescript` tool already does. What Mail cannot do is said in the tool descriptions:
// no Gmail search operators, labels show up as mailboxes, and a message Mail has not downloaded cannot be read.

/// Mail, as far as the connector needs it. The app runs AppleScript; tests answer with canned text.
protocol MailBackend: Sendable {
    /// Whether macOS lets the Orb control Mail. Never asks.
    func automation() async -> MacPermissionStatus
    /// Opens Mail (hidden) if it is closed and lets macOS show its permission dialog.
    func requestAutomation() async -> MacPermissionStatus
    func run(_ script: String) async throws -> String
}

struct LiveMailBackend: MailBackend {
    var checker = MacPermissionChecker.live

    private static let mail = AutomationTarget(name: "Mail", bundleID: "com.apple.mail")

    func automation() async -> MacPermissionStatus { await checker.status(ofInBackground: .automation(Self.mail)) }

    func requestAutomation() async -> MacPermissionStatus {
        _ = await Blocking.run(fallback: false, timeout: .seconds(15)) { checker.system.launchHidden(bundleID: Self.mail.bundleID) }
        return await checker.requestInBackground(.automation(Self.mail))
    }

    func run(_ script: String) async throws -> String {
        try await AppleScript.run(script, timeout: .seconds(90), outputLimit: 200_000)
    }
}

/// A Mail account, as the accounts script reports it.
struct MailAccount: Sendable, Equatable {
    var id: String
    var name: String
    var host: String
    var address: String

    /// Whether Mail reaches this account through Google (Gmail's servers, or a Gmail address).
    var isGoogle: Bool {
        let host = host.lowercased(), address = address.lowercased()
        return host.contains("gmail.com") || host.contains("google.com") || host.contains("googlemail.com")
            || address.hasSuffix("@gmail.com") || address.hasSuffix("@googlemail.com")
    }

    /// How the person and the model refer to it: the address, or the name Mail gives it.
    var label: String { address.isEmpty ? name : address }
}

// MARK: - AppleScript

/// The scripts, as text, and the way their answers are read. Every value that comes from the model is put in a quoted
/// literal (`quoted`), never pasted as code; the answers use two control characters as separators (records and fields), which
/// no mail text holds.
enum MailScripts {
    static let record: Character = "\u{1E}"
    static let field: Character = "\u{1F}"

    /// `text` as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Statements that put `date` in `name`, field by field: a date written as text depends on the Mac's language.
    static func dateStatements(_ name: String, _ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return """
        set \(name) to current date
        set day of \(name) to 1
        set year of \(name) to \(parts.year ?? 2000)
        set month of \(name) to \(parts.month ?? 1)
        set day of \(name) to \(parts.day ?? 1)
        set hours of \(name) to \(parts.hour ?? 0)
        set minutes of \(name) to \(parts.minute ?? 0)
        set seconds of \(name) to \(parts.second ?? 0)
        """
    }

    private static let separators = """
    set RS to character id 30
    set US to character id 31
    """

    static let accounts = """
    tell application "Mail"
    \(separators)
    set out to ""
    repeat with a in accounts
    set host to ""
    set address to ""
    try
    set host to server name of a
    end try
    try
    set address to item 1 of (email addresses of a)
    end try
    set out to out & (id of a) & US & (name of a) & US & host & US & address & RS
    end repeat
    return out
    end tell
    """

    /// The mailboxes of one account, and the ones inside them (Gmail keeps its labels under "[Gmail]").
    static func mailboxes(accountID: String) -> String {
        """
        tell application "Mail"
        \(separators)
        set acc to first account whose id is \(quoted(accountID))
        set out to ""
        repeat with m in mailboxes of acc
        set out to out & (name of m) & US & (unread count of m) & RS
        try
        repeat with c in mailboxes of m
        set out to out & (name of m) & "/" & (name of c) & US & (unread count of c) & RS
        end repeat
        end try
        end repeat
        return out
        end tell
        """
    }

    /// The newest first is not promised by Mail, so up to `fetch` matches are read and the caller sorts and cuts them.
    static func search(accountID: String, mailbox: String, since: Date, until: Date?, query: String?, unreadOnly: Bool, fetch: Int) -> String {
        var conditions = ["date received ≥ sinceDate"]
        if until != nil { conditions.append("date received ≤ untilDate") }
        if let query { conditions.append("(subject contains \(quoted(query)) or sender contains \(quoted(query)))") }
        if unreadOnly { conditions.append("read status is false") }
        return """
        tell application "Mail"
        \(separators)
        \(dateStatements("sinceDate", since))
        \(until.map { dateStatements("untilDate", $0) } ?? "")
        set acc to first account whose id is \(quoted(accountID))
        set mb to mailbox \(quoted(mailbox)) of acc
        set found to (every message of mb whose \(conditions.joined(separator: " and ")))
        set total to count of found
        set upTo to total
        if upTo > \(fetch) then set upTo to \(fetch)
        set out to ""
        repeat with i from 1 to upTo
        set m to item i of found
        set out to out & (id of m as string) & US & ((date received of m) as «class isot» as string) & US & (sender of m) & US & (subject of m) & US & (read status of m as string) & RS
        end repeat
        return (total as string) & RS & out
        end tell
        """
    }

    static func read(accountID: String, mailbox: String, messageID: Int, characters: Int) -> String {
        """
        tell application "Mail"
        \(separators)
        set acc to first account whose id is \(quoted(accountID))
        set mb to mailbox \(quoted(mailbox)) of acc
        set m to (first message of mb whose id is \(messageID))
        set body to content of m
        if (length of body) > \(characters) then set body to (text 1 thru \(characters) of body)
        set tos to ""
        repeat with r in to recipients of m
        set tos to tos & (address of r) & ", "
        end repeat
        set ccs to ""
        repeat with r in cc recipients of m
        set ccs to ccs & (address of r) & ", "
        end repeat
        set files to ""
        repeat with f in mail attachments of m
        set files to files & (name of f) & ", "
        end repeat
        return (subject of m) & US & (sender of m) & US & tos & US & ccs & US & ((date received of m) as «class isot» as string) & US & files & US & body
        end tell
        """
    }

    /// A new message, saved as a draft or sent. `from` is the address of the account to write from.
    static func compose(from: String, to: [String], cc: [String], subject: String, body: String, send: Bool) -> String {
        let recipients = (to.map { ("to recipient", $0) } + cc.map { ("cc recipient", $0) })
            .map { "make new \($0.0) at end of \($0.0)s with properties {address:\(quoted($0.1))}" }
            .joined(separator: "\n")
        return """
        tell application "Mail"
        set msg to make new outgoing message with properties {subject:\(quoted(subject)), content:\(quoted(body)), visible:false}
        set sender of msg to \(quoted(from))
        tell msg
        \(recipients)
        end tell
        \(send ? "send msg" : "save msg")
        return "ok"
        end tell
        """
    }

    static func rows(_ output: String) -> [[String]] {
        output.split(separator: record, omittingEmptySubsequences: true)
            .map { $0.split(separator: field, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
}

// MARK: - Gmail

struct GmailConnector: LocalConnector {
    let backend: any MailBackend

    static let longestBody = 12_000
    static let defaultMailbox = "INBOX"

    var tools: [LocalTool] {
        let account = "Mail account (address) when there is more than one Google account."
        return [
            .reading("list_mailboxes", "Lists the Google accounts in Mail and their mailboxes (Gmail labels show up as mailboxes, like \"[Gmail]/All Mail\").",
                     .schema(["account": .property("string", account)])),
            .reading("search_messages", "Finds messages in one mailbox of a Google account by period and text (subject or sender; Gmail search operators do not work). Newest first. Returns id, date, sender, subject.",
                     .schema(["account": .property("string", account), "mailbox": .property("string", "Default INBOX."),
                              "since": .property("string", "ISO 8601 date. Default: 7 days ago."), "until": .property("string", "End of the period, same format; a date with no time includes that whole day."),
                              "query": .property("string", "Text in the subject or the sender."), "unread_only": .property("boolean"),
                              "limit": .property("integer", "Default 20, at most 50.")])),
            .reading("read_message", "Reads one message (text, at most about 12,000 characters) with its recipients and attachment names.",
                     .schema(["account": .property("string", account), "mailbox": .property("string", "The mailbox the search listed it in."),
                              "id": .property("integer", "The id from search_messages.")], required: ["mailbox", "id"])),
            .writing("create_draft", "Saves a draft in the Drafts mailbox of a Google account. Nothing is sent.",
                     .schema(Self.composition(account), required: ["to", "subject", "body"])),
            .writing("send_message", "Sends an email from a Google account.", .schema(Self.composition(account), required: ["to", "subject", "body"])),
        ]
    }

    private static func composition(_ account: String) -> [String: JSONValue] {
        ["account": .property("string", account), "to": .object(["type": .string("array"), "items": .property("string")]),
         "cc": .object(["type": .string("array"), "items": .property("string")]), "subject": .property("string"), "body": .property("string")]
    }

    func call(_ name: String, arguments: JSONValue) async throws -> String {
        switch name {
        case "list_mailboxes":
            var lines: [String] = []
            for account in try await googleAccounts(named: arguments.nonEmptyString("account"), all: true) {
                lines.append("Conta: \(account.label)")
                for row in MailScripts.rows(try await backend.run(MailScripts.mailboxes(accountID: account.id))) where !row[0].isEmpty {
                    lines.append("  \(row[0])" + (row.count > 1 && row[1] != "0" ? " (\(row[1]) não lidas)" : ""))
                }
            }
            return lines.joined(separator: "\n")
        case "search_messages":
            return try await search(arguments)
        case "read_message":
            return try await read(arguments)
        case "create_draft":
            return try await compose(arguments, send: false)
        case "send_message":
            return try await compose(arguments, send: true)
        default:
            throw ToolError("Ferramenta desconhecida: \(name).")
        }
    }

    // MARK: Accounts

    /// The Google accounts in Mail, or the one named. Throws what to do when there is none or the choice is open.
    func googleAccounts(named name: String?, all: Bool = false) async throws -> [MailAccount] {
        let accounts = MailScripts.rows(try await backend.run(MailScripts.accounts))
            .compactMap { row in row.count >= 4 ? MailAccount(id: row[0], name: row[1], host: row[2], address: row[3]) : nil }
            .filter(\.isGoogle)
        guard !accounts.isEmpty else {
            throw ToolError("O Mail não tem uma conta Google. Peça para a pessoa adicionar em Ajustes do Sistema → Contas de Internet → Google e marcar Mail.")
        }
        if let name {
            let wanted = name.lowercased()
            let found = accounts.filter { $0.address.lowercased() == wanted || $0.name.lowercased() == wanted || $0.id == name }
            guard !found.isEmpty else { throw ToolError("Não achei a conta \"\(name)\". As contas Google no Mail: \(accounts.map(\.label).joined(separator: ", ")).") }
            return found
        }
        if all || accounts.count == 1 { return accounts }
        throw ToolError("Há mais de uma conta Google no Mail (\(accounts.map(\.label).joined(separator: ", "))). Diga qual em \"account\".")
    }

    private func account(_ arguments: JSONValue) async throws -> MailAccount {
        try await googleAccounts(named: arguments.nonEmptyString("account"))[0]
    }

    // MARK: Messages

    private func search(_ arguments: JSONValue) async throws -> String {
        let account = try await account(arguments)
        let mailbox = arguments.nonEmptyString("mailbox") ?? Self.defaultMailbox
        let limit = arguments.integer("limit", default: 20, in: 1...50)
        let since = try LocalDates.optional(arguments, "since") ?? Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 24 * 3600))
        let until = try LocalDates.optionalEnd(arguments, "until")
        let script = MailScripts.search(accountID: account.id, mailbox: mailbox, since: since, until: until,
                                        query: arguments.nonEmptyString("query"), unreadOnly: arguments.flag("unread_only"), fetch: 200)
        var rows = MailScripts.rows(try await backend.run(script))
        // The first record is how many matched.
        let total = rows.first.flatMap { $0.count == 1 ? Int($0[0]) : nil } ?? 0
        if let first = rows.first, first.count == 1 { rows.removeFirst() }
        let messages = rows.compactMap { row -> (id: String, date: Date, line: String)? in
            guard row.count >= 5 else { return nil }
            let date = LocalDates.parse(row[1]) ?? .distantPast
            let unread = row[4] == "false" ? "[não lida] " : ""
            return (row[0], date, "\(unread)\(LocalDates.text(date)) — \(row[2]) — \(row[3].isEmpty ? "(sem assunto)" : row[3]) — id: \(row[0])")
        }
        .sorted { $0.date > $1.date }
        guard !messages.isEmpty else { return "Nenhuma mensagem em \(mailbox) de \(account.label) desde \(LocalDates.text(since))." }
        var text = messages.prefix(limit).map(\.line).joined(separator: "\n")
        text += "\n\nConta: \(account.label), caixa: \(mailbox)."
        if total > messages.count { text += " Havia \(total) mensagens no período; só as \(messages.count) primeiras foram lidas: estreite o período ou o texto." }
        return text + " Para ler uma, use read_message com a caixa e o id."
    }

    private func read(_ arguments: JSONValue) async throws -> String {
        let account = try await account(arguments)
        let id = arguments.integer("id", default: -1, in: -1...Int.max)
        guard id >= 0 else { throw ToolError("Faltou o argumento \"id\".") }
        let mailbox = try arguments.requiredString("mailbox")
        let output = try await backend.run(MailScripts.read(accountID: account.id, mailbox: mailbox, messageID: id, characters: Self.longestBody))
        let parts = output.split(separator: MailScripts.field, maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7 else { throw ToolError("O Mail respondeu algo que não deu para ler. Tente de novo.") }
        func clean(_ list: String) -> String { list.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        var lines = ["Assunto: \(parts[0])", "De: \(parts[1])", "Para: \(clean(parts[2]))"]
        if !clean(parts[3]).isEmpty { lines.append("Cc: \(clean(parts[3]))") }
        lines.append("Data: \(LocalDates.parse(parts[4]).map { LocalDates.text($0) } ?? parts[4])")
        if !clean(parts[5]).isEmpty { lines.append("Anexos: \(clean(parts[5]))") }
        return lines.joined(separator: "\n") + "\n\n" + parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compose(_ arguments: JSONValue, send: Bool) async throws -> String {
        let account = try await account(arguments)
        func addresses(_ key: String) -> [String] {
            let list = arguments[key]?.array?.compactMap(\.string) ?? arguments[key]?.string.map { [$0] } ?? []
            return list.flatMap { $0.split(whereSeparator: { ",;".contains($0) }) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let to = addresses("to"), cc = addresses("cc")
        guard !to.isEmpty else { throw ToolError("Faltou o argumento \"to\".") }
        for address in to + cc where !address.contains("@") { throw ToolError("\"\(address)\" não parece um endereço de e-mail.") }
        let subject = try arguments.requiredString("subject", allowEmpty: true), body = try arguments.requiredString("body", allowEmpty: true)
        _ = try await backend.run(MailScripts.compose(from: account.address.isEmpty ? account.name : account.address, to: to, cc: cc,
                                                      subject: subject, body: body, send: send))
        return send ? "E-mail enviado de \(account.label) para \(to.joined(separator: ", "))."
                    : "Rascunho salvo em \(account.label) para \(to.joined(separator: ", ")). Nada foi enviado."
    }
}
