import Foundation

/// Events a bot turn emits. Mirrors the shape of the OpenBot gateway SSE stream
/// (status, text deltas, tool-call cards, approvals) so the mock can be swapped
/// for a real client without touching the UI.
enum TurnEvent: Sendable {
    case status(String)
    case text(String)
    case toolStarted(ToolCall)
    case toolFinished(id: UUID, state: ToolCall.State, output: String?)
    case approval(ApprovalRequest)
    case finished
}

protocol AgentGateway: Sendable {
    func runTurn(bot: Bot, prompt: String) -> AsyncStream<TurnEvent>
    func resolve(approvalID: UUID, decision: ApprovalDecision) async
    func cancelPendingApprovals() async
}

/// Scripted gateway for the prototype. Plays a short turn with a search,
/// an approval prompt and a shell command.
actor MockGateway: AgentGateway {
    private var pending: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    nonisolated func runTurn(bot: Bot, prompt: String) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let task = Task { await self.play(bot: bot, prompt: prompt, out: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resolve(approvalID: UUID, decision: ApprovalDecision) {
        pending.removeValue(forKey: approvalID)?.resume(returning: decision)
    }

    func cancelPendingApprovals() {
        for continuation in pending.values { continuation.resume(returning: .deny) }
        pending.removeAll()
    }

    private func waitForDecision(_ id: UUID) async -> ApprovalDecision {
        await withCheckedContinuation { pending[id] = $0 }
    }

    private func play(bot: Bot, prompt: String, out: AsyncStream<TurnEvent>.Continuation) async {
        defer { out.finish() }

        out.yield(.status("Lendo seu pedido"))
        guard await nap(0.7) else { return }
        guard await stream("Entendi. Vou olhar o que tem por aqui e já te mostro o caminho.", to: out) else { return }

        let topic = prompt.split(separator: " ").prefix(4).joined(separator: " ")
        let search = ToolCall(kind: .search, title: "Procurando nos seus arquivos", detail: "~/Projects · \"\(topic)\"")
        out.yield(.toolStarted(search))
        out.yield(.status("Vasculhando pastas"))
        guard await nap(1.2) else { return }
        out.yield(.toolFinished(id: search.id, state: .done, output: "12 resultados · 3 relevantes\n~/Projects/site/README.md\n~/Projects/api/package.json\n~/Projects/notas/ideias.md"))

        let command = "brew outdated --quiet"
        let decision: ApprovalDecision
        switch bot.permissionMode {
        case .auto:
            decision = .once
        case .readOnly:
            decision = .deny
        case .ask:
            let request = ApprovalRequest(
                title: "Executar um comando no seu Mac",
                command: command,
                reason: "Para saber quais ferramentas estão desatualizadas antes de sugerir uma atualização."
            )
            out.yield(.approval(request))
            out.yield(.status("Esperando sua resposta"))
            decision = await waitForDecision(request.id)
        }
        guard !Task.isCancelled else { return }

        if decision == .deny {
            _ = await stream("\n\nTudo bem, não vou executar nada. Se quiser, listo o que faria passo a passo.", to: out)
        } else {
            let shell = ToolCall(kind: .shell, title: "Rodando no Terminal", detail: command)
            out.yield(.toolStarted(shell))
            out.yield(.status("Rodando o comando"))
            guard await nap(1.4) else { return }
            out.yield(.toolFinished(id: shell.id, state: .done,
                                    output: "node (22.9.0) < 22.11.0\npython@3.13 (3.13.0) < 3.13.1\nffmpeg (7.1) < 7.1.1"))
            out.yield(.status("Escrevendo a resposta"))
            _ = await stream("\n\nPronto. Encontrei **3 pacotes desatualizados**: `node`, `python@3.13` e `ffmpeg`. Quer que eu atualize agora ou crie uma rotina semanal para isso?", to: out)
        }
        out.yield(.finished)
    }

    private func nap(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func stream(_ text: String, to out: AsyncStream<TurnEvent>.Continuation) async -> Bool {
        var chunk = ""
        for character in text {
            chunk.append(character)
            if character == " " || character == "\n" {
                out.yield(.text(chunk))
                chunk = ""
                guard await nap(0.035) else { return false }
            }
        }
        if !chunk.isEmpty { out.yield(.text(chunk)) }
        return !Task.isCancelled
    }
}
