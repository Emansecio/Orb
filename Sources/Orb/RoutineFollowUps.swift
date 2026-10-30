import Foundation

/// A routine's working list is separate from its bounded run history.
struct RoutineFollowUpTool: AgentTool {
    let spec = ToolSpec(name: "routine_follow_up", description: "Maintain this routine's persistent follow-ups. List first; save new items with subject, channel and next_step; update or resolve existing items by id. Never infer that a missing item is resolved.",
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
        if action == "list" {
            let open = routines[index].followUps.filter { !$0.resolved }
            return open.isEmpty ? "Nenhum acompanhamento aberto." : open.map {
                "\($0.id.uuidString) | \($0.subject) | \($0.channel) | \($0.nextStep)"
                    + ($0.lastAction.map { " | Última ação: " + $0 } ?? "")
                    + ($0.source.map { " | Fonte: " + $0 } ?? "")
                    + ($0.lastChecked.map { " | Verificado: " + $0.formatted(.iso8601) } ?? "")
            }.joined(separator: "\n")
        }
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
            routines[index].followUps.append(item)
            return "Acompanhamento salvo: \(item.id.uuidString)."
        }
        guard action == "update" || action == "resolve", let id = field("id").flatMap(UUID.init(uuidString:)),
              let item = routines[index].followUps.firstIndex(where: { $0.id == id }) else {
            throw ToolError("Informe action e o id de um acompanhamento existente.")
        }
        if let subject = field("subject") { routines[index].followUps[item].subject = subject }
        if let channel = field("channel") { routines[index].followUps[item].channel = channel }
        if let next = field("next_step") { routines[index].followUps[item].nextStep = next }
        if let action = field("last_action") { routines[index].followUps[item].lastAction = action }
        if let source = field("source") { routines[index].followUps[item].source = source }
        if arguments.flag("checked") { routines[index].followUps[item].lastChecked = .now }
        routines[index].followUps[item].resolved = action == "resolve"
        routines[index].followUps[item].updatedAt = .now
        return action == "resolve" ? "Acompanhamento concluído." : "Acompanhamento atualizado."
    }
}
