import Foundation

// The `schedule` tool's side of the app: an Orb asks in the chat for something to repeat ("verifique meus e-mails a
// cada 30 minutos") and it becomes one of its routines, the same ones the Rotinas page and the Orb's panel show.
// Both engines end up in `schedule(_:orb:)`, so the limits and the words are the same.

extension AppModel {
    /// Tasks one Orb may have at a time.
    static let scheduledTaskLimit = 20

    /// The handler the Orb's tools get for a native turn (`ToolContext.schedule`).
    func scheduleHandler(for botID: UUID) -> ScheduleHandler {
        { [weak self] arguments in
            guard let model = self else { throw ToolError("O app está fechando.") }
            return try await model.schedule(arguments, orb: botID)
        }
    }

    /// Carries out one call of the tool for `botID`, which only ever sees and changes its own routines. The task
    /// runs in the Orb's own permission mode (`permissionMode` stays nil): it can never do more than the Orb can.
    /// Returns what the Orb is told, and what the chat shows as the tool's result.
    func schedule(_ arguments: JSONValue, orb botID: UUID) throws -> String {
        guard let orb = bot(botID) else { throw ToolError("Este Orb não existe mais.") }
        let own = routines(for: botID)
        switch try ScheduleCommand(arguments) {
        case .create(let name, let prompt, let schedule, let goal, let enabled, let runNow, let precheck):
            // A run that reads an e-mail or a page must not be able to plant tasks that outlive it.
            if let refusal = sideRunRefusal(botID, routine: "Uma tarefa agendada não cria outras tarefas.") { throw refusal }
            guard own.count < Self.scheduledTaskLimit else {
                throw ToolError("Este Orb já tem \(Self.scheduledTaskLimit) tarefas agendadas. Apague alguma antes (action delete).")
            }
            guard !own.contains(where: { $0.name.sameName(as: name) }) else {
                throw ToolError("Já existe uma tarefa chamada “\(name)”. Escolha outro nome ou apague a antiga.")
            }
            var routine = Routine(name: name, botID: botID, prompt: prompt, schedule: schedule, goal: goal.map { RoutineGoal(target: $0) })
            routine.isEnabled = enabled
            routine.precheck = precheck
            routines.append(routine)
            show(routine, of: botID)
            if runNow { runRoutine(routine.id, manual: true) }
            // Nobody is there during a run: in "Perguntar antes" it waits for you, which is worth knowing now.
            let waits = RoutineText.waitsForAnswer(orbMode: orb.permissionMode, routineMode: nil)
            return "Agendei “\(name)”: \(schedule.label.lowercasedFirst). "
                + (enabled ? "\(RoutineText.preview(nextRun: routine.nextRun)). " : "Ela foi criada pausada e só roda depois de retomada. ")
                + (runNow ? Self.runNowNote + " " : "")
                + (goal == nil ? "" : "Cada execução informa o progresso da meta, e a tarefa pausa quando ela for alcançada. ")
                + "Ela aparece na aba Rotinas do painel, onde dá para pausar ou apagar."
                + (waits ? " Como \(orb.name) pergunta antes de agir, cada execução espera a sua aprovação (em Automático ela roda sozinha)." : "")
        case .update(let name, let prompt, let schedule, let goal, let precheck):
            if let refusal = sideRunRefusal(botID, routine: "Uma tarefa agendada não altera tarefas.") { throw refusal }
            let current = try own.named(name)
            guard let index = routines.firstIndex(where: { $0.id == current.id }) else { throw ToolError("Não achei a tarefa “\(name)”.") }
            if let prompt { routines[index].prompt = prompt }
            if let precheck { routines[index].precheck = precheck }
            if let goal, goal != routines[index].goal?.target {
                // The last check measured the old goal: a new one starts unmeasured.
                routines[index].goal = goal.isEmpty ? nil : RoutineGoal(target: goal)
            }
            if let schedule, schedule != routines[index].schedule {
                // Counted from now, as the editor does: not from when the task was created.
                routines[index].schedule = schedule
                routines[index].createdAt = .now
                routines[index].lastRun = nil
            }
            let routine = routines[index]
            show(routine, of: botID)
            return "Alterei “\(routine.name)”: \(routine.schedule.label.lowercasedFirst), "
                + (routine.isEnabled ? RoutineText.preview(nextRun: routine.nextRun).lowercasedFirst : "pausada") + "."
                + (routine.goal.map { " Meta: \(MemoryText.clip($0.target, 120))." } ?? "")
        case .list:
            guard !own.isEmpty else { return "Nenhuma tarefa agendada." }
            return own.map { routine in
                let state = routine.isEnabled ? RoutineText.nextRun(of: routine)?.lowercasedFirst ?? "" : "pausada"
                let goal = routine.goal.map { goal in
                    " Meta: \(MemoryText.clip(goal.target, 120))" + (goal.check.map { " (\($0.label))" } ?? "")
                } ?? ""
                return "- “\(routine.name)”: \(routine.schedule.label.lowercasedFirst), \(state). Faz: \(MemoryText.clip(MemoryText.flatten(routine.prompt), 120))" + goal
            }.joined(separator: "\n")
        case .setEnabled(let name, let enabled):
            // A run may stop tasks, never start them again.
            if enabled, let refusal = sideRunRefusal(botID, routine: "Uma tarefa agendada não retoma outras tarefas.") { throw refusal }
            let routine = try own.named(name)
            guard routine.isEnabled != enabled else { return "“\(routine.name)” já estava \(enabled ? "ativa" : "pausada")." }
            guard setRoutineEnabled(routine.id, enabled) else {
                return "Não retomei “\(routine.name)”: a data dela já passou e não haveria próxima execução. Mude a data (update com when) ou crie outra."
            }
            return enabled ? "Retomei “\(routine.name)”. \(RoutineText.preview(of: routine.schedule))."
                : "Pausei “\(routine.name)”. Ela não roda até ser retomada."
        case .run(let name):
            if let refusal = sideRunRefusal(botID, routine: "Uma tarefa agendada não dispara outras tarefas.") { throw refusal }
            let routine = try own.named(name)
            guard !isRoutineRunning(routine.id) else { return "“\(routine.name)” já está rodando." }
            runRoutine(routine.id, manual: true)
            return "Pedi para rodar “\(routine.name)” agora. " + Self.runNowNote
        case .delete(let name):
            if let refusal = sideRunRefusal(botID, routine: "Uma tarefa agendada não apaga tarefas; pode só pausá-las.") { throw refusal }
            let routine = try own.named(name)
            deleteRoutine(routine.id)
            return "Apaguei “\(routine.name)”."
        }
    }

    /// Why a turn that is not the Orb's own chat may not change its tasks (nil in the chat). `routine` is the refusal of a
    /// routine's run; a request from another Orb and a group's turn (`routineID` marks them too) are told what they are and what
    /// to do instead.
    private func sideRunRefusal(_ botID: UUID, routine: String) -> ToolError? {
        guard let session = sessions[botID], session.routineID != nil else { return nil }
        switch session.sideKind {
        case .group:
            return ToolError("Num turno de grupo não se agenda nem se muda tarefa: proponha a rotina na sua resposta, e o usuário "
                + "a cria no chat deste Orb.")
        case .delegation:
            return ToolError("Num pedido de outro Orb não se agenda nem se muda tarefa: sugira a rotina no seu resultado, e o "
                + "usuário decide.")
        case .routine, nil:
            return ToolError(routine)
        }
    }

    /// The run waits for the Orb's current turn (this one, when the Orb asked in its chat) to end.
    static let runNowNote = "A execução começa assim que este Orb estiver livre e tem conversa própria; o resultado aparece no chat quando ela terminar."

    /// Turns a routine on or off. A routine for one moment already past stays off (it would have no next run): false then.
    @discardableResult
    func setRoutineEnabled(_ id: UUID, _ enabled: Bool) -> Bool {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return false }
        guard !enabled || routines[index].canBeEnabled() else { return false }
        routines[index].setEnabled(enabled)
        return true
    }

    /// Lets the panel show the new task, when it is on screen for this Orb: its tab opens and the row is highlighted
    /// for a moment (with the tap that goes with it). Another Orb's panel, or none, is left alone.
    private func show(_ routine: Routine, of botID: UUID) {
        guard showInspector, selectedBotID == botID else { return }
        freshRoutine = routine.id
        request(.showTab(.routines), of: botID)
        Task { [weak self] in
            try? await Task.sleep(for: self?.freshDuration ?? .zero)
            if self?.freshRoutine == routine.id { self?.freshRoutine = nil }
        }
    }
}

extension [Routine] {
    /// The routine with this name (case and accents aside), never a guess: deleting the wrong task is not undone. The
    /// refusal lists the names there are.
    func named(_ name: String) throws -> Routine {
        if let found = first(where: { $0.name.sameName(as: name) }) { return found }
        throw ToolError("Não achei a tarefa “\(name)”. As deste Orb: \(isEmpty ? "nenhuma" : map { "“\($0.name)”" }.joined(separator: ", ")).")
    }
}

private extension String {
    /// Without the quotes the results put around names (“…”), which the model tends to copy.
    var foldedName: String { trimmingCharacters(in: Self.nameEdges).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    static let nameEdges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"'"))
    func sameName(as other: String) -> Bool { foldedName == other.foldedName }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
