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
    /// "Em andamento" opened from its one-line form (shown that way while nothing waits for a decision).
    @State private var workingOpen = false
    /// Novidades narrowed to one Orb; nil shows them all.
    @State private var orbFilter: UUID?
    @State private var showingRecent = false
    @State private var unavailable: String?
    @State private var presentedEntries: [InicioEntry] = []
    @State private var readingBelowTop = false
    @State private var returningFocus: InicioRowFocus?
    @State private var scrollAnchor = InicioScrollAnchor()
    @FocusState private var focusedRowState: InicioRowFocus?
    @AccessibilityFocusState private var accessibilityFocusedRow: InicioRowFocus?
    @State private var inspectingApproval: UUID?

    private static let columnWidth: CGFloat = 860

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
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text("Início").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if !model.botIDs.isEmpty {
                            fleetSummary
                        }
                    }
                    Text(model.inicioVisitBase == nil ? "Resultados recentes dos seus Orbs" : "O que mudou desde sua última visita")
                        .font(Typography.text).foregroundStyle(Palette.muted)
                }
                if model.botIDs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "circle.hexagongrid")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Palette.hint)
                            .accessibilityHidden(true)
                        Text("Ainda não há Orbs").font(Typography.title).foregroundStyle(Palette.ink)
                        Text("Crie seu primeiro Orb para começar.").font(Typography.text).foregroundStyle(Palette.muted)
                        Button("Criar Orb") { model.selection = nil }.buttonStyle(PrimaryPillStyle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 52)
                } else {
                    attention
                        .transition(.opacity)
                    working
                        .transition(.opacity)
                    if !model.teams.isEmpty {
                        teamsOverview
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 0)
                        .background(InicioScrollAnchorBridge(anchor: scrollAnchor))
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("inicio-scroll")).minY } action: { scrollAnchor.observe(viewportY: $0) }
                    news
                    followUps
                        .transition(.opacity)
                }
            }
            // A column of reading width: on a wide window the time at a row's end would sit a screen away from its text.
            .frame(maxWidth: Self.columnWidth).frame(maxWidth: .infinity).padding(Spacing.page)
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
        // The page's own heading says it; a second "Início" in the title bar would repeat it.
        .navigationTitle("")
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
        focusedRowState = row
        accessibilityFocusedRow = row
    }

    @ViewBuilder private var fleetSummary: some View {
        let workingCount = model.workingIDs.count
        let pendingCount = model.pendingApprovals.count + flaggedRuns.count
        if workingCount > 0 || pendingCount > 0 {
            HStack(spacing: Spacing.s) {
                if pendingCount > 0 {
                    Label("\(pendingCount) \(pendingCount == 1 ? "pendência" : "pendências")", systemImage: "exclamationmark.circle")
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.warn)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.warn.opacity(0.12), in: .capsule)
                }
                if workingCount > 0 {
                    Label("\(workingCount) \(workingCount == 1 ? "ativo" : "ativos")", systemImage: "circle.dotted")
                        .font(Typography.small.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accent.opacity(0.14), in: .capsule)
                }
            }
        }
    }

    @ViewBuilder private var teamsOverview: some View {
        section("Times", count: model.teams.count, tone: .card) {
            ForEach(model.teams) { team in
                let progress = team.mission.progress
                HStack(spacing: 12) {
                    Button {
                        model.selection = .team(team.id)
                    } label: {
                        HStack(spacing: 10) {
                            StackedAvatars(members: team.members.map {
                                StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: $0.state.orbActivity)
                            }, size: 22, overlap: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(team.name)
                                    .font(Typography.text.weight(.medium))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Text(TeamRowText.subtitle(for: team))
                                    .font(Typography.small)
                                    .foregroundStyle(team.status == .waitingUser ? Palette.warn : Palette.faint)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if let summary = progress.stageSummary {
                                Text(summary)
                                    .font(Typography.small)
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if team.status.isWorking {
                        Button("Pausar") { model.pauseTeam(team.id) }
                            .buttonStyle(SecondaryPillStyle())
                            .controlSize(.small)
                    } else if team.status != .completed {
                        Button("Retomar") { model.startTeam(team.id) }
                            .buttonStyle(SecondaryPillStyle())
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private var attention: some View {
        let pending = model.pendingApprovals
        let flagged = flaggedRuns
        if !pending.isEmpty || !flagged.isEmpty {
            section("Precisa de você", count: pending.count + flagged.count, tone: .needsYou) {
                ForEach(pending) { item in
                    pendingApprovalRow(item)
                }
                ForEach(flagged, id: \.1.id) { routine, run in
                    row(botID: routine.botID, focus: .attention(run.id), title: run.summary, detail: "Resultado da rotina pede atenção", date: run.date) {
                        openRun(routine.id, run.id, from: .attention(run.id))
                    }
                }
            }
        }
    }

    private func pendingApprovalRow(_ item: PendingApproval) -> some View {
        let preview = ApprovalPreview.of(item.request).rows.first?.command
        let canRespondHere = item.request.question == nil && !item.request.isHandoff
        return HStack(alignment: .center, spacing: Spacing.m) {
            row(botID: item.bot.id, focus: .approval(item.request.id), title: item.request.title,
                detail: preview ?? "Aguardando sua resposta", codeDetail: preview != nil,
                showsChevron: !canRespondHere, date: nil) {
                openPending(item.bot.id, approval: item.request.id)
            }
            if canRespondHere {
                Button("Responder") { inspectingApproval = item.request.id }
                    .buttonStyle(SecondaryPillStyle())
                    .controlSize(.small)
                    .help("Ver o pedido e decidir sem sair do Início")
                    .popover(isPresented: Binding(get: { inspectingApproval == item.request.id },
                                                  set: { if !$0 { inspectingApproval = nil } }), arrowEdge: .leading) {
                        ApprovalCard(request: item.request, botID: item.bot.id)
                            .frame(minWidth: 320, maxWidth: 440)
                            .padding(Spacing.m)
                    }
            }
        }
    }

    /// The routines whose goal check asks for attention, each with the run that said so.
    private var flaggedRuns: [(Routine, RoutineRun)] {
        model.routines.compactMap { routine in
            guard routine.goal?.check?.status == .attention,
                  let run = routine.runs.first(where: { $0.check?.status == .attention }) else { return nil }
            return (routine, run)
        }
    }

    @ViewBuilder private var working: some View {
        if !model.workingIDs.isEmpty {
            // With nothing waiting on you, what runs is a line: the page leads with results, not with activity.
            if workingOpen || !model.pendingApprovals.isEmpty || !flaggedRuns.isEmpty {
                section("Em andamento", count: model.workingIDs.count) {
                    ForEach(model.workingIDs, id: \.self) { id in
                        row(botID: id, focus: .working(id), title: model.live(id).shownWork?.headline ?? "Trabalhando", detail: "Ver trabalho", date: nil) {
                            openWork(id)
                        }
                    }
                }
            } else {
                Button { workingOpen = true } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Em andamento").font(Typography.title).foregroundStyle(Palette.ink)
                        Text(Self.itemsLabel(model.workingIDs.count)).font(Typography.small).foregroundStyle(Palette.muted)
                        Spacer()
                        Image(systemName: "chevron.down").font(Typography.small).foregroundStyle(Palette.faint).accessibilityHidden(true)
                    }
                    .padding(Spacing.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: Radius.large, stroke: Palette.line)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Mostra o que os Orbs estão fazendo agora")
                .accessibilityLabel("Em andamento, \(Self.itemsLabel(model.workingIDs.count))")
                .accessibilityHint("Mostra o que os Orbs estão fazendo agora")
            }
        }
    }

    private static func itemsLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "item" : "itens")" }

    private var news: some View {
        let currentAttention = Set(flaggedRuns.map(\.1.id))
        let all = InicioNews.folded(events.filter { !currentAttention.contains($0.id) })
        // The filter lists the Orbs that have news, in the sidebar's order; a filter whose Orb has none left shows all again.
        let orbs = model.botIDs.filter { id in all.contains { $0.entry.botID == id } }
        let filter = orbFilter.flatMap { orbs.contains($0) ? $0 : nil }
        let news = filter.map { id in all.filter { $0.entry.botID == id } } ?? all
        let shown = showingAll ? news : Array(news.prefix(Self.newsAtRest))
        return section("Novidades", count: news.count, tone: .plain) {
            // The filter sits in the header, beside the count it changes, instead of on a row of its own above the list.
            if orbs.count > 1 {
                Menu(filter.flatMap { model.liveBot($0)?.look.name } ?? "Todos os Orbs") {
                    Button("Todos os Orbs") { orbFilter = nil }
                    Divider()
                    ForEach(orbs, id: \.self) { id in
                        Toggle(model.liveBot(id)?.look.name ?? "Orb indisponível", isOn: Binding(get: { filter == id }, set: { orbFilter = $0 ? id : nil }))
                    }
                }
                .menuStyle(.button).buttonStyle(GhostStyle()).controlSize(.small).fixedSize().hangsOnTrailingEdge()
                .help("Mostra as novidades de um Orb só")
            }
        } content: {
            if news.isEmpty {
                Text(model.inicioVisitBase == nil ? "Ainda não há resultados recentes." : "Nenhuma novidade desde sua última visita.")
                    .font(Typography.text).foregroundStyle(Palette.muted).padding(.vertical, 8)
                if !presentedEntries.isEmpty && !showingRecent {
                    Button("Ver resultados recentes") { showingRecent = true }.buttonStyle(GhostStyle())
                }
            } else {
                DayAware { now in
                    let days = InicioDays.group(shown, now: now)
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        ForEach(days) { day in
                            Text(day.title).font(Typography.label.weight(.semibold)).foregroundStyle(Palette.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, day.id == days.first?.id ? Spacing.xs : Spacing.m)
                            ForEach(day.items) { item in
                                eventRow(item)
                                if item.id != day.items.last?.id { Divider().padding(.leading, 42) }
                            }
                        }
                    }
                }
                if news.count > Self.newsAtRest {
                    Button(showingAll ? "Mostrar menos" : InicioDays.moreLabel(hidden: news.count - Self.newsAtRest)) { showingAll.toggle() }
                        .buttonStyle(LinkTextStyle())
                }
            }
            if showingRecent { Button("Voltar às novidades") { showingRecent = false }.buttonStyle(GhostStyle()) }
        }
    }

    private static let newsAtRest = 5

    @ViewBuilder private var followUps: some View {
        // Orb by Orb, its avatar and name once over its run of items: one Orb may keep dozens.
        let items = model.botIDs.flatMap { bot in
            model.routines.filter { $0.botID == bot }.flatMap { routine in routine.followUps.filter { !$0.resolved }.map { (routine, $0) } }
        }
        if !items.isEmpty {
            section("Acompanhamentos", count: items.count) {
                ForEach(Array(items.enumerated()), id: \.element.1.id) { index, pair in
                    let (routine, item) = pair
                    row(botID: routine.botID, focus: .followUp(item.id), title: item.subject, showsOrb: index == 0 || items[index - 1].0.botID != routine.botID,
                        detail: item.nextStep, badge: item.channel,
                        status: item.lastChecked.map { "Verificado " + RoutineText.stamp($0) } ?? "Sem verificação registrada", date: nil) {
                        guard model.routines.contains(where: { $0.id == routine.id && $0.followUps.contains(where: { $0.id == item.id }) }) else {
                            unavailable = "Este acompanhamento não está mais disponível."; return
                        }
                        present(.followUp(routine.id, item.id), from: .followUp(item.id))
                    }
                }
            }
        }
    }

    private func eventRow(_ news: InicioNews) -> some View {
        let event = news.entry
        return row(botID: event.botID, focus: .news(event.id), title: event.summary.isEmpty ? "Resultado registrado" : event.summary,
                   detail: outcome(event.outcome) + (news.runs > 1 ? " · a última de \(news.runs) rodadas" : ""), date: event.date) { open(event) }
    }

    private enum SectionTone { case card, needsYou, plain }

    /// `needsYou`: a warm outline and the count in a pill, because these block an Orb. `plain`: no card, the rows are
    /// told apart by dividers (the history is read, not decided).
    private func section<Content: View>(_ title: String, count: Int, tone: SectionTone = .card, @ViewBuilder content: () -> Content) -> some View {
        section(title, count: count, tone: tone, accessory: { EmptyView() }, content: content)
    }

    /// `accessory` ends the header row, after the count (the Novidades' filter by Orb).
    private func section<Accessory: View, Content: View>(_ title: String, count: Int, tone: SectionTone = .card,
                                                         @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        let body = VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Text(title).font(Typography.title).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Spacer()
                if count > 0 {
                    let label = Text(Self.itemsLabel(count)).font(Typography.small)
                    if tone == .needsYou {
                        label.foregroundStyle(Palette.warn).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.warn.opacity(0.14)))
                    } else {
                        label.foregroundStyle(Palette.muted)
                    }
                }
                accessory()
            }
            Divider()
            content()
        }
        return Group {
            if tone == .plain {
                body.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                body.padding(Spacing.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: Radius.large, stroke: tone == .needsYou ? Palette.warn : Palette.line)
            }
        }
    }

    private func row(botID: UUID, focus: InicioRowFocus, title: String, showsOrb: Bool = true, detail: String, codeDetail: Bool = false, badge: String? = nil, status: String? = nil, showsChevron: Bool = true, date: Date?,
                     action: @escaping () -> Void) -> some View {
        let look = showsOrb ? model.liveBot(botID)?.look : nil
        return HStack(alignment: .center, spacing: 10) {
            if !showsOrb {
                Color.clear.frame(width: 32, height: 1) // under the avatar of the row that opens the Orb's run
            } else if let look {
                Button { model.selection = .bot(botID) } label: {
                    BotAvatar(orb: look.orb, size: 32, animated: false)
                }.buttonStyle(.plain).help("Abrir conversa de \(look.name)").accessibilityLabel("Abrir conversa de \(look.name)")
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in model.selection = .bot(botID); return .handled }
            }
            VStack(alignment: .leading, spacing: 3) {
                if showsOrb, let look {
                    Button(look.name) { model.selection = .bot(botID) }
                        .buttonStyle(.plain).font(Typography.small.weight(.semibold)).foregroundStyle(Palette.secondary)
                        .help("Abrir conversa de \(look.name)")
                        .focusable()
                        .onKeyPress(keys: [.return, .space]) { _ in model.selection = .bot(botID); return .handled }
                } else if showsOrb {
                    Text("Orb indisponível").font(Typography.small.weight(.semibold)).foregroundStyle(Palette.secondary)
                }
                Button(action: action) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                        // Summaries come from the Orbs in Markdown: drawn as the chat draws them, from its cache.
                        Text(MarkdownCache.attributed(title)).font(Typography.text).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                            .help(title)
                        if let badge {
                            // The channel as a pill ahead of the step, the check on its own line below.
                            HStack(spacing: 6) {
                                CatalogBadge(text: badge)
                                Text(MarkdownCache.attributed(detail)).font(Typography.small).foregroundStyle(Palette.muted).lineLimit(1).help(detail)
                            }
                        } else if codeDetail {
                            Text(detail).font(Typography.codeSmall).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle).help(detail)
                        } else {
                            Text(MarkdownCache.attributed(detail)).font(Typography.small).foregroundStyle(Palette.muted).lineLimit(1).multilineTextAlignment(.leading).help(detail)
                        }
                        if let status { Text(status).font(Typography.small).foregroundStyle(Palette.muted).lineLimit(1).help(status) }
                        }
                        Spacer(minLength: 4)
                        if let date { DayAware { now in Text(ReplyTime.label(date, now: now)).font(Typography.small).foregroundStyle(Palette.muted) } }
                        if showsChevron { Image(systemName: "chevron.right").font(Typography.small).foregroundStyle(Palette.faint) }
                    }.contentShape(.rect)
                }.buttonStyle(.plain)
                    .focusable()
                    .focused($focusedRowState, equals: focus)
                    .accessibilityFocused($accessibilityFocusedRow, equals: focus)
                    .onKeyPress(keys: [.return, .space]) { _ in action(); return .handled }
            }
        }
        .padding(.vertical, 6)
    }

    private func outcome(_ outcome: InicioEntry.Outcome) -> String {
        switch outcome {
        case .completed: "Concluído"
        case .failed: "Não terminou"
        case .attention: "Pede atenção"
        case .skipped: "Pulada" // by the precheck or a missed slot: the summary says which
        case .recorded: "Resultado anterior"
        }
    }

    private func open(_ event: InicioEntry) {
        switch event.origin {
        case .chat(let bot, let chat, let item), .pulse(let bot, let chat, let item):
            if !model.openInicioChat(bot: bot, chat: chat, item: item) { unavailable = "A conversa de origem não está mais disponível." }
        case .routine(let bot, let routine, let run):
            guard model.routines.contains(where: { $0.id == routine && $0.botID == bot }) else {
                unavailable = "A rotina de origem não está mais disponível."; return
            }
            openRun(routine, run, from: .news(event.id))
        }
    }

    private func openRun(_ routine: UUID, _ run: UUID, from focus: InicioRowFocus) {
        guard model.routines.contains(where: { $0.id == routine && $0.runs.contains(where: { $0.id == run }) }) else {
            unavailable = "Esta execução não está mais no histórico da rotina."; return
        }
        present(.run(routine, run), from: focus)
    }

    private func openWork(_ botID: UUID) {
        let gone = "Este trabalho não está mais em andamento."
        guard let session = model.sessions[botID] else { unavailable = gone; return }
        if session.sideKind == nil || session.sideKind == .routine, let routine = session.routineID {
            guard model.routines.contains(where: { $0.id == routine && $0.botID == botID }) else { unavailable = gone; return }
            present(.conversation(routine), from: .working(botID))
        } else if session.routineID == nil && session.sideKind == nil {
            let chat = session.workingChatID ?? session.chatID
            if model.live(botID).chats == nil { model.selection = .bot(botID) } else { model.openChat(chat, of: botID) }
        } else if session.sideKind == .pulse {
            model.selection = .bot(botID) // the chat narrates the pulse while it runs
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
        switch model.openPending(botID, approval: approval) {
        case .opened: break
        case .answered: unavailable = "Este pedido já não está aguardando resposta."
        case .chatGone: unavailable = "A conversa deste pedido não está mais disponível."
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(followUp.nextStep).font(Typography.text).foregroundStyle(Palette.ink)
                        Text("Canal: \(followUp.channel)").font(Typography.label).foregroundStyle(Palette.secondary)
                        if let action = followUp.lastAction { Text("Última ação: \(action)").font(Typography.label).foregroundStyle(Palette.secondary) }
                        if let checked = followUp.lastChecked {
                            Text("Última verificação: \(RoutineText.stamp(checked))").font(Typography.label).foregroundStyle(Palette.muted)
                        } else { Text("Sem verificação registrada").font(Typography.label).foregroundStyle(Palette.muted) }
                        if let source = followUp.source {
                            Text("Origem: \(source)").font(Typography.small).foregroundStyle(Palette.muted).textSelection(.enabled)
                            if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                                Link("Ver origem", destination: url).font(Typography.label)
                            }
                        }
                        Text(followUp.resolved ? "Concluído" : "Em aberto").font(Typography.small).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sheetEdge)
                }
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
                    .overlay(alignment: .bottom) {
                        Button("Fechar") { dismiss() }
                            .buttonStyle(PrimaryPillStyle())
                            .keyboardShortcut(.cancelAction)
                            .padding()
                    }
            }
        }
    }
}
