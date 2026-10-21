import AppKit
import Foundation
import Testing
@testable import Orb

// The live screen's interface (docs/TELA-AO-VIVO.md, 3): which state the card is in, the words of the card and its closing
// line, where the Orb's pointer lands, the item the transcript keeps for a use of the browser, how it folds, and the layer
// that draws the page (what it registers for, what it draws, what it lets go of).

// MARK: - Pure logic

@Suite("Tela ao vivo: estados e textos")
struct LiveScreenLogicTests {
    private typealias State = LiveCardState

    private func state(_ outcome: BrowserViewItem.Outcome = .running, phase: LiveFrameStore.Phase = .live, isProtected: Bool = false,
                       isPrivate: Bool = false, handoff: Bool = false) -> State {
        State.of(outcome: outcome, phase: phase, isProtected: isProtected, isPrivate: isPrivate, handoff: handoff)
    }

    @Test func aUseThatEndedIsALineNotACard() {
        for outcome in [BrowserViewItem.Outcome.done, .failed, .stopped] {
            #expect(state(outcome, isProtected: true, handoff: true) == .ended)
        }
    }

    @Test func theStateFollowsWhatIsMostUrgent() {
        #expect(state() == .live)
        #expect(state(phase: .connecting) == .connecting)
        #expect(state(phase: .idle) == .connecting)
        #expect(state(phase: .paused) == .paused)
        #expect(state(phase: .failed) == .failed)
        #expect(state(isPrivate: true) == .privateView)
        #expect(state(isProtected: true, isPrivate: true) == .protected, "a protected page is not the person's to show")
        #expect(state(phase: .failed, isPrivate: true) == .failed)
        #expect(state(phase: .failed, isProtected: true, handoff: true) == .needsYou, "a hand-off wins over everything")
        #expect(state(phase: .idle, handoff: true) == .needsYou)
    }

    @Test func aPageThatMustNotBeSeenIsNeverDrawn() {
        #expect(State.needsYou.veil == .opaque && !State.needsYou.showsFrames)
        #expect(State.protected.veil == .opaque && !State.protected.showsFrames)
        #expect(State.privateView.veil == .blur && State.privateView.showsFrames, "blurred by the layer, not left out")
        #expect(State.live.veil == .none && State.live.showsFrames)
    }

    @Test func eachStateHasItsOwnButtons() {
        #expect(State.live.buttons == [.enlarge, .stop, .hide])
        #expect(State.connecting.buttons == [.enlarge, .stop, .hide])
        #expect(State.needsYou.buttons == [.done, .cancel])
        #expect(State.protected.buttons == [.enlarge])
        #expect(State.privateView.buttons == [.reveal, .stop])
        #expect(State.paused.buttons == [.enlarge, .stop])
        #expect(State.failed.buttons.isEmpty && State.ended.buttons.isEmpty)
    }

    @Test func onlyTheLiveStatesPulseShimmerAndShowThePointer() {
        #expect(State.live.pulses && State.live.shimmers && State.live.showsPointer)
        #expect(!State.needsYou.pulses && !State.needsYou.shimmers && !State.needsYou.showsPointer)
        #expect(!State.failed.shimmers && !State.paused.pulses)
        #expect(State.failed.dimsPage && State.paused.dimsPage && !State.live.dimsPage)
        #expect(State.live.chip == "Ao vivo" && State.needsYou.chip == "Precisa de você")
        #expect(State.protected.chip == nil && State.failed.chip == nil)
    }

    @Test func aThumbnailOpensTheLargerViewExceptWhereThereIsNothingToOpen() {
        #expect(State.live.enlarges && State.protected.enlarges && State.privateView.enlarges)
        #expect(!State.failed.enlarges && !State.needsYou.enlarges && !State.ended.enlarges)
    }

    // MARK: Words

    @Test func hostAndPathComeFromTheAddress() {
        #expect(LiveScreenText.host(of: "https://www.checkout.acessosfit.com.br/pagamentos?id=7") == "checkout.acessosfit.com.br")
        #expect(LiveScreenText.host(of: "about:blank") == nil)
        #expect(LiveScreenText.host(of: nil) == nil)
        #expect(LiveScreenText.path(of: "https://x.com/pagamentos?token=abc#top") == "/pagamentos", "never the query")
        #expect(LiveScreenText.path(of: "https://x.com") == "/")
        #expect(LiveScreenText.path(of: "about:blank") == nil)
        let long = "https://x.com/" + String(repeating: "a", count: 80)
        #expect(LiveScreenText.path(of: long)!.count <= 40 && LiveScreenText.path(of: long)!.contains("…"))
    }

    @Test func durationAndActionsAreShort() {
        #expect(LiveScreenText.duration(0) == "0 s")
        #expect(LiveScreenText.duration(45) == "45 s")
        #expect(LiveScreenText.duration(120) == "2 min")
        #expect(LiveScreenText.duration(3_900) == "1 h 05 min")
        #expect(LiveScreenText.actions(1) == "1 ação")
        #expect(LiveScreenText.actions(14) == "14 ações")
    }

    @Test func theClosingLineSaysWhatWasDone() {
        let start = Date(timeIntervalSince1970: 1_000)
        var view = BrowserViewItem(host: "checkout.acessosfit", lastPath: "/pagamentos", startedAt: start,
                                   endedAt: start.addingTimeInterval(120), actions: 14, outcome: .done)
        #expect(LiveScreenText.closingLine(view)
                == "Usou o navegador · checkout.acessosfit · 2 min · 14 ações · terminou em /pagamentos")
        view.outcome = .stopped
        #expect(LiveScreenText.closingLine(view).hasSuffix("parou em /pagamentos"))
        view.outcome = .failed
        #expect(LiveScreenText.closingLine(view).hasSuffix("falhou em /pagamentos"))
    }

    @Test func theClosingLineLeavesOutWhatIsNotKnown() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(LiveScreenText.closingLine(BrowserViewItem(startedAt: start, endedAt: start.addingTimeInterval(30), outcome: .done))
                == "Usou o navegador · 30 s")
        #expect(LiveScreenText.closingLine(BrowserViewItem(host: "a.com", startedAt: start, actions: 1, outcome: .stopped))
                == "Usou o navegador · a.com · 1 ação", "a use cut by a crash has no end")
    }

    @Test func aHandoffNamesWhatThePersonHasToDo() {
        let login = "https://github.com/login — “Sign in to GitHub”"
        #expect(LiveScreenText.handoffVeil(page: login) == "Página de login")
        #expect(LiveScreenText.handoffCaption(page: login).contains("Entre na sua conta"))
        #expect(LiveScreenText.handoffVeil(page: "https://x.com/y — “Just a moment…”") == "Verificação")
        #expect(LiveScreenText.handoffVeil(page: "https://x.com/y — “Enter your verification code”") == "Código de verificação")
        #expect(LiveScreenText.handoffVeil(page: "https://x.com/y") == "Precisa de você")
        #expect(!LiveScreenText.handoffCaption(page: "").isEmpty)
    }

    @Test func theCaptionFollowsTheState() {
        func caption(_ state: State, work: String? = "Clicando em Pagamentos", last: String? = nil) -> String {
            LiveScreenText.caption(for: state, work: work, handoffPage: nil, lastAction: last)
        }
        #expect(caption(.live) == "Clicando em Pagamentos")
        #expect(caption(.connecting, work: nil) == "Abrindo o navegador…")
        #expect(caption(.protected) == "Conteúdo protegido")
        #expect(caption(.failed) == "O navegador fechou")
        #expect(caption(.failed, last: "Clicando em Pagamentos") == "O navegador fechou · última ação: Clicando em Pagamentos")
        #expect(LiveScreenText.spoken(caption: "Clicando em Pagamentos") == "Tela ao vivo, navegador, Clicando em Pagamentos")
    }

    @Test func voiceOverIsToldOnlyOfTheChangesThatMatter() {
        #expect(LiveScreenText.announcement(for: .needsYou) != nil)
        #expect(LiveScreenText.announcement(for: .failed) != nil)
        #expect(LiveScreenText.announcement(for: .live) == nil, "the working steps are not announced here")
    }

    // MARK: The pointer

    @Test func theBoxBecomesAPointOnTheLayer() {
        // A 1280 x 800 page drawn at 640 x 400 fills a 160 x 100 layer exactly: a quarter of the page, in CSS pixels.
        let point = LiveCursor.point(of: CGRect(x: 100, y: 200, width: 200, height: 40), viewport: CGSize(width: 1280, height: 800),
                                     scroll: .zero, imageSize: CGSize(width: 640, height: 400), layerSize: CGSize(width: 160, height: 100))
        #expect(point == CGPoint(x: 25, y: 27.5))
    }

    @Test func theScrollOfThePictureIsTakenOff() {
        let point = LiveCursor.point(of: CGRect(x: 100, y: 1_000, width: 200, height: 40), viewport: CGSize(width: 1280, height: 800),
                                     scroll: CGPoint(x: 0, y: 800), imageSize: CGSize(width: 640, height: 400),
                                     layerSize: CGSize(width: 160, height: 100))
        #expect(point == CGPoint(x: 25, y: 27.5))
    }

    @Test func aPictureThatFillsTheLayerIsCroppedAroundItsMiddle() {
        // The same page in a layer twice as wide as it is tall (200 x 100): scaled to the width, 25 pt cut off top and bottom.
        let point = LiveCursor.point(of: CGRect(x: 600, y: 380, width: 80, height: 40), viewport: CGSize(width: 1280, height: 800),
                                     scroll: .zero, imageSize: CGSize(width: 640, height: 400), layerSize: CGSize(width: 200, height: 100))
        #expect(point == CGPoint(x: 100, y: 50))
    }

    @Test func aBoxOutsideThePageStopsAtTheEdgeAndNoViewportGivesNothing() {
        let image = CGSize(width: 640, height: 400), layer = CGSize(width: 160, height: 100)
        let outside = LiveCursor.point(of: CGRect(x: 5_000, y: -300, width: 10, height: 10), viewport: CGSize(width: 1280, height: 800),
                                       scroll: .zero, imageSize: image, layerSize: layer)
        #expect(outside == CGPoint(x: 160, y: 0))
        #expect(LiveCursor.point(of: .zero, viewport: .zero, scroll: .zero, imageSize: image, layerSize: layer) == nil)
    }

    // MARK: The setting

    @Test func theSettingIsOnUnlessTheyTurnedItOff() {
        let name = "LiveScreenSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LiveScreenSetting.isOn(defaults))
        defaults.set(false, forKey: LiveScreenSetting.key)
        #expect(!LiveScreenSetting.isOn(defaults))
        defaults.set(true, forKey: LiveScreenSetting.key)
        #expect(LiveScreenSetting.isOn(defaults))
    }
}

// MARK: - The item in the transcript

@Suite("Tela ao vivo: item da conversa", .serialized)
final class LiveScreenItemTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbLiveScreen-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    init() { QuietNotifications.hold() } // no banner from the test process

    @MainActor private func model() -> AppModel {
        AppModel(store: Store(directory: root), runsBackgroundWork: false)
    }

    private func browse(_ title: String, _ detail: String = "") -> ToolCall { ToolCall(kind: .browser, title: title, detail: detail) }
    private func shell() -> ToolCall { ToolCall(kind: .shell, title: "Rodando no Terminal", detail: "ls") }

    /// A running turn that does nothing (the tests play its events and end it by hand).
    @MainActor private func running(_ model: AppModel) -> (id: UUID, turn: UUID, session: BotSession) {
        let id = model.bots[0].id
        let session = model.session(id)
        let turn = session.beginTurn()
        session.turnTask = Task { try? await Task.sleep(for: .seconds(30)) }
        model.setStatus("Pensando", of: id)
        return (id, turn, session)
    }

    @MainActor private func views(_ session: BotSession) -> [BrowserViewItem] {
        (session.conversation?.items ?? []).compactMap { if case .browserView(let view) = $0.kind { view } else { nil } }
    }

    @MainActor private func order(_ session: BotSession) -> [String] {
        (session.conversation?.items ?? []).map {
            switch $0.kind {
            case .browserView: "view"
            case .tool(let call): call.title
            default: "other"
            }
        }
    }

    @Test @MainActor func theFirstBrowserToolOpensOneItemAboveItsLine() {
        let model = model()
        let (id, _, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://www.checkout.acessosfit.com.br/pagamentos")), to: id)
        #expect(order(session) == ["view", "Abrindo página"])
        let view = views(session)[0]
        #expect(view.outcome == .running && view.actions == 1)
        #expect(view.host == "checkout.acessosfit.com.br", "the host of the page it opened, only the host")
        #expect(session.browserViewID != nil)
    }

    @Test @MainActor func theItemIsMadeOnceAndCountsEachBrowserAction() {
        let model = model()
        let (id, _, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com/x")), to: id)
        let itemID = session.browserViewID
        model.apply(.toolStarted(shell()), to: id)
        model.apply(.toolStarted(browse("Clicando em Salvar")), to: id)
        model.apply(.toolStarted(browse("Olhando a página")), to: id)
        #expect(views(session).count == 1 && views(session)[0].actions == 3, "shell does not count")
        #expect(session.browserViewID == itemID)
        #expect(order(session) == ["view", "Abrindo página", "Rodando no Terminal", "Clicando em Salvar", "Olhando a página"])
    }

    @Test @MainActor func aShellOnlyTurnGetsNoItem() {
        let model = model()
        let (id, _, session) = running(model)
        model.apply(.toolStarted(shell()), to: id)
        #expect(views(session).isEmpty && session.browserViewID == nil)
    }

    @Test @MainActor func theToolThatReadsThePersonsOwnBrowserIsNotTheOrbs() {
        let model = model()
        let (id, _, session) = running(model)
        model.apply(.toolStarted(browse(LiveScreenBrowser.readTabTitle, "Safari")), to: id)
        model.apply(.toolStarted(browse(LiveScreenBrowser.closeTitle)), to: id)
        #expect(views(session).isEmpty, "no page of those streams, and closing a browser that was not open opens no card")
    }

    @Test @MainActor func theHostIsTheStreamsWhenItKnowsIt() {
        let model = model()
        let (id, _, session) = running(model)
        model.liveScreens.store(id).setURL("https://painel.exemplo.com/entrar")
        model.apply(.toolStarted(browse("Clicando em Entrar")), to: id)
        #expect(views(session)[0].host == "painel.exemplo.com")
    }

    @Test @MainActor func aSuccessfulTurnClosesItAsDoneWithTheLastPath() {
        let model = model()
        let (id, turn, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com/x")), to: id)
        model.liveScreens.store(id).setURL("https://a.com/pagamentos?token=segredo")
        model.apply(.toolStarted(browse("Clicando em Pagamentos")), to: id)
        model.finishTurn(id, turn: turn)
        let view = views(session)[0]
        #expect(view.outcome == .done && view.endedAt != nil)
        #expect(view.lastPath == "/pagamentos", "no query: it may carry a token")
        #expect(view.actions == 2 && session.browserViewID == nil)
    }

    @Test @MainActor func aFailedTurnClosesItAsFailed() {
        let model = model()
        let (id, turn, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com")), to: id)
        model.apply(.failed("sem rede"), to: id)
        model.finishTurn(id, turn: turn, succeeded: false)
        #expect(views(session)[0].outcome == .failed)
    }

    @Test @MainActor func stoppingClosesItAsStopped() {
        let model = model()
        let (id, _, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com")), to: id)
        model.stop(id)
        let view = views(session)[0]
        #expect(view.outcome == .stopped && view.endedAt != nil && session.browserViewID == nil)
    }

    @Test @MainActor func aNewTurnOpensANewItem() {
        let model = model()
        let (id, first, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com")), to: id)
        model.finishTurn(id, turn: first)
        let second = session.beginTurn()
        session.turnTask = Task { try? await Task.sleep(for: .seconds(30)) }
        model.apply(.toolStarted(browse("Abrindo página", "https://b.com")), to: id)
        model.finishTurn(id, turn: second)
        #expect(views(session).map(\.host) == ["a.com", "b.com"] && views(session).allSatisfy { $0.outcome == .done })
    }

    @Test func aCrashInTheMiddleClosesItAsStopped() {
        let start = Date(timeIntervalSince1970: 1_000)
        var running = TranscriptItem(.browserView(BrowserViewItem(host: "a.com", startedAt: start, actions: 3)))
        running.date = start
        var last = TranscriptItem(.tool(ToolCall(kind: .browser, title: "Clicando", detail: "", state: .done)))
        last.date = start.addingTimeInterval(90)
        let conversation = Conversation(items: [TranscriptItem(.user(text: "oi", attachments: [])), running, last])
        let closed = conversation.closingInterruptedTurn(notice: BotSession.quitNotice)
        guard case .browserView(let view) = closed.items[1].kind else { Issue.record("o item sumiu"); return }
        #expect(view.outcome == .stopped && view.endedAt == start.addingTimeInterval(90))
        #expect(view.actions == 3)
    }

    @Test func aFinishedItemSurvivesTheCrashHandlingUntouched() {
        let start = Date(timeIntervalSince1970: 1_000)
        let done = BrowserViewItem(host: "a.com", startedAt: start, endedAt: start.addingTimeInterval(5), actions: 2, outcome: .done)
        let conversation = Conversation(items: [TranscriptItem(.browserView(done))])
        let closed = conversation.closingInterruptedTurn()
        guard case .browserView(let view) = closed.items[0].kind else { Issue.record("o item sumiu"); return }
        #expect(view == done)
    }

    @Test @MainActor func withTheSettingOffNoItemIsMade() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: LiveScreenSetting.key)
        defaults.set(false, forKey: LiveScreenSetting.key)
        defer { if let before { defaults.set(before, forKey: LiveScreenSetting.key) } else { defaults.removeObject(forKey: LiveScreenSetting.key) } }
        let model = model()
        let (id, turn, session) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com")), to: id)
        model.apply(.toolStarted(browse("Clicando em Salvar")), to: id)
        model.finishTurn(id, turn: turn)
        #expect(views(session).isEmpty && session.browserViewID == nil)
        #expect(order(session) == ["Abrindo página", "Clicando em Salvar"], "the lines of the tools stay as they were")
    }

    @Test func theItemIsKeptAsWordsAndComesBackFromTheDisk() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let item = BrowserViewItem(host: "a.com", lastPath: "/x", startedAt: start, endedAt: start.addingTimeInterval(60), actions: 4, outcome: .done)
        let data = try JSONEncoder().encode(Conversation(items: [TranscriptItem(.browserView(item))]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("jpeg") && !text.contains("image"), "no picture is ever written")
        let back = try JSONDecoder().decode(Conversation.self, from: data)
        guard case .browserView(let view) = back.items[0].kind else { Issue.record("o item sumiu"); return }
        #expect(view == item)
    }

    // MARK: The hand-off

    @Test @MainActor func theLiveCardStandsForTheHandoffOnlyWhileTheTurnHasOne() {
        let model = model()
        let (id, _, _) = running(model)
        #expect(!model.liveCardDrawsHandoff(of: id))
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com/login")), to: id)
        #expect(model.liveCardDrawsHandoff(of: id))
        model.stop(id)
        #expect(!model.liveCardDrawsHandoff(of: id))
    }

    @Test @MainActor func aPendingHandoffIsFoundOnlyWhileTheOrbWaits() {
        let model = model()
        let (id, _, _) = running(model)
        model.apply(.toolStarted(browse("Abrindo página", "https://a.com/login")), to: id)
        #expect(model.pendingHandoff(of: id) == nil)
        let request = ApprovalRequest.handoff(botName: "Atlas", page: "https://a.com/login — “Entrar”")
        model.apply(.approval(request), to: id)
        #expect(model.pendingHandoff(of: id)?.id == request.id)
        model.decide(.once, approvalID: request.id, botID: id)
        #expect(model.pendingHandoff(of: id) == nil, "answered: the usual line again")
    }

    @Test @MainActor func anotherKindOfCardIsNotAHandoff() {
        let model = model()
        let (id, _, _) = running(model)
        model.apply(.approval(ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "ls", reason: "")), to: id)
        #expect(model.pendingHandoff(of: id) == nil)
    }
}

// MARK: - Folding

@MainActor
@Suite("Tela ao vivo: dobras")
struct LiveScreenFoldingTests {
    private func item(_ kind: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(kind) }
    private func tool(_ title: String = "Rodando no Terminal") -> TranscriptItem {
        item(.tool(ToolCall(kind: .shell, title: title, detail: "ls", state: .done)))
    }
    private var user: TranscriptItem { item(.user(text: "faz", attachments: [])) }
    private func say(_ text: String) -> TranscriptItem { item(.bot(text: text, isStreaming: false)) }
    private var card: TranscriptItem { item(.browserView(BrowserViewItem(host: "a.com", actions: 2))) }

    @Test func theCardDoesNotJoinARunOfActions() {
        let rows = TranscriptFolding.rows(for: [user, tool(), tool(), card, tool(), tool()], liveTail: true)
        let kinds = rows.map { row -> String in
            switch row {
            case .tools(let items): "tools\(items.count)"
            case .single(let item): if case .browserView = item.kind { "view" } else { "single" }
            default: "other"
            }
        }
        #expect(kinds == ["single", "tools2", "view", "tools2"])
    }

    @Test func aFinishedRequestFoldsItsWorkAndLeavesTheItemRightAfter() {
        let items = [user, say("vou ver"), tool(), tool(), card, tool(), say("pronto")]
        let rows = TranscriptFolding.rows(for: items)
        guard case .work(let inside, _) = rows[1] else { Issue.record("o trabalho não dobrou: \(rows)"); return }
        #expect(!inside.contains { if case .browserView = $0.kind { true } else { false } }, "not counted in 'Rodou N comandos'")
        guard case .single(let after) = rows[2], case .browserView = after.kind else { Issue.record("o item não vem logo depois"); return }
        #expect(rows.count == 4)
    }

    @Test func whileTheTurnRunsNothingFolds() {
        let items = [user, say("vou ver"), tool(), tool(), card, tool()]
        let rows = TranscriptFolding.rows(for: items, liveTail: true)
        #expect(!rows.contains { if case .work = $0 { true } else { false } })
    }

    @Test func theItemIsNotAMessageForTheModelsContext() {
        // It carries no text anyone could search or remember (see `ConversationSearch`).
        #expect(ReplyAvatars.quietReplies(in: [say("a"), card, say("b")]).count == 1, "it does not cut a run of replies")
    }
}

// MARK: - The layer that draws the page

@MainActor
@Suite("Tela ao vivo: camada da página", .serialized)
final class LiveScreenLayerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbLiveLayer-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    private func model() -> AppModel { AppModel(store: Store(directory: root), runsBackgroundWork: false) }

    private func image(_ width: Int = 64, _ height: Int = 40) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func frame(stale: Bool = false) -> LiveFrame {
        LiveFrame(image: image(), viewport: CGSize(width: 1280, height: 800), scroll: .zero, timestamp: .now, isStale: stale)
    }

    /// A layer view in a window nobody sees; `visible` says whether it counts as on screen.
    private func layerView(_ model: AppModel, visible: Bool = true) -> (LiveScreenLayerView, NSWindow, UUID) {
        let id = model.bots[0].id
        let view = LiveScreenLayerView(hub: model.liveScreens, botID: id, wide: false, pointerColor: .systemBlue)
        view.visibilityForTests = visible
        view.frame = NSRect(x: 0, y: 0, width: 115, height: 72)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [], backing: .buffered, defer: true)
        window.contentView = view
        return (view, window, id)
    }

    @Test func onScreenItRegistersAndAcquiresAndDrawsTheLastFrameAtOnce() {
        let model = model()
        let id = model.bots[0].id
        model.liveScreens.store(id).deliver(frame())
        let (view, window, _) = layerView(model)
        #expect(view.isObservingFrames && view.isStreamAcquired)
        #expect(view.isShowingFrame, "the frame the store already had")
        withExtendedLifetime(window) {}
    }

    @Test func aNewFrameSwapsTheContentsWithoutAnyViewUpdate() {
        let model = model()
        let (view, window, id) = layerView(model)
        #expect(!view.isShowingFrame)
        model.liveScreens.store(id).deliver(frame())
        #expect(view.isShowingFrame && view.pageOpacity == 1)
        model.liveScreens.store(id).deliver(frame(stale: true))
        #expect(view.pageOpacity == LiveScreenLayerView.dimmedOpacity, "the replayed frame is dimmed until a new one comes")
        withExtendedLifetime(window) {}
    }

    @Test func offScreenItListensToNothingAndHoldsNothing() {
        let model = model()
        let (view, window, id) = layerView(model, visible: false)
        #expect(!view.isObservingFrames && !view.isStreamAcquired)
        model.liveScreens.store(id).deliver(frame())
        #expect(!view.isShowingFrame)
        view.visibilityForTests = true
        view.refresh()
        #expect(view.isObservingFrames && view.isStreamAcquired && view.isShowingFrame)
        view.visibilityForTests = false // the window was minimized or covered
        view.refresh()
        #expect(!view.isObservingFrames && !view.isStreamAcquired)
        withExtendedLifetime(window) {}
    }

    @Test func leavingTheWindowOrTheScreenLetsGoOfEverything() {
        let model = model()
        let (view, window, _) = layerView(model)
        #expect(view.isStreamAcquired)
        view.removeFromSuperview()
        #expect(!view.isObservingFrames && !view.isStreamAcquired)
        window.contentView = view
        #expect(view.isStreamAcquired)
        view.detach()
        #expect(!view.isObservingFrames && !view.isStreamAcquired)
    }

    @Test func aPageThatMustNotBeSeenIsLetGoNotJustCovered() {
        let model = model()
        let (view, window, id) = layerView(model)
        model.liveScreens.store(id).deliver(frame())
        #expect(view.isShowingFrame)
        view.showsPage = false
        #expect(!view.isShowingFrame)
        model.liveScreens.store(id).deliver(frame())
        #expect(!view.isShowingFrame, "frames that arrive meanwhile are not drawn")
        view.showsPage = true
        #expect(view.isShowingFrame, "and it comes back with the last one")
        withExtendedLifetime(window) {}
    }

    @Test func thePrivateViewIsBlurredByTheLayerAndNeverFailsOpen() {
        let model = model()
        let (view, window, id) = layerView(model)
        model.liveScreens.store(id).deliver(frame())
        view.isBlurred = true
        #expect(view.hasBlurFilter && view.isShowingFrame)
        view.isBlurred = false
        #expect(!view.hasBlurFilter)
        withExtendedLifetime(window) {}
    }

    @Test func thePointerFollowsTheOrbAndHidesWhereThePageDoes() {
        let model = model()
        let (view, window, id) = layerView(model)
        let store = model.liveScreens.store(id)
        store.point(LivePointer(rect: CGRect(x: 10, y: 10, width: 20, height: 20), kind: .click))
        #expect(!view.isPointerVisible, "no picture yet to place it on")
        store.deliver(frame())
        store.point(LivePointer(rect: CGRect(x: 600, y: 300, width: 40, height: 20), kind: .click))
        #expect(view.isPointerVisible)
        view.showsPointer = false
        #expect(!view.isPointerVisible)
        view.showsPointer = true
        #expect(view.isPointerVisible)
        view.isBlurred = true
        #expect(!view.isPointerVisible, "the pointer would give the page away")
        view.isBlurred = false
        view.showsPage = false
        #expect(!view.isPointerVisible)
        withExtendedLifetime(window) {}
    }

    @Test func aWindowThatIsNotOnScreenDoesNotWantTheFeed() {
        #expect(LiveScreenLayerView.wantsFeed(hasWindow: true, windowVisible: true, viewHidden: false, inView: true))
        #expect(!LiveScreenLayerView.wantsFeed(hasWindow: false, windowVisible: true, viewHidden: false, inView: true))
        #expect(!LiveScreenLayerView.wantsFeed(hasWindow: true, windowVisible: false, viewHidden: false, inView: true))
        #expect(!LiveScreenLayerView.wantsFeed(hasWindow: true, windowVisible: true, viewHidden: true, inView: true))
        #expect(!LiveScreenLayerView.wantsFeed(hasWindow: true, windowVisible: true, viewHidden: false, inView: false))
    }
}
