import SwiftUI

private enum InicioSheet: Identifiable {
    case run(UUID, UUID)
    case conversation(UUID)
    case followUp(UUID, UUID)

    var id: String {
        switch self {
        case .run(let routine, let run): "\(routine)-\(run)"
        case .conversation(let routine): "\(routine)"
        case .followUp(let routine, let item): "\(routine)-\(item)"
        }
    }
}

private enum InicioRowFocus: Hashable {
    case approval(UUID), attention(UUID), working(UUID), news(UUID), followUp(UUID)
}

/// A view of the app's own results. It does not ask a model or reload external services.
struct InicioView: View {
    /// Snapshots force Reduce Motion because `accessibilityReduceMotion` is a read-only environment value.
    var reduceMotionOverride: Bool?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: InicioSheet?
    @State private var showingAll = false
    @State private var showingRecent = false
    @State private var unavailable: String?
    @State private var presentedEntries: [InicioEntry] = []
    @State private var readingBelowTop = false
    @State private var returningFocus: InicioRowFocus?
    @State private var scrollAnchor = InicioScrollAnchor()
    @FocusState private var focusedRow: InicioRowFocus?
    @AccessibilityFocusState private var accessibilityFocusedRow: InicioRowFocus?

    private var events: [InicioEntry] {
        let base = model.inicioVisitBase
        return presentedEntries.reversed().filter { showingRecent || base == nil || $0.sequence > base! }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                Color.clear.frame(height: 0).id("inicio-top")
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .named("inicio-scroll")).minY < -40 } action: { readingBelowTop = $0 }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Início").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.inicioVisitBase == nil ? "Resultados recentes dos seus Orbs" : "O que mudou desde sua última visita")
                        .font(Typography.text).foregroundStyle(Palette.muted)
                }
                if model.botIDs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(Palette.faint).accessibilityHidden(true)
                        Text("Ainda não há Orbs").font(Typography.title).foregroundStyle(Palette.ink)
                        Text("Crie seu primeiro Orb para começar.").font(Typography.text).foregroundStyle(Palette.muted)
                        Button("Criar Orb") { model.selection = nil }.buttonStyle(PrimaryPillStyle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 52)
                } else {
                    attention
                        .transition(.opacity)
                    working
                        .transition(.opacity)
                    Color.clear.frame(height: 0)
                        .background(InicioScrollAnchorBridge(anchor: scrollAnchor))
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("inicio-scroll")).minY } action: { scrollAnchor.observe(viewportY: $0) }
                    news
                    followUps
                        .transition(.opacity)
                }
            }
            .pageColumn()
            .animation(readingBelowTop ? nil : Motion.adapted(Motion.content, reduceMotion: reduceMotionOverride ?? reduceMotion), value: model.workingIDs)
        }
        .coordinateSpace(name: "inicio-scroll")
        .overlay(alignment: .bottom) {
            if readingBelowTop && model.inicio.entries.last?.sequence != presentedEntries.last?.sequence {
                Button("Novos resultados") {
                    presentEntries()
                    proxy.scrollTo("inicio-top", anchor: .top)
                }
                .buttonStyle(PrimaryPillStyle())
                .padding()
            }
        }
        }
        .background(Palette.canvas)
        .navigationTitle("Início")
        .onAppear { presentEntries() }
        .onChange(of: model.inicio.entries) { if !readingBelowTop { presentEntries() } }
        .onChange(of: readingBelowTop) { if !readingBelowTop { presentEntries() } }
        .sheet(item: $sheet, onDismiss: restoreSheetFocus) { target in
            switch target {
            case .run(let routine, let run):
                RoutineRunSheet(routineID: routine, runID: run, onConversation: { sheet = .conversation(routine) })
            case .conversation(let routine): RoutineConversationSheet(routineID: routine)
            case .followUp(let routine, let item): InicioFollowUpSheet(routineID: routine, followUpID: item)
            }
        }
        .alert("Não foi possível abrir", isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } })) {
            Button("OK") { unavailable = nil }
        } message: { Text(unavailable ?? "") }
    }

    private func presentEntries() {
        presentedEntries = model.inicio.entries
        model.inicioDidPresent(presentedEntries.last?.sequence)
    }

    private func present(_ target: InicioSheet, from row: InicioRowFocus) {
        returningFocus = row
        sheet = target
    }

    private func restoreSheetFocus() {
        guard sheet == nil, model.selection == .inicio, let row = returningFocus else { return }
        returningFocus = nil
        focusedRow = row
        accessibilityFocusedRow = row
    }

    @ViewBuilder private var attention: some View {
        let pending = model.pendingApprovals
        let flagged = model.routines.compactMap { routine -> (Routine, RoutineRun)? in
            guard routine.goal?.check?.status == .attention,
                  let run = routine.runs.first(where: { $0.check?.status == .attention }) else { return nil }
            return (routine, run)
        }
        if !pending.isEmpty || !flagged.isEmpty {
            section("Precisa de você", count: pending.count + flagged.count) {
                ForEach(pending) { item in
                    row(botID: item.bot.id, focus: .approval(item.request.id), title: item.request.title, detail: "Aguardando sua resposta", date: nil) {
                        openPending(item.bot.id, approval: item.request.id)
                    }
                }
                ForEach(flagged, id: \.1.id) { routine, run in
                    row(botID: routine.botID, focus: .attention(run.id), title: run.summary, detail: "Resultado da rotina pede atenção", date: run.date) {
                        guard model.routines.contains(where: { $0.id == routine.id && $0.runs.contains(where: { $0.id == run.id }) }) else {
                            unavailable = "Esta execução não está mais no histórico da rotina."; return
                        }
                        present(.run(routine.id, run.id), from: .attention(run.id))
                    }
                }
            }
        }
    }

    @ViewBuilder private var working: some View {
        if !model.workingIDs.isEmpty {
            section("Em andamento", count: model.workingIDs.count) {
                ForEach(model.workingIDs, id: \.self) { id in
                    row(botID: id, focus: .working(id), title: model.live(id).shownWork?.headline ?? "Trabalhando", detail: "Ver trabalho", date: nil) {
                        openWork(id)
                    }
                }
            }
        }
    }

    private var news: some View {
        let currentAttention = Set(model.routines.compactMap { routine -> UUID? in
            guard routine.goal?.check?.status == .attention else { return nil }
            return routine.runs.first(where: { $0.check?.status == .attention })?.id
        })
        let news = events.filter { !currentAttention.contains($0.id) }
        return section("Novidades", count: news.count) {
            if news.isEmpty {
                Text(model.inicioVisitBase == nil ? "Ainda não há resultados recentes." : "Nenhuma novidade desde sua última visita.")
                    .font(Typography.text).foregroundStyle(Palette.muted).padding(.vertical, 8)
                if !presentedEntries.isEmpty && !showingRecent {
                    Button("Ver resultados recentes") { showingRecent = true }.buttonStyle(GhostStyle())
                }
            } else {
                ForEach(Array(showingAll ? news : Array(news.prefix(5)))) { event in eventRow(event) }
                if news.count > 5 {
                    Button(showingAll ? "Mostrar menos" : "Ver mais") { showingAll.toggle() }.buttonStyle(GhostStyle())
                }
            }
            if showingRecent { Button("Voltar às novidades") { showingRecent = false }.buttonStyle(GhostStyle()) }
        }
    }

    @ViewBuilder private var followUps: some View {
        let items = model.routines.flatMap { routine in routine.followUps.filter { !$0.resolved }.map { (routine, $0) } }
        if !items.isEmpty {
            section("Acompanhamentos", count: items.count) {
                ForEach(items, id: \.1.id) { routine, item in
                    row(botID: routine.botID, focus: .followUp(item.id), title: item.subject,
                        detail: "\(item.channel) · \(item.nextStep)" + (item.lastChecked.map { " · Verificado " + RoutineText.stamp($0) } ?? " · Sem verificação registrada"), date: nil) {
                        guard model.routines.contains(where: { $0.id == routine.id && $0.followUps.contains(where: { $0.id == item.id }) }) else {
                            unavailable = "Este acompanhamento não está mais disponível."; return
                        }
                        present(.followUp(routine.id, item.id), from: .followUp(item.id))
                    }
                }
            }
        }
    }

    private func eventRow(_ event: InicioEntry) -> some View {
        row(botID: event.botID, focus: .news(event.id), title: event.summary.isEmpty ? "Resultado registrado" : event.summary,
            detail: outcome(event.outcome), date: event.date) { open(event) }
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Spacer()
                if count > 0 { Text("\(count) \(count == 1 ? "item" : "itens")").font(Typography.small).foregroundStyle(Palette.muted) }
            }
            Divider()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.card, stroke: Palette.line)
    }

    private func row(botID: UUID, focus: InicioRowFocus, title: String, detail: String, date: Date?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let bot = model.bot(botID) {
                Button { model.selection = .bot(botID) } label: {
                    LiveBotAvatar(botID: botID, orb: bot.orb, size: 32, restsWhenIdle: true)
                }.buttonStyle(.plain).help("Abrir conversa de \(bot.name)").accessibilityLabel("Abrir conversa de \(bot.name)")
                    .focusable()
                    .onKeyPress(.return) { model.selection = .bot(botID); return .handled }
                    .onKeyPress(.space) { model.selection = .bot(botID); return .handled }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let bot = model.bot(botID) {
                    Button(bot.name) { model.selection = .bot(botID) }
                        .buttonStyle(.plain).font(Typography.small.weight(.semibold)).foregroundStyle(Palette.secondary)
                        .help("Abrir conversa de \(bot.name)")
                        .focusable()
                        .onKeyPress(.return) { model.selection = .bot(botID); return .handled }
                        .onKeyPress(.space) { model.selection = .bot(botID); return .handled }
                } else {
                    Text("Orb indisponível").font(Typography.small.weight(.semibold)).foregroundStyle(Palette.secondary)
                }
                Button(action: action) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Typography.text).foregroundStyle(Palette.ink).lineLimit(3).multilineTextAlignment(.leading)
                        Text(detail).font(Typography.small).foregroundStyle(Palette.muted).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 4)
                        if let date { Text(ReplyTime.label(date)).font(Typography.small).foregroundStyle(Palette.faint) }
                        Image(systemName: "chevron.right").font(Typography.small).foregroundStyle(Palette.faint)
                    }.contentShape(.rect)
                }.buttonStyle(.plain)
                    .focusable()
                    .focused($focusedRow, equals: focus)
                    .accessibilityFocused($accessibilityFocusedRow, equals: focus)
                    .onKeyPress(.return) { action(); return .handled }
                    .onKeyPress(.space) { action(); return .handled }
            }
        }
        .padding(.vertical, 6)
    }

    private func outcome(_ outcome: InicioEntry.Outcome) -> String {
        switch outcome {
        case .completed: "Concluído"
        case .failed: "Não terminou"
        case .attention: "Pede atenção"
        case .skipped: "Dispensada pela pré-checagem"
        case .recorded: "Resultado anterior"
        }
    }

    private func open(_ event: InicioEntry) {
        switch event.origin {
        case .chat(let bot, let chat, let item):
            if !model.openInicioChat(bot: bot, chat: chat, item: item) { unavailable = "A conversa de origem não está mais disponível." }
        case .routine(let bot, let routine, let run):
            guard model.routines.contains(where: { $0.id == routine && $0.botID == bot }) else {
                unavailable = "A rotina de origem não está mais disponível."; return
            }
            if model.routines.first(where: { $0.id == routine })?.runs.contains(where: { $0.id == run }) == true {
                present(.run(routine, run), from: .news(event.id))
            } else { unavailable = "Esta execução não está mais no histórico da rotina." }
        }
    }

    private func openWork(_ botID: UUID) {
        guard let session = model.sessions[botID] else { unavailable = "Este trabalho não está mais em andamento."; return }
        if session.sideKind == nil || session.sideKind == .routine, let routine = session.routineID {
            guard model.routines.contains(where: { $0.id == routine && $0.botID == botID }) else { return }
            present(.conversation(routine), from: .working(botID))
        } else if session.routineID == nil && session.sideKind == nil {
            let chat = session.workingChatID ?? session.chatID
            if model.live(botID).chats == nil { model.selection = .bot(botID) } else { model.openChat(chat, of: botID) }
        } else if session.sideKind == .group, model.showGroupOfMember(botID) {
            return
        } else if session.sideKind == .delegation, let request = session.servingRequest {
            model.selection = .bot(botID)
            model.sideWorkToShow = SideWorkTarget(botID: botID, requestID: request)
        } else {
            unavailable = "Abra a conversa do Orb para acompanhar este trabalho."
        }
    }

    private func openPending(_ botID: UUID, approval: UUID) {
        guard model.isPending(approval, of: botID), let session = model.sessions[botID] else {
            unavailable = "Este pedido já não está aguardando resposta."; return
        }
        if session.routineID == nil, let chat = session.conversationChat,
           let item = session.conversation?.items.first(where: {
               if case .approval(let request) = $0.kind { return request.id == approval && request.decision == nil }
               return false
           }) {
            if !model.openInicioChat(bot: botID, chat: chat, item: item.id) {
                unavailable = "A conversa deste pedido não está mais disponível."
            }
        } else {
            model.showApprovalOwner(botID)
        }
    }
}

private struct InicioFollowUpSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineID: UUID
    let followUpID: UUID

    var body: some View {
        let routine = model.routines.first { $0.id == routineID }
        let followUp = routine?.followUps.first { $0.id == followUpID }
        Group {
            if let routine, let followUp {
                VStack(alignment: .leading, spacing: 10) {
                    Text(followUp.nextStep).font(Typography.text).foregroundStyle(Palette.ink)
                    Text("Canal: \(followUp.channel)").font(Typography.label).foregroundStyle(Palette.secondary)
                    if let action = followUp.lastAction { Text("Última ação: \(action)").font(Typography.label).foregroundStyle(Palette.secondary) }
                    if let checked = followUp.lastChecked {
                        Text("Última verificação: \(RoutineText.stamp(checked))").font(Typography.label).foregroundStyle(Palette.muted)
                    } else { Text("Sem verificação registrada").font(Typography.label).foregroundStyle(Palette.muted) }
                    if let source = followUp.source { Text("Origem: \(source)").font(Typography.small).foregroundStyle(Palette.muted).textSelection(.enabled) }
                    if let source = followUp.source, let url = URL(string: source),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                        Link("Ver origem", destination: url).font(Typography.label)
                    }
                    Text(followUp.resolved ? "Concluído" : "Em aberto").font(Typography.small).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .orbSheet(followUp.subject, subtitle: routine.name, size: .medium) {
                    SheetFooterBar {
                        Button("Ver rotina", systemImage: "clock.arrow.circlepath") {
                            dismiss()
                            model.inicioRoutineFocus = routine.id
                            model.selection = .routines
                        }.buttonStyle(GhostStyle())
                        Spacer()
                        Button("Fechar") { dismiss() }.buttonStyle(PrimaryPillStyle()).keyboardShortcut(.cancelAction)
                    }
                }
            } else {
                ContentUnavailableView("Este acompanhamento não está mais aqui", systemImage: "text.bubble")
                    .frame(width: 540, height: 300)
                    .overlay(alignment: .bottom) { Button("Fechar") { dismiss() }.padding() }
            }
        }
    }
}
