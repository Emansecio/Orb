import SwiftUI

// The welcome screen: what the window shows when there are no Orbs (the first launch with nothing made yet, or after
// the last Orb was deleted). It is the front door: it says what the product is in a few seconds, with three Orbs that
// live and look back at you, and leads to the first Orb in as few clicks as possible: connect a model, then "Criar
// meu primeiro Orb" (the New Orb sheet) or "Começar com o Atlas" (one click). docs/MOVIMENTO.md §2.11.

// MARK: - What the screen is in

/// Which step of the front door the screen shows. One pure choice, so it can be tested without a window.
enum WelcomeStage: Equatable {
    /// The connections have not been looked at yet (launch: Keychain, ChatGPT, `claude auth status`). The screen shows
    /// the Orbs, the words and the three points, and only keeps the place of the action: neither the card nor the
    /// buttons, so nothing is shown and then swapped.
    case checking
    /// No model yet (or one was just connected and "Pronto" is on screen): the card that connects one.
    case connect
    /// A model is ready: make the first Orb.
    case create
    /// A model is ready and there are memories kept from Orbs that were deleted: they can start the new one.
    case createWithKept

    /// The card stays through the "Pronto" beat of a model that was just connected, as the empty chat's does.
    ///
    /// `detected`: Claude Code and the local servers have been looked for. Without a model the card (or the one big
    /// button it can become) waits for the answer, so what shows first is what stays. `starting`: "Usar meu Claude Code e
    /// começar" is under way and the Atlas is not made yet, so the card stays until it is.
    static func resolve(providerReady: Bool, connectedName: String?, keptCount: Int, connectionsChecked: Bool = true,
                        detected: Bool = true, starting: Bool = false) -> WelcomeStage {
        if !connectionsChecked { return .checking }
        if !providerReady && !detected { return .checking }
        if !providerReady || connectedName != nil || starting { return .connect }
        return keptCount > 0 ? .createWithKept : .create
    }

    var showsConnectCard: Bool { self == .connect }

    /// Whether the Atlas celebrates and VoiceOver announces "Pronto": only when a model was connected on the card
    /// (`viaCard`) and the screen moves on to making the Orb. Never when the first look at the connections ends.
    static func celebrates(old: WelcomeStage, new: WelcomeStage, viaCard: Bool) -> Bool {
        viaCard && old == .connect && (new == .create || new == .createWithKept)
    }
}

/// What makes the list of kept memories be read again: the list turning empty, or a memory that finished being kept.
struct WelcomeKeptKey: Equatable {
    var listIsEmpty: Bool
    var keptVersion: Int
}

/// What the screen says: the first sentence differs between the first use and an emptied list.
enum WelcomeCopy: Equatable {
    case firstUse
    case returning

    var title: String {
        switch self {
        case .firstUse: "Olá! Este é o Orb."
        case .returning: "Hora de um Orb novo"
        }
    }

    var subtitle: String { "Assistentes que conversam com você e fazem o trabalho no seu Mac." }

    /// The big button.
    var createTitle: String {
        switch self {
        case .firstUse: "Criar meu primeiro Orb"
        case .returning: "Criar um novo Orb"
        }
    }

    /// The sidebar's invitation, which speaks like the screen it leads to.
    var invitationTitle: String {
        switch self {
        case .firstUse: "Criar seu primeiro Orb"
        case .returning: "Criar um novo Orb"
        }
    }

    struct Point: Equatable, Identifiable {
        var symbol: String
        var title: String
        var detail: String
        var id: String { title }
    }

    /// The three things that matter, in the order they come up in use.
    static let points = [
        Point(symbol: "bubble.left.and.text.bubble.right", title: "Conversa e faz",
              detail: "Lê arquivos, roda comandos, navega e usa seus apps."),
        Point(symbol: "hand.raised", title: "Pede antes de agir", detail: "Você aprova o que mexe nas suas coisas."),
        Point(symbol: "brain.head.profile", title: "Lembra de você", detail: "Guarda o que importa e melhora a cada conversa."),
    ]

    static let heroAccessibilityLabel = "Três Orbs sorrindo: Atlas, de óculos, no meio; Lia, com um laço; Bento, com fones"
}

/// The three Orbs of the hero. Fixed looks (not random, not the user's): the same welcome for everyone.
enum WelcomeLooks {
    /// The suggested Orb is also the one the app used to start with.
    static let atlas = AppState.initial.bots[0].orb
    static let lia = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush", hair: "tufinho",
                               accessories: ["laco"], temperament: .timido)
    static let bento = OrbConfig(color: "menta", eyes: "pontos", mouth: "sorrisao", accessories: ["fones"],
                                 temperament: .curioso)
}

/// What the window's selection should be given the Orbs there are: with Orbs, "nothing" and a deleted Orb become the
/// first Orb ("Escolha um Orb" no longer exists); with none, a deleted Orb's chat becomes the welcome screen.
enum WelcomeSelection {
    static func resolved(_ selection: SidebarItem?, botIDs: [UUID]) -> SidebarItem? {
        if botIDs.isEmpty {
            if case .bot = selection { return nil }
            return selection
        }
        switch selection {
        case nil: return .bot(botIDs[0])
        case .bot(let id)?: return botIDs.contains(id) ? selection : .bot(botIDs[0])
        default: return selection
        }
    }
}

/// When the entrance plays (§2.11): the first time the screen shows in the session and each time the list has just
/// become empty; coming back from Rotinas, Conectores or Skills does not repeat it. A reference the root view holds,
/// so the screen being made again costs nothing.
final class WelcomeLedger {
    private(set) var played = false

    init() {}

    /// The screen has appeared: its entrance (if it had one) is done.
    func notePlayed() { played = true }

    /// The list has Orbs again: the next time it empties, the entrance plays again.
    func reset() { played = false }

    /// Whether the entrance plays now. No ledger (a snapshot): it does not.
    static func plays(_ ledger: WelcomeLedger?) -> Bool { ledger.map { !$0.played } ?? false }
}

/// The order the screen comes in (§2.11): the Orbs drop in turn, then the title and the subtitle, the three points,
/// and last the card or the actions, then the kept memories.
enum WelcomeEntrance {
    static let atlas = EntranceStyle.drop
    static let lia = EntranceStyle.drop.delayed(0.06)
    static let bento = EntranceStyle.drop.delayed(0.10)
    static let title = EntranceStyle.rise.delayed(0.16)
    static let subtitle = EntranceStyle.rise.delayed(0.20)
    static let pointsStart = 0.26
    static let actions = EntranceStyle.rise.delayed(0.40)
    static let keptCard = EntranceStyle.rise.delayed(0.44)
    /// How long the card waits for the look at Claude Code and the local servers before it shows anyway.
    static let detectionPatience: Duration = .seconds(2)
    /// The two other ways in, side by side under the main button, one after the other.
    static func choice(_ index: Int) -> EntranceStyle { .staggered(index, start: 0.46) }
    /// After this long the screen is "settled": what appears later comes in with a transition, not the entrance.
    static let duration: Duration = .seconds(1)

    static func point(_ index: Int) -> EntranceStyle { .staggered(index, start: pointsStart) }
}

// MARK: - The screen

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// For snapshots: a stage, the sentences and the kept memories fixed (nil: what the app says now).
    private let forcedStage: WelcomeStage?
    private let forcedCopy: WelcomeCopy?
    private let forcedKept: [KeptMemory]?
    private let detectsProviders: Bool
    /// Says whether the entrance plays (nil: it does not, as in a snapshot).
    private let ledger: WelcomeLedger?

    @State private var firstRun: FirstRunModel
    @State private var loadedKept: [KeptMemory] = []
    /// True during the first second of an entrance that plays (decided when the view is made, from the ledger): what
    /// is made after that comes in with a transition instead.
    @State private var entering: Bool
    @State private var contentHeight: CGFloat = 520
    @State private var liaPoke = 0
    @State private var atlasPoke = 0
    @State private var bentoPoke = 0
    @State private var celebrating = false
    /// The look for Claude Code and the local servers took longer than `WelcomeEntrance.detectionPatience`: the card
    /// shows without waiting for it (the big button comes in later if it turns out to be there).
    @State private var detectionWaitOver = false
    /// A model was connected on the card during this stay on the screen (only that makes the Atlas celebrate).
    @State private var connectedOnCard = false
    @State private var lastHoverPoke = Date.distantPast
    @AccessibilityFocusState private var createFocused: Bool

    init(forcedStage: WelcomeStage? = nil, copy: WelcomeCopy? = nil, kept: [KeptMemory]? = nil,
         detectsProviders: Bool = true, claude: ClaudeCodeStatus? = nil, ledger: WelcomeLedger? = nil) {
        self.forcedStage = forcedStage
        self.forcedCopy = copy
        self.forcedKept = kept
        self.detectsProviders = detectsProviders
        _firstRun = State(initialValue: FirstRunModel(claude: claude))
        self.ledger = ledger
        _entering = State(initialValue: WelcomeLedger.plays(ledger))
    }

    private var kept: [KeptMemory] { forcedKept ?? loadedKept }

    private var stage: WelcomeStage {
        forcedStage ?? .resolve(providerReady: model.isProviderReady, connectedName: firstRun.connectedName, keptCount: kept.count,
                                connectionsChecked: model.hasCheckedConnections,
                                detected: firstRun.hasDetected || !detectsProviders || detectionWaitOver,
                                starting: firstRun.isStarting)
    }

    /// The one big button, when a path is ready to use (nil: the card with its paths).
    private var offer: FirstRunOffer? { firstRun.offer(keptCount: kept.count) }

    private var copy: WelcomeCopy { forcedCopy ?? model.welcomeCopy }

    var body: some View {
        let stage = stage
        let copy = copy
        GeometryReader { proxy in
            // The light is the scrolling column's own background, so it moves with the Orbs instead of staying behind.
            ScrollView {
                content(stage: stage, copy: copy)
                    .padding(.horizontal, 28)
                    .padding(.vertical, stage == .connect ? 24 : 32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .background { WelcomeBackdrop(heroY: heroCenter(in: proxy.size.height, stage: stage)) }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .background(Palette.canvas)
        }
        .onAppear(perform: begin)
        .onDisappear { model.welcomeReason = nil }
        .task {
            // Looks as soon as the screen is up, in step with the first look at the connections.
            firstRun.attach(model)
            guard forcedStage == nil, detectsProviders, !firstRun.hasDetected else { return }
            await firstRun.detect()
        }
        .task {
            try? await Task.sleep(for: WelcomeEntrance.detectionPatience)
            detectionWaitOver = true
        }
        .task(id: WelcomeKeptKey(listIsEmpty: model.botIDs.isEmpty, keptVersion: model.keptMemoriesVersion)) { await loadKept() }
        .onChange(of: firstRun.connectedName) { _, name in
            if name != nil { connectedOnCard = true }
        }
        .onChange(of: stage) { old, new in
            let viaCard = connectedOnCard
            if new != .connect { connectedOnCard = false }
            if WelcomeStage.celebrates(old: old, new: new, viaCard: viaCard) { connected() }
        }
    }

    // MARK: Layout

    private func content(stage: WelcomeStage, copy: WelcomeCopy) -> some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 6) {
                Text(copy.title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .entrance(WelcomeEntrance.title, enters: entering)
                Text(copy.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .entrance(WelcomeEntrance.subtitle, enters: entering)
            }
            points
                .padding(.top, 26)
            Group {
                if stage == .checking {
                    // Keeps the place of what comes: the card or the buttons enter here once the answer is known.
                    Color.clear.frame(height: 150)
                } else if stage.showsConnectCard {
                    connect
                        .transition(.opacity.animation(reduceMotion ? Motion.fade : Motion.exit))
                        .entrance(WelcomeEntrance.actions, enters: entering)
                } else {
                    actions(stage: stage, copy: copy)
                        .transition(.adapted(.rise, reduceMotion: reduceMotion))
                        .entrance(WelcomeEntrance.actions, enters: entering)
                }
            }
            .padding(.top, stage.showsConnectCard ? 28 : 34)
            .animation(reduceMotion ? Motion.fade : Motion.enter, value: stage)
        }
        .frame(maxWidth: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }

    /// No model yet: the note of why the screen came up (if something sent you here), then the one big button when
    /// Claude Code is ready, or the card with its paths.
    private var connect: some View {
        VStack(spacing: 18) {
            if let reason = model.welcomeReason { WelcomeReasonNote(reason: reason) }
            if let offer {
                WelcomeOfferView(offer: offer, run: firstRun, onStarted: startedWithOffer)
            } else {
                FirstRunCard(style: .welcome, run: firstRun, detectsOnAppear: detectsProviders && !firstRun.hasDetected)
            }
        }
    }

    /// Where the middle of the Atlas is, from the top of the area: the glow is centered there.
    private func heroCenter(in height: CGFloat, stage: WelcomeStage) -> CGFloat {
        let padding: CGFloat = stage == .connect ? 24 : 32
        let top = max(padding, (height - contentHeight) / 2)
        return top + 40 + 52
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 44) {
            heroOrb(WelcomeLooks.lia, size: 72, landing: liaPoke, style: WelcomeEntrance.lia) { liaPoke += 1 }
            heroOrb(WelcomeLooks.atlas, size: 104, landing: atlasPoke, style: WelcomeEntrance.atlas, activity: celebrating ? .happy : .idle) {
                atlasPoke += 1
            }
            heroOrb(WelcomeLooks.bento, size: 72, landing: bentoPoke, style: WelcomeEntrance.bento) { bentoPoke += 1 }
        }
        .padding(.top, 40)
        .padding(.bottom, 28)
        // One picture for VoiceOver, not three separate Orbs.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WelcomeCopy.heroAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private func heroOrb(_ config: OrbConfig, size: CGFloat, landing: Int, style: EntranceStyle,
                         activity: OrbActivity = .idle, landed: @escaping @MainActor () -> Void) -> some View {
        SettlingOrb(idle: activity == .idle, wake: landing) { settled in
            OrbView(config: config, activity: activity, size: size, animated: true, paused: settled, landing: landing, interactive: true)
        }
            .entrance(style, enters: entering) {
                // Touches the floor: it lands. Still under Reduce Motion.
                if !reduceMotion { landed() }
            }
    }

    // MARK: The three points

    private var points: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(WelcomeCopy.points.enumerated()), id: \.element.id) { index, point in
                    WelcomePointView(point: point, isRow: false)
                        .entrance(WelcomeEntrance.point(index), enters: entering)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(WelcomeCopy.points.enumerated()), id: \.element.id) { index, point in
                    WelcomePointView(point: point, isRow: true)
                        .entrance(WelcomeEntrance.point(index), enters: entering)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    // MARK: Actions

    private func actions(stage: WelcomeStage, copy: WelcomeCopy) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 14) {
                Button { model.startNewOrb(from: nil) } label: {
                    HStack(spacing: 10) {
                        Text(copy.createTitle)
                        Text(AppShortcut.newBot.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.onInk.opacity(0.5))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(HeroPillStyle())
                .keyboardShortcut(.defaultAction)
                .help(Tip.createOrbSheet())
                .accessibilityHint("Abre a folha Novo Orb")
                .accessibilityFocused($createFocused)

            }
            if stage == .createWithKept {
                KeptStartCard(memories: kept, onContinue: { model.startNewOrb(from: $0) }, onShowAll: { model.startNewOrb(from: nil) })
                    .padding(.top, 6)
                    .transition(.adapted(.rise, reduceMotion: reduceMotion))
                    .entrance(WelcomeEntrance.keptCard, enters: entering)
            }
            otherWaysIn
                .padding(.horizontal, 6) // room for the capsules' edges (and their growth under the pointer)
                .padding(.top, 4)
        }
    }

    /// The other two ways in, quiet beside the main button: side by side, stacked when the window is narrow.
    private var otherWaysIn: some View {
        let atlas = WelcomeChoice(symbol: "sparkle", title: "Começar com o Atlas", help: Tip.createAtlas,
                                  onHover: hoverAtlas) { _ = model.createSuggestedOrb() }
            .accessibilityLabel("Começar com o Atlas, pronto para usar")
            .accessibilityHint("Cria o Atlas agora. Dá para personalizar depois")
            .entrance(WelcomeEntrance.choice(0), enters: entering)
        let importing = WelcomeChoice(symbol: "square.and.arrow.down", title: "Importar de outro assistente",
                                      help: Tip.importFromAssistant) { model.startNewOrbImporting() }
            .accessibilityHint("Abre a folha Novo Orb para trazer o que outro assistente sabe de você")
            .entrance(WelcomeEntrance.choice(1), enters: entering)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { atlas; importing }
            VStack(spacing: 8) { atlas; importing }
        }
    }

    // MARK: Behavior

    private func begin() {
        guard entering else { return }
        ledger?.notePlayed()
        Task {
            try? await Task.sleep(for: WelcomeEntrance.duration)
            entering = false
        }
    }

    private func loadKept() async {
        guard forcedKept == nil, model.botIDs.isEmpty else { return }
        let root = model.memory.root
        loadedKept = await Task.detached(priority: .userInitiated) { KeptMemories.list(in: root) }.value
    }

    /// The Atlas gives a little hop when the pointer is on "Começar com o Atlas": cause and effect, at most once
    /// every 1.5 s.
    private func hoverAtlas() {
        guard !reduceMotion, Date.now.timeIntervalSince(lastHoverPoke) > 1.5 else { return }
        lastHoverPoke = .now
        atlasPoke += 1
    }

    /// "Usar meu Claude Code e começar" made the Atlas: VoiceOver says where the person is now (the chat opens).
    private func startedWithOffer() {
        AccessibilityNotification.Announcement("Claude Code conectado. Atlas criado.").post()
    }

    /// A model just got connected: the Atlas celebrates for 3 s (the session's own flash time), VoiceOver says what is
    /// next and the focus goes to the main button.
    private func connected() {
        if !reduceMotion { atlasPoke += 1 }
        celebrating = true
        AccessibilityNotification.Announcement("Pronto. Agora crie seu primeiro Orb.").post()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            createFocused = true
            try? await Task.sleep(for: .seconds(3))
            celebrating = false
        }
    }
}

// MARK: - Parts

/// One of the three points: a round icon, what it is and one line of why.
private struct WelcomePointView: View {
    let point: WelcomeCopy.Point
    /// Icon to the left of the words (the narrow window's list) instead of above them.
    let isRow: Bool

    var body: some View {
        Group {
            if isRow {
                HStack(alignment: .top, spacing: 12) { icon; words }
            } else {
                // Centered in its column, like the Orbs, the title and the card above and below it.
                VStack(alignment: .center, spacing: 6) { icon; words }
                    .frame(width: 168)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(point.title). \(point.detail)")
    }

    private var icon: some View {
        Image(systemName: point.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.06), in: .circle)
            .overlay(Circle().strokeBorder(Palette.line))
    }

    private var words: some View {
        VStack(alignment: isRow ? .leading : .center, spacing: 2) {
            Text(point.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(point.detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(isRow ? .leading : .center)
    }
}

/// One of the quieter ways in under the main button: an icon and a few words in a soft capsule that lights up and
/// grows a little under the pointer (opacity and scale only). What it does in full is in the tooltip.
private struct WelcomeChoice: View {
    let symbol: String
    let title: String
    let help: String
    var onHover: (() -> Void)?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? Palette.accentText : Palette.muted)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovering ? Palette.ink : Palette.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(isHovering ? 0.08 : 0.04), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isHovering ? Palette.lineStrong : Palette.line))
            .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
            .animation(Motion.hover(isHovering), value: isHovering)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .onHover {
            isHovering = $0
            if $0 { onHover?() }
        }
    }
}

/// "Começar de uma memória guardada": up to three of the memories kept from Orbs that were deleted, newest first.
struct KeptStartCard: View {
    let memories: [KeptMemory]
    let onContinue: (KeptMemory) -> Void
    let onShowAll: () -> Void

    static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .foregroundStyle(Palette.muted)
                Text("Começar de uma memória guardada")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            let rows = Array(memories.prefix(Self.shown))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, memory in
                if index > 0 { Divider().overlay(Palette.line).padding(.leading, 48) }
                KeptStartRow(memory: memory) { onContinue(memory) }
            }
            if memories.count > Self.shown {
                Divider().overlay(Palette.line).padding(.leading, 48)
                Button(action: onShowAll) {
                    Text("Ver todas (\(memories.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Tip.allKeptMemories)
            }
        }
        .padding(.bottom, 2)
        .frame(width: 420)
        .card(radius: 14, fill: Palette.surface.opacity(0.9))
        .accessibilityElement(children: .contain)
    }
}

private struct KeptStartRow: View {
    let memory: KeptMemory
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OrbView(config: memory.profile?.orb ?? OrbConfig(color: "grafite"), size: 26, animated: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(memory.shortDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Continuar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accentText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .hoverFill(isHovering, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Tip.continueFromMemory)
        .onHover { isHovering = $0 }
        .accessibilityLabel(memory.spokenSummary)
    }
}

/// The stage light behind the Orbs, drawn once and never animated: a soft indigo ellipse over the whole area, a cool
/// pool on the floor under the Orbs and a faint veil from the top. Nothing here blurs or moves.
struct WelcomeBackdrop: View, Equatable {
    /// How far from the top the middle of the hero is.
    let heroY: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Palette.canvas
                // Over the whole area: a frame would show its edge.
                Rectangle().fill(EllipticalGradient(
                    colors: [Palette.stageGlow.opacity(0.24), Palette.stageGlow.opacity(0.09), Palette.stageGlow.opacity(0)],
                    center: UnitPoint(x: 0.5, y: size.height > 0 ? heroY / size.height : 0.3),
                    startRadiusFraction: 0, endRadiusFraction: 0.75))
                Rectangle()
                    .fill(EllipticalGradient(colors: [Palette.stageFloor.opacity(0.08), Palette.stageFloor.opacity(0)],
                                             center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: 560, height: 110)
                    .position(x: size.width / 2, y: heroY + 64)
                LinearGradient(colors: [Color.white.opacity(0.025), .clear], startPoint: .top, endPoint: .center)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
