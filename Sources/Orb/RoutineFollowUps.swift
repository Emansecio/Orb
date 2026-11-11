import Foundation

/// A routine's working list is separate from its bounded run history.
struct RoutineFollowUpTool: AgentTool {
    let spec = ToolSpec(name: "routine_follow_up", description: "Maintain this routine's persistent follow-ups. List first; save new items with subject, channel and next_step; update or resolve existing items by id, or by the same channel or subject. One open item per contact (phone or e-mail in channel): saving another updates it. Resolve what is finished, and what waits on someone who went quiet (the list says for how long): it comes back if they write. Never infer that a missing item is resolved.",
                        parameters: .schema([
                            "action": .property("string", "list, save, update or resolve"),
                            "id": .property("string"), "subject": .property("string"),
                            "channel": .property("string"), "next_step": .property("string"),
                            "last_action": .property("string"), "source": .property("string"),
                            "checked": .property("boolean", "true only after checking the source in this run")
                        ], required: ["action"]))
    var kind: ToolCall.Kind { .plan }
    var capability: Capability? { nil }
    func risk(_ arguments: JSONValue) -> ToolRisk { .safe }
    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        ("Atualizando acompanhamentos", arguments["subject"]?.string ?? "")
    }
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let handler = context.followUps else { throw ToolError("Acompanhamentos indisponíveis nesta conversa.") }
        return try await handler(arguments)
    }
}

extension AppModel {
    func followUpHandler(routineID: UUID, botID: UUID) -> ScheduleHandler {
        { [weak self] arguments in
            guard let self else { throw ToolError("O app está fechando.") }
            return try await self.changeFollowUp(arguments, routineID: routineID, botID: botID)
        }
    }

    func changeFollowUp(_ arguments: JSONValue, routineID: UUID, botID: UUID) throws -> String {
        guard let index = routines.firstIndex(where: { $0.id == routineID && $0.botID == botID }),
              sessions[botID]?.routineID == routineID else { throw ToolError("Esta rotina não está em execução.") }
        let action = arguments["action"]?.string ?? ""
        // Two open items about one client are two states of it, and a run would act on either: the older ones go first.
        RoutineFollowUp.collapse(&routines[index].followUps)
        RoutineFollowUp.pruneResolved(&routines[index].followUps)
        if action == "list" { return RoutineFollowUp.list(routines[index].followUps) }
        func field(_ name: String) -> String? {
            let value = arguments[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : String(value.prefix(500))
        }
        if action == "save" {
            guard let subject = field("subject"), let channel = field("channel"), let next = field("next_step") else {
                throw ToolError("Informe subject, channel e next_step.")
            }
            var item = RoutineFollowUp(subject: subject, channel: channel, nextStep: next)
            item.lastAction = field("last_action")
            item.source = field("source")
            if arguments.flag("checked") { item.lastChecked = .now }
            let followUps = routines[index].followUps
            if let open = followUps.firstIndex(where: { !$0.resolved && $0.sameness == item.sameness }) {
                item.id = followUps[open].id
                item.lastAction = item.lastAction ?? followUps[open].lastAction
                item.source = item.source ?? followUps[open].source
                item.lastChecked = item.lastChecked ?? followUps[open].lastChecked
                routines[index].followUps[open] = item
                return "Este contato já tinha um acompanhamento aberto (\(item.id.uuidString)): atualizado, sem duplicar."
            }
            routines[index].followUps.append(item)
            var reply = "Acompanhamento salvo: \(item.id.uuidString)."
            if let contact = item.contact, let done = followUps.last(where: { $0.resolved && $0.contact == contact }) {
                reply += " Este contato já teve um acompanhamento concluído (\(RoutineReport.stamp(done.updatedAt))): \(done.subject)"
                    + " · \(done.lastAction ?? done.nextStep)"
            }
            return reply
        }
        // By id, else by what makes two items one (`sameness`): the id is only in the list, which shows part of a long
        // one, so an item could be saved again and again but not closed.
        let followUps = routines[index].followUps
        let subject = field("subject"), channel = field("channel")
        let probe = subject == nil && channel == nil ? nil
            : RoutineFollowUp(subject: subject ?? "", channel: channel ?? "", nextStep: "").sameness
        guard action == "update" || action == "resolve",
              let item = field("id").flatMap(UUID.init(uuidString:)).flatMap({ id in followUps.firstIndex { $0.id == id } })
                ?? followUps.firstIndex(where: { !$0.resolved && $0.sameness == probe }) else {
            throw ToolError("Informe action e o id, ou o mesmo channel ou subject, de um acompanhamento aberto.")
        }
        if let subject { routines[index].followUps[item].subject = subject }
        if let channel { routines[index].followUps[item].channel = channel }
        if let next = field("next_step") { routines[index].followUps[item].nextStep = next }
        if let action = field("last_action") { routines[index].followUps[item].lastAction = action }
        if let source = field("source") { routines[index].followUps[item].source = source }
        if arguments.flag("checked") { routines[index].followUps[item].lastChecked = .now }
        routines[index].followUps[item].resolved = action == "resolve"
        routines[index].followUps[item].updatedAt = .now
        RoutineFollowUp.collapse(&routines[index].followUps) // an update that made it another's twin, or reopened an old one
        return action == "resolve" ? "Acompanhamento concluído." : "Acompanhamento atualizado."
    }
}

extension RoutineFollowUp {
    /// What `list` hands the model, and how many resolved items a routine keeps: both grow with the routine's life otherwise.
    static let listLimit = 50
    static let resolvedKept = 200
    /// An open item nobody updated or checked for this long is quiet: the list says so, and asks for it to be closed or
    /// updated. Of a list longer than `listLimit`, this many of the quietest take the place of the last newest ones.
    static let quietAfter: TimeInterval = 7 * 86_400
    static let quietShown = 10

    /// When the item last moved: saved, updated or checked.
    var lastMoved: Date { max(updatedAt, lastChecked ?? .distantPast) }

    /// What `list` answers: the open items, newest first. A list longer than `listLimit` used to show only the newest, so
    /// the old ones were never seen again and never closed: now the quietest come along, and each one closed or updated
    /// makes room for the next.
    static func list(_ items: [RoutineFollowUp], now: Date = .now) -> String {
        let open = items.filter { !$0.resolved }.sorted { $0.updatedAt > $1.updatedAt }
        guard !open.isEmpty else { return "Nenhum acompanhamento aberto." }
        let quietest = open.dropFirst(listLimit).sorted { $0.lastMoved < $1.lastMoved }.prefix(quietShown)
        let shown = open.prefix(listLimit - quietest.count) + quietest
        let lines = shown.map { item in
            let quiet = now.timeIntervalSince(item.lastMoved)
            return "\(item.id.uuidString) | \(item.subject) | \(item.channel) | \(item.nextStep)"
                + (item.lastAction.map { " | Última ação: " + $0 } ?? "")
                + (item.source.map { " | Fonte: " + $0 } ?? "")
                + (item.lastChecked.map { " | Verificado: " + $0.formatted(.iso8601) } ?? "")
                + (quiet >= quietAfter ? " | Parado há \(Int(quiet / 86_400)) dias: conclua (resolve) ou atualize" : "")
        }
        let more = open.count - shown.count
        return lines.joined(separator: "\n") + (more > 0 ? "\n+\(more) abertos: aparecem conforme os parados acima forem concluídos ou atualizados" : "")
    }

    /// Drops the oldest resolved items beyond `resolvedKept`; open ones are never touched.
    static func pruneResolved(_ items: inout [RoutineFollowUp]) {
        let resolved = items.filter(\.resolved)
        guard resolved.count > resolvedKept else { return }
        let drop = Set(resolved.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(resolvedKept).map(\.id))
        items.removeAll { drop.contains($0.id) }
    }

    /// Who the item is about: the one phone number or e-mail of its channel ("WhatsApp 5511…"). Not its subject, where a
    /// batch names one lead among others ("Toques de 30/10 (gra, lead 5531…, Fabiana)"). nil when there is none, or more.
    var contact: String? {
        let contacts = Self.contacts(in: channel)
        return contacts.count == 1 ? contacts.first : nil
    }

    /// What makes two items one: their contact, or else the same subject.
    var sameness: String {
        contact ?? "subject:" + subject.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Open items that are one (`sameness`) become one: the one updated last stays open and the others are resolved, kept
    /// in the list as they were. Returns how many were resolved.
    @discardableResult
    static func collapse(_ items: inout [RoutineFollowUp]) -> Int {
        var newest: [String: Int] = [:]
        var resolved = 0
        for index in items.indices where !items[index].resolved {
            let key = items[index].sameness
            guard let kept = newest[key] else {
                newest[key] = index
                continue
            }
            let older = items[index].updatedAt > items[kept].updatedAt ? kept : index
            if older == kept { newest[key] = index }
            items[older].resolved = true
            resolved += 1
        }
        return resolved
    }

    /// Phone numbers and e-mails in `text`. A Brazilian number counts without its 55 and its ninth digit, as WhatsApp
    /// writes it either way; a WhatsApp address (`…@s.whatsapp.net`) is its number.
    static func contacts(in text: String) -> Set<String> {
        var found = Set<String>()
        for match in text.matches(of: /\+?\d[\d ().-]{8,}\d/) {
            let digits = match.output.filter(\.isNumber)
            if let phone = phone(String(digits)) { found.insert(phone) }
        }
        for match in text.matches(of: /[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/) {
            let address = match.output.0.lowercased()
            if !address.hasSuffix("whatsapp.net") { found.insert(address) }
        }
        return found
    }

    private static func phone(_ digits: String) -> String? {
        guard (10...15).contains(digits.count) else { return nil }
        var number = digits
        if number.count >= 12, number.hasPrefix("55") { number.removeFirst(2) }
        let ninth = number.index(number.startIndex, offsetBy: 2)
        if number.count == 11, number[ninth] == "9" { number.remove(at: ninth) }
        return number
    }
}
