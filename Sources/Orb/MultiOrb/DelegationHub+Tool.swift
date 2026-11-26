import Foundation

// Tool bridge (`orbs`, `group_create`, `group_edit`, `orb_delete`), UI projections (`OpenTalk`, `refresh`), and pulse lineage.
extension DelegationHub {
    // MARK: The tool

    /// One call of the `orbs` tool for `botID` (both engines end up here). `ask` returns at once: the answer wakes the Orb later.
    func handleTool(_ arguments: JSONValue, orb botID: UUID, messageID: UUID = UUID(), turn: UUID? = nil) async throws -> String {
        guard let model, model.bot(botID) != nil else { throw ToolError("Este Orb não existe mais.") }
        // A call still in flight when its turn was stopped would otherwise act with what the next turn left in the session (no
        // chain: a new one, outside the pulse's budget and the stop).
        if let turn, model.sessions[botID]?.turnID != turn { throw ToolError("Esta resposta foi interrompida: nada foi feito.") }
        let groupID = model.session(botID).chain?.groupID
        switch arguments["action"]?.string?.lowercased() {
        case "list":
            guard model.orbsCanTalk || groupID != nil else { throw DelegationRefusal.switchedOff.toolError }
            return teammatesText(for: botID, groupID: groupID)
        case "create_group":
            do { return try createGroup(arguments, by: botID) } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "edit_group_plan":
            // For the tool: what the user must confirm first (none when the edit needs nobody) and the ids it is about.
            do {
                let plan = try planGroupEdit(arguments, by: botID)
                return ConfirmedEdit.answer(confirmation: plan.confirmation, group: plan.group.id,
                                            orb: plan.confirmation == nil ? nil : plan.orb?.id)
            } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "edit_group_later":
            do { return try askGroupEditLater(arguments, by: botID) } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "edit_group":
            do { return try await editGroup(arguments, by: botID) } catch let refusal as DelegationRefusal { throw refusal.toolError }
        case "delete_orb_plan":
            // For the tool: the text of the user's card and the Orb it is about.
            let plan = try planOrbDelete(arguments, by: botID)
            return ConfirmedEdit.answer(confirmation: plan.confirmation, group: nil, orb: plan.orb.id)
        case "delete_orb_later":
            let plan = try planOrbDelete(arguments, by: botID)
            return model.askDeletionLater(.orb(plan.orb), by: botID, text: plan.confirmation)
        case "delete_orb":
            return try deleteOrb(arguments, by: botID)
        case "ask", "tell":
            let kind: OrbEnvelope.Kind = arguments["action"]?.string?.lowercased() == "tell" ? .tell : .ask
            let name = arguments["to"]?.string ?? "", text = arguments["message"]?.string ?? ""
            let artifacts = Self.parseArtifactPaths(arguments["files"])
            do {
                // Outside a group's turn, a group's name (that no Orb has) is a request to that group.
                // In a group's turn too, with "Orbs agem por conta própria" (an orchestrator asking another group).
                if groupID == nil || model.orbsActOnOwn, let group = group(named: name) {
                    let envelope = try submitToGroup(group, from: botID, text: text, kind: kind, messageID: messageID)
                    let ignoredFolder = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    return "Pedido enviado ao grupo \(group.name) (id \(envelope.shortID)): \(envelope.to.name) orquestra, o grupo "
                        + "trabalha no fio dele e a resposta final chega sozinha como mensagem; não espere nem repita o pedido. "
                        + "O usuário acompanha na tela do grupo."
                        + (ignoredFolder ? " Note: folder was ignored; a group works in its own project folder." : "")
                }
                // A project folder is for a plain request: a group's turns use the group's own (`OrbGroup.projectFolder`).
                var folder: String?
                if kind == .ask, groupID == nil, let path = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    folder = try AccessRequest.checkedFolder(path, home: model.homeFolder)
                }
                let envelope = try submit(from: botID, to: name, text: text, kind: kind, messageID: messageID, groupID: groupID,
                                          folder: folder, artifacts: artifacts)
                return kind == .ask
                    ? "Pedido enviado a \(envelope.to.name) (id \(envelope.shortID)). A resposta chega sozinha como mensagem"
                        + (envelope.servingRoutine != nil ? " e retoma esta execução da rotina"
                            : envelope.servingPulse != nil ? " e retoma este pulso" : "")
                        + "; não espere nem repita o pedido. Termine o que puder sem ela."
                    : "Aviso deixado para \(envelope.to.name): \(envelope.groupID == nil ? "ele lê na próxima mensagem que receber" : "fica no fio do grupo, que ele lê no próximo turno"). tell não acorda; para acordar e ter resposta, use ask."
            } catch let refusal as DelegationRefusal {
                throw refusal.toolError
            }
        default:
            throw ToolError("Use action list, ask ou tell.")
        }
    }

    static func parseArtifactPaths(_ value: JSONValue?) -> [String] {
        guard let items = value?.array else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            guard let raw = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let clean = OrbEnvelopeText.sanitize(raw).split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            result.append(clean)
            if result.count >= DelegationLimits.maxArtifacts { break }
        }
        return result
    }

    /// "- Pesquisador: Pesquisa na web e resume (livre)": the teammates, without ids or folders. Outside a group's turn, the
    /// groups the Orb is in come after them; in one, the other groups its orchestrator may ask.
    func teammatesText(for botID: UUID, groupID: UUID?) -> String {
        guard let model else { return "" }
        let team = roster(for: botID, groupID: groupID).compactMap { model.bot($0.id) }
        let listed = team.prefix(DelegationLimits.rosterLimit * 4)
        var teammates = team.isEmpty ? "Não há outros Orbs." : listed.map { orb in
            let role = MemoryText.clip(MemoryText.flatten(orb.role), DelegationLimits.roleClip)
            let state = groupID.map { groupStatus(of: orb.id, in: $0) } ?? status(of: orb.id)
            return "- \(orb.name)\(role.isEmpty ? "" : ": " + role) (\(state))"
        }.joined(separator: "\n")
        if team.count > listed.count { teammates += "\n- e mais \(team.count - listed.count) Orbs (não listados)" }
        let lines = groupID == nil ? model.groupLines(for: botID) : model.otherGroupLines(for: botID, inTurnOf: groupID)
        let groups = lines.prefix(OrbsPrompt.groupLimit).map { group in
            let lead = group.youOrchestrate ? "você orquestra" : "\(group.orchestrator) orquestra"
            return "- \(group.name): \(lead)" + (group.others.isEmpty ? "" : "; outros membros: " + group.others.joined(separator: ", "))
        }
        // The groups it is not in, which group_edit may change: without their names it could only guess them.
        let elsewhere = model.orbsCanManageGroups
            ? model.groups.filter { !$0.memberIDs.contains(botID) }.prefix(OrbsPrompt.groupLimit).map { GroupPrompt.label($0.name) } : []
        let otherText = elsewhere.isEmpty ? "" : "\n\nOutros grupos do usuário (você não é membro; group_edit muda): "
            + elsewhere.joined(separator: ", ") + "."
        guard !groups.isEmpty else { return teammates + otherText }
        // Outside a group's turn the Orb may start a group's work only with both switches on; else the user does it on the group's screen.
        let mayAsk = groupID != nil || (model.orbsActOnOwn && model.orbsCanStartGroups)
        let note = mayAsk ? "você pode acionar estes com ask, pelo nome"
            : "o usuário inicia o trabalho de um grupo na tela dele; você não escreve no fio"
        return teammates + "\n\nSeus grupos (\(note)):\n" + groups.joined(separator: "\n") + otherText
    }

    /// "livre", "ocupado", or "espera aprovação do usuário": a card of its turn is open, so whoever waits for it waits for the
    /// person, not for the work.
    private func status(of botID: UUID) -> String {
        if model?.liveBot(botID)?.needsYou == true { return "espera aprovação do usuário" }
        return isBusy(botID) ? "ocupado" : "livre"
    }

    /// In a group's turn, what the member is doing for the group: each open assignment ("trabalhando em “…” (pedido de Atlas,
    /// há 4 min)"), and whether it waits for the person. With none, `status(of:)`.
    private func groupStatus(of botID: UUID, in groupID: UUID, now: Date = .now) -> String {
        var parts: [String] = []
        if model?.liveBot(botID)?.needsYou == true { parts.append("espera aprovação do usuário") }
        let open = requests.values.filter { $0.envelope.groupID == groupID && $0.envelope.to.id == botID && Self.isOpen($0.state) }
            .sorted(by: Self.older)
        parts += open.prefix(3).map { assignmentText($0, now: now) }
        if open.count > 3 { parts.append("e mais \(open.count - 3)") }
        return parts.isEmpty ? status(of: botID) : parts.joined(separator: "; ")
    }

    /// One open request as `list` tells it: what, for whom, since when.
    private func assignmentText(_ request: DelegationRequest, now: Date) -> String {
        let envelope = request.envelope
        let what = "“" + MemoryText.clip(MemoryText.flatten(envelope.text), 60) + "”"
        let who = envelope.from.id == envelope.to.id && !envelope.fromChat ? "pedido do usuário" : "pedido de \(currentName(envelope.from))"
        switch request.state {
        case .queued:
            return "na fila: \(what) (\(who))"
        case .awaitingChildren:
            let names = request.openChildren.compactMap { requests[$0].map { currentName($0.envelope.to) } }
            let waits = names.isEmpty ? "esperando respostas" : "esperando " + Self.list(Array(Set(names)).sorted())
            return "\(waits) em \(what) (\(who))"
        default:
            return "trabalhando em \(what) (\(who), \(Self.ago(request.startedAt ?? envelope.sentAt, now: now)))"
        }
    }

    /// "há menos de 1 min", "há 4 min", "há 2 h".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "há menos de 1 min" }
        return minutes < 120 ? "há \(minutes) min" : "há \(minutes / 60) h"
    }

    /// "A", "A e B", "A, B e C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " e " + last
    }

    func isBusy(_ botID: UUID) -> Bool {
        isInTurn(botID) || !(queues[botID] ?? []).isEmpty
    }

    /// The Orb is in a turn (its own chat, a routine, a request), or one is starting.
    func isInTurn(_ botID: UUID) -> Bool {
        guard let model else { return false }
        return model.isWorking(botID) || model.sessions[botID]?.turnTask != nil || starting.contains(botID)
    }

    // MARK: What the person sees

    /// A request between Orbs outside groups still open, as Ajustes lists it (a group's are on the group's screen).
    struct OpenTalk: Identifiable, Equatable {
        var id: UUID
        var chainID: UUID
        /// "Atlas → Pesquisador".
        var title: String
        /// "“Revise o texto” · trabalhando · há 4 min".
        var detail: String
    }

    /// The open requests outside groups, oldest first: who asked whom, what, where it stands and since when.
    func openTalks(now: Date = .now) -> [OpenTalk] {
        requests.values
            .filter { $0.envelope.groupID == nil && $0.envelope.kind == .ask && Self.isOpen($0.state)
                && chainStates[$0.envelope.chainID]?.cancelled != true }
            .sorted(by: Self.older)
            .map { request in
                let envelope = request.envelope
                let from = currentName(envelope.from) + (envelope.servingRoutine != nil ? " (rotina)" : envelope.servingPulse != nil ? " (pulso)" : "")
                let state: String = switch request.state {
                case .queued: "na fila"
                case .awaitingChildren:
                    "esperando " + Self.list(Array(Set(request.openChildren.compactMap { requests[$0].map { currentName($0.envelope.to) } })).sorted())
                default: "trabalhando"
                }
                let what = "“" + MemoryText.clip(MemoryText.flatten(envelope.text), 80) + "”"
                return OpenTalk(id: envelope.id, chainID: envelope.chainID, title: "\(from) → \(currentName(envelope.to))",
                                detail: "\(what) · \(state) · \(Self.ago(envelope.sentAt, now: now))")
            }
    }

    /// Writes the Orb's wait ("Esperando Pesquisador") and its partner to its live state (only what changed is written).
    func refresh(_ ids: UUID...) { refresh(ids) }

    func refresh(_ ids: [UUID]) {
        guard let model else { return }
        // Every change of a request passes here: the journal forgets the ones that ended (answered, failed, stopped).
        if model.workJournal.tracksRequests {
            // Top-level chat replies are persisted as `.pendingReply`, so only non-persisted undelivered replies keep their request.
            let undelivered = inbox.values.flatMap {
                $0.filter { $0.servingRequest != nil || $0.servingRun != nil || $0.groupID != nil }.compactMap(\.replyTo)
            }
            model.workJournal.syncRequests(open: Set(requests.values.filter { Self.isOpen($0.state) }.map(\.id)).union(undelivered))
        }
        for id in Set(ids) {
            guard let live = model.liveBot(id) else { continue }
            let asks = openRequests(from: id)
            var names: [String] = []
            for request in asks {
                let name = displayName(of: request.envelope)
                if !names.contains(name) { names.append(name) }
            }
            live.setChainWork(Self.waitLine(names))
            live.isConversing = !asks.isEmpty
            live.setPartner(partner(of: id))
        }
    }

    /// The phrase of an Orb that waits: one name, two names, or a count.
    static func waitLine(_ names: [String]) -> WorkLine? {
        switch names.count {
        case 0: nil
        case 1: WorkLine(verb: "Esperando", target: names[0])
        case 2: WorkLine(verb: "Esperando", target: "\(names[0]) e \(names[1])")
        default: WorkLine(verb: "Esperando", target: "\(names.count) Orbs")
        }
    }

    private func partner(of botID: UUID) -> PartnerTint? {
        guard let model else { return nil }
        if let asked = openRequests(from: botID).first, let orb = model.bot(asked.envelope.to.id) {
            return PartnerTint(botID: orb.id, color: orb.orb.color)
        }
        let serving = requests.values.filter { $0.state == .running && $0.envelope.to.id == botID && $0.envelope.from.id != botID }
            .sorted(by: Self.older)
        if let first = serving.first, let orb = model.bot(first.envelope.from.id) {
            return PartnerTint(botID: orb.id, color: orb.orb.color)
        }
        return nil
    }

    // MARK: A group asked from a chat

    /// The group whose name this is, when no Orb has it.
    private func group(named name: String) -> OrbGroup? {
        guard let model else { return nil }
        let wanted = DelegationRules.fold(name)
        guard !wanted.isEmpty else { return nil }
        // An exact group name wins over a prefix of an Orb's ("Vendas" is the group, not "Vendas Sul"); an Orb with exactly
        // that name wins over the group (the two cannot share a name, but older data may).
        let group = model.groups.first { DelegationRules.fold($0.name) == wanted }
        if let orb = DelegationRules.resolve(name, among: model.bots.map(OrbRef.init)) {
            return DelegationRules.fold(orb.name) == wanted ? nil : group
        }
        return group
    }

    /// `orbs ask` with the name of a group the Orb is in, from its own chat and in a turn the person started (any turn with "Orbs agem por conta própria"): a new request of
    /// the group (`GroupHub.postOrbRequest`), marked as the Orb's and handed to the orchestrator as data. The refusals say what
    /// to do instead; nothing changes when one is thrown.
    private func submitToGroup(_ group: OrbGroup, from botID: UUID, text raw: String, kind: OrbEnvelope.Kind,
                               messageID: UUID) throws -> OrbEnvelope {
        guard let model, !isShuttingDown, let sender = model.bot(botID) else { throw DelegationRefusal.switchedOff }
        let name = group.name
        guard kind == .ask else { throw DelegationRefusal.groupDoor(name, .tell) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupDoor(name, .switchedOff) }
        guard group.memberIDs.contains(botID) else { throw DelegationRefusal.groupDoor(name, .notMember) }
        // Groups already behind the asking turn: its own group and the ones that led to it.
        var visited: Set<UUID> = []
        if model.orbsActOnOwn {
            if let running = model.session(botID).chain, let current = running.groupID {
                guard group.id != current else { throw DelegationRefusal.ownGroup(name) }
                guard model.group(current)?.orchestratorID == botID else { throw DelegationRefusal.groupDoor(name, .notOrchestrator) }
                visited = (chainStates[running.chainID]?.groupsVisited ?? []).union([current])
                guard !visited.contains(group.id) else { throw DelegationRefusal.groupDoor(name, .inChain) }
            }
        } else {
            guard model.isOwnChat(botID) else { throw DelegationRefusal.groupDoor(name, .notFromHere) }
            guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupDoor(name, .notAsked) }
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal.emptyMessage }
        guard text.count <= DelegationLimits.messageLimit else { throw DelegationRefusal.tooLong }
        guard !seenMessageIDs.contains(messageID) else { throw DelegationRefusal.duplicate }
        if model.pulseLineage(of: botID) != nil, model.pulseBudgetSpent { throw DelegationRefusal.pulseBudget }
        guard let request = model.groupHub.postOrbRequest(from: botID, text: text, to: group.id, messageID: messageID) else {
            throw DelegationRefusal.groupDoor(name, .unavailable)
        }
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.seenLimit { seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit) }
        let envelope = request.envelope
        // The target group's turns start on a later pass of the main actor, so this lands before any of them can ask back.
        if !visited.isEmpty { chainStates[envelope.chainID]?.groupsVisited.formUnion(visited) }
        // The asker's chat: "Atlas pediu ao Estúdio" (the group's name, the orchestrator's color).
        model.session(botID).append(.orbMessage(OrbMessageItem(direction: .sent, kind: .ask, state: .open, from: OrbRef(sender),
                                                               to: OrbRef(id: envelope.to.id, name: name), text: text,
                                                               requestID: envelope.id, chainID: envelope.chainID,
                                                               groupID: group.id, fromChat: true)))
        model.live(botID).poked()
        refresh(botID)
        return envelope
    }

    /// `group_create`: a group of the user's Orbs, made from the Orb's own chat in a turn the person started (any turn with "Orbs agem por conta própria"). The refusals say
    /// what to do instead; nothing is created when one is thrown.
    private func createGroup(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model, !isShuttingDown else { throw DelegationRefusal.groupSetup(.unavailable) }
        guard model.orbsCanStartGroups else { throw DelegationRefusal.groupSetup(.switchedOff) }
        if model.orbsActOnOwn {
            if let current = model.session(botID).chain?.groupID, model.group(current)?.orchestratorID != botID {
                throw DelegationRefusal.groupSetup(.notOrchestrator)
            }
        } else {
            guard model.isOwnChat(botID) else { throw DelegationRefusal.groupSetup(.notFromHere) }
            guard model.session(botID).turnAskedByUser else { throw DelegationRefusal.groupSetup(.notAsked) }
        }
        let name = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DelegationRefusal.groupSetup(.noName) }
        let orbs = model.bots.map(OrbRef.init)
        // A name that an Orb or another group has would make `orbs ask` ambiguous.
        guard DelegationRules.resolve(name, among: orbs) == nil,
              !model.groups.contains(where: { DelegationRules.fold($0.name) == DelegationRules.fold(name) }) else {
            throw DelegationRefusal.groupSetup(.nameTaken(name))
        }
        var members: [OrbRef] = []
        for typed in arguments["members"]?.array?.compactMap(\.string) ?? [] {
            guard let orb = DelegationRules.resolve(typed, among: orbs) else { throw DelegationRefusal.unknownOrb(typed) }
            if !members.contains(where: { $0.id == orb.id }) { members.append(orb) }
        }
        guard OrbGroup.memberLimits.contains(members.count), var lead = members.first else {
            throw DelegationRefusal.groupSetup(.memberCount)
        }
        if let typed = arguments["orchestrator"]?.string, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let orb = DelegationRules.resolve(typed, among: members) else {
                throw DelegationRefusal.groupSetup(.orchestratorNotMember(typed))
            }
            lead = orb
        }
        let objective = arguments["objective"]?.string ?? ""
        guard objective.count <= MemoryBank.identityMaximumLength else {
            throw ToolError("objective is too long (\(objective.count) characters; limit \(MemoryBank.identityMaximumLength)). Shorten it.")
        }
        var project = ""
        if let path = arguments["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            project = try AccessRequest.checkedFolder(path, home: model.homeFolder)
        }
        guard let group = model.createGroup(name: name, members: members.map(\.id), orchestrator: lead.id,
                                            objective: objective, projectFolder: project,
                                            createdBy: botID) else {
            throw DelegationRefusal.groupSetup(.unavailable)
        }
        let others = members.filter { $0.id != lead.id }.map(\.name)
        let next = members.contains(where: { $0.id == botID })
            ? "Para mandar o primeiro pedido, use orbs ask com to “\(group.name)”."
            : "Você não é membro: o usuário manda os pedidos na tela do grupo."
        return "Grupo \(group.name) criado: \(lead.name) orquestra; os outros membros são \(Self.list(others)). O usuário vê o grupo "
            + "na lateral. " + (project.isEmpty ? "" : "Pasta do projeto: \(project); os membros (menos o orquestrador) trabalham cada um no seu ramo. ") + next
    }

    /// One checked `group_edit`: the group, the Orb it is about and what the user is asked first (nil when nobody is).
    private struct GroupEditPlan {
        enum Edit: String { case add, remove, orchestrator, rename, objective, delete }
        var edit: Edit
        var group: OrbGroup
        var orb: OrbRef?
        var text = ""
        var confirmation: String?
    }

    /// Checks a `group_edit` against the groups as they are now, changing nothing. Deleting a group, or taking out a member of a group
    /// of two (which dissolves it), carries the text of the user's card.
    private func planGroupEdit(_ arguments: JSONValue, by botID: UUID) throws -> GroupEditPlan {
        guard let model, !isShuttingDown else { throw DelegationRefusal.groupEdit(.unavailable) }
        guard model.orbsCanManageGroups else { throw DelegationRefusal.groupEdit(.switchedOff) }
        let typedGroup = (arguments["group"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = DelegationRules.fold(typedGroup)
        guard !wanted.isEmpty, let group = model.groups.first(where: { DelegationRules.fold($0.name) == wanted }) else {
            throw DelegationRefusal.groupEdit(.noGroup(typedGroup, model.groups.prefix(OrbsPrompt.groupLimit).map(\.name)))
        }
        let typedEdit = (arguments["edit"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let edit = GroupEditPlan.Edit(rawValue: typedEdit) else { throw DelegationRefusal.groupEdit(.unknownEdit(typedEdit)) }
        var plan = GroupEditPlan(edit: edit, group: group)
        let orbs = model.bots.map(OrbRef.init)
        switch edit {
        case .add, .remove, .orchestrator:
            let typed = (arguments["orb"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { throw DelegationRefusal.groupEdit(.missing("orb")) }
            guard let orb = DelegationRules.resolve(typed, among: orbs) else { throw DelegationRefusal.unknownOrb(typed) }
            plan.orb = orb
            let isMember = group.memberIDs.contains(orb.id)
            switch edit {
            case .add:
                guard !isMember else { throw DelegationRefusal.groupEdit(.alreadyMember(orb: orb.name, group: group.name)) }
                guard group.memberIDs.count < OrbGroup.memberLimits.upperBound else { throw DelegationRefusal.groupEdit(.full(group.name)) }
            case .remove:
                guard isMember else { throw DelegationRefusal.groupEdit(.notMember(orb: orb.name, group: group.name)) }
                if group.memberIDs.count <= OrbGroup.memberLimits.lowerBound {
                    plan.confirmation = "\(model.bot(botID)?.name ?? "Um Orb") quer tirar \(orb.name) do grupo “\(group.name)”. "
                        + "Com isso o grupo acaba (precisa de \(OrbGroup.memberLimits.lowerBound) Orbs, no mínimo); os Orbs ficam."
                }
            default:
                guard isMember else { throw DelegationRefusal.groupEdit(.notMember(orb: orb.name, group: group.name)) }
            }
        case .rename:
            let name = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw DelegationRefusal.groupEdit(.missing("name")) }
            // The same rule as `group_create`: a name an Orb or another group has would make `orbs ask` ambiguous.
            guard DelegationRules.resolve(name, among: orbs) == nil,
                  !model.groups.contains(where: { $0.id != group.id && DelegationRules.fold($0.name) == DelegationRules.fold(name) }) else {
                throw DelegationRefusal.groupEdit(.nameTaken(name))
            }
            plan.text = name
        case .objective:
            let text = (arguments["objective"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DelegationRefusal.groupEdit(.missing("objective")) }
            plan.text = text
        case .delete:
            plan.confirmation = "\(model.bot(botID)?.name ?? "Um Orb") quer apagar o grupo “\(group.name)”: o fio, o quadro e as conversas dos "
                + "membros nele vão embora. Os Orbs ficam."
        }
        return plan
    }

    /// `group_edit`: changes one of the user's groups. The refusals say what to do instead; nothing changes when one is thrown.
    /// `confirmed` comes from the tool after the user's card; an edit that needs it is refused without.
    private func editGroup(_ arguments: JSONValue, by botID: UUID) async throws -> String {
        guard let model else { throw DelegationRefusal.groupEdit(.unavailable) }
        let plan = try planGroupEdit(arguments, by: botID)
        if plan.confirmation != nil {
            guard arguments["confirmed"]?.bool == true else { throw DelegationRefusal.groupEdit(.needsConfirmation) }
            // The yes was for this group and this Orb: a rename since the card must not turn it into another deletion.
            guard arguments["expect_group"]?.string == plan.group.id.uuidString,
                  plan.orb.map({ arguments["expect_orb"]?.string == $0.id.uuidString }) ?? true else {
                throw DelegationRefusal.groupEdit(.changed)
            }
        }
        let group = plan.group
        switch plan.edit {
        case .add:
            guard let orb = plan.orb, model.addMember(orb.id, to: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "\(orb.name) entrou no grupo \(group.name)."
        case .remove:
            guard let orb = plan.orb, model.removeMember(orb.id, from: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            guard let left = model.group(group.id) else { return "\(orb.name) saiu e o grupo \(group.name) acabou (precisa de 2 Orbs, no mínimo)." }
            let lead = left.orchestratorID != group.orchestratorID ? " \(model.bot(left.orchestratorID)?.name ?? "Outro Orb") passou a orquestrar." : ""
            return "\(orb.name) saiu do grupo \(group.name)." + lead
        case .orchestrator:
            guard let orb = plan.orb, model.setOrchestrator(orb.id, of: group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "\(orb.name) agora orquestra o grupo \(group.name)."
        case .rename:
            model.renameGroup(group.id, to: plan.text)
            guard let renamed = model.group(group.id) else { throw DelegationRefusal.groupEdit(.unavailable) }
            return "O grupo \(group.name) agora se chama \(renamed.name)."
        case .objective:
            guard await model.setGroupObjective(plan.text, of: group.id) else { throw DelegationRefusal.groupEdit(.objectiveRefused) }
            return "Objetivo do grupo \(group.name) gravado."
        case .delete:
            model.deleteGroup(group.id)
            return "Grupo \(group.name) apagado; os Orbs continuam."
        }
    }

    /// `group_edit` in a turn nobody watches, for an edit the user must confirm: the ask goes to the chat (`askDeletionLater`).
    private func askGroupEditLater(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model else { throw DelegationRefusal.groupEdit(.unavailable) }
        let plan = try planGroupEdit(arguments, by: botID)
        guard let text = plan.confirmation else { throw DelegationRefusal.groupEdit(.unavailable) } // nothing to ask: edit_group does it
        let ask: DeletionAsk
        switch (plan.edit, plan.orb) {
        case (.delete, _): ask = .group(id: plan.group.id, name: plan.group.name)
        case (.remove, let orb?): ask = .removeMember(orb, groupID: plan.group.id, groupName: plan.group.name)
        default: throw DelegationRefusal.groupEdit(.unavailable) // no other edit asks the user
        }
        return model.askDeletionLater(ask, by: botID, text: text)
    }

    /// Checks an `orb_delete` against the Orbs as they are now, changing nothing: the Orb to delete (by its whole name, never a
    /// prefix) and the text of the user's card. A refusal says what to do instead.
    private func planOrbDelete(_ arguments: JSONValue, by botID: UUID) throws -> (orb: OrbRef, confirmation: String) {
        guard let model, !isShuttingDown else { throw ToolError("The app is closing.") }
        guard model.orbsCanManageGroups else {
            throw ToolError("The user switched off \"Orbs organizam grupos\": tell them which Orb you would delete and why.")
        }
        let typed = (arguments["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = DelegationRules.fold(typed)
        let matches = model.bots.filter { DelegationRules.fold($0.name) == wanted }
        guard !wanted.isEmpty, matches.count == 1, let target = matches.first else {
            throw ToolError(matches.count > 1 ? "More than one Orb is named \"\(typed)\": the user can delete it on their screen."
                            : "No Orb is named \"\(typed)\" (use the whole name; orbs list shows them).")
        }
        guard target.id != botID else { throw ToolError("You cannot delete yourself: ask the user if you should go.") }
        guard model.liveBot(target.id)?.isWorking != true, model.sessions[target.id]?.turnTask == nil else {
            throw ToolError("\(target.name) is working right now: try again when it is free.")
        }
        let reason = String(MemoryText.flatten(MemorySanitizer.scrub(arguments["reason"]?.string ?? "")).prefix(200))
        let who = model.bot(botID)?.name ?? "Um Orb"
        let because = reason.isEmpty ? "" : " Motivo: \(reason)"
        // The groups of two it is in end with it (`AppModel.leaveGroups`): the card says so.
        let ending = model.groups.filter { $0.memberIDs.contains(target.id) && $0.memberIDs.count <= OrbGroup.memberLimits.lowerBound }
            .map { "“\($0.name)”" }
        let groupsEnd = ending.isEmpty ? "" : (ending.count == 1 ? " O grupo \(ending[0]) acaba." : " Os grupos \(Self.list(ending)) acabam.")
        return (OrbRef(target), "\(who) quer apagar \(PortugueseArticle.article(for: target.name)) \(target.name).\(because) "
            + "A conversa, a memória e as rotinas dele vão embora, e ele sai dos grupos.\(groupsEnd)")
    }

    /// `orb_delete` once the user confirmed in the tool's card (`confirmed` is set by the tool alone).
    private func deleteOrb(_ arguments: JSONValue, by botID: UUID) throws -> String {
        guard let model else { throw ToolError("The app is closing.") }
        let plan = try planOrbDelete(arguments, by: botID)
        guard arguments["confirmed"]?.bool == true else { throw ToolError("The user did not confirm. Nothing changed.") }
        // The yes was for this Orb: another one that took the name since must not go.
        guard arguments["expect_orb"]?.string == plan.orb.id.uuidString else {
            throw ToolError("The Orb changed since the user confirmed: nothing was deleted. Check with orbs list and ask again.")
        }
        model.deleteBot(plan.orb.id)
        return "\(plan.orb.name) was deleted."
    }

    // MARK: The pulse's lineage

    func pulseRun(ofChain chainID: UUID) -> UUID? { chainStates[chainID]?.origin.pulseRun }

    /// A chain no person began (the pulse's, a routine's run): a group's turn in it has nobody to answer a card.
    func isUnattended(chain chainID: UUID?) -> Bool {
        switch chainID.flatMap({ chainStates[$0]?.origin }) {
        case .pulse?, .routine?: true
        case .chat?, .group?, nil: false
        }
    }

    func seedChain(_ chainID: UUID, pulseRun: UUID, originBot: UUID, groupID: UUID?) {
        guard chainStates[chainID] == nil else { return }
        chainStates[chainID] = ChainState(origin: .pulse(pulseRun), originBot: originBot, groupID: groupID)
    }
}
