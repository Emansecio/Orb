import SwiftUI

/// The sentences of a group's sidebar row, as plain values the tests read.
enum GroupRowText {
    /// The second line: what the group does ("Pesquisador está escrevendo…"), or "3 Orbs".
    static func secondLine(presence: String?, orbCount: Int) -> String {
        if let presence { return presence }
        return orbCount == 1 ? "1 Orb" : "\(orbCount) Orbs"
    }

    /// The one mark at the right of the row. Waiting for you shows none: the second line turns amber (and VoiceOver says
    /// it). Unseen beats working because the second line already says what the group does ("X está escrevendo…") while
    /// nothing else says there is something new; so the row never shows a dot and a ring side by side.
    static func marker(needsYou: Bool, unread: Int, working: Bool) -> SidebarMarker? {
        if needsYou { return nil }
        if unread > 0 { return .unread }
        return working ? .working : nil
    }

    /// What VoiceOver reads for the row: "Lançamento, grupo, 3 Orbs, não lido, trabalhando".
    static func accessibilityLabel(name: String, orbCount: Int, unread: Int, working: Bool, waiting: Bool) -> String {
        var parts = [name, "grupo", orbCount == 1 ? "1 Orb" : "\(orbCount) Orbs"]
        if waiting { parts.append("precisa de você") }
        if unread > 0 { parts.append("não lido") }
        if working { parts.append("trabalhando") }
        return parts.joined(separator: ", ")
    }
}

/// The groups of the sidebar, below the Orbs (the "+" of its title makes a new one). A group is also
/// made from the palette, ⌥⌘G, the Orbs menu or an Orb's "Criar grupo com…". With two Orbs and no group the section is
/// its title and "+" alone, which keeps the feature in sight.
struct SidebarGroupsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectionSpace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionTitle("Grupos") {
                Button { model.showNewGroup = true } label: { SectionPlus() }
                    .buttonStyle(.plain)
                    .disabled(model.botIDs.count < 2)
                    .help(model.botIDs.count < 2 ? "Crie ao menos 2 Orbs para formar um grupo" : Tip.newGroup())
                    .accessibilityLabel("Novo grupo")
                    .accessibilityIdentifier("sidebar-new-group")
            }
            ForEach(model.groups) { group in
                SidebarGroupRow(group: group, selectionSpace: selectionSpace)
                    .transition(.adapted(.arrive, reduceMotion: reduceMotion))
            }
        }
        // A group made or deleted comes and goes like an Orb's row, and the ones below slide.
        .animateChanges(of: model.groups.map(\.id))
    }
}

/// One group's row: its Orbs stacked (`stackSize`, "+N" past three), the name, what it does (amber while it waits
/// for you), and on the right one mark: an unread dot, or a ring while a request runs (`GroupRowText.marker`). Its selection is the sidebar's own.
struct SidebarGroupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrbGroup
    let selectionSpace: Namespace.ID
    @State private var isHovering = false
    @State private var isConfirmingDelete = false

    /// The stack takes the Orb avatar's 30 pt column and the 8 pt to the text (the Orbs' names start 46 pt from the row's edge):
    /// three 18 pt avatars overlapped by 10 pt are 34 wide, 4 pt of air after them.
    static let stackSize: CGFloat = 18
    static let stackOverlap: CGFloat = 10
    static let stackGap: CGFloat = 4

    var body: some View {
        let live = model.groupLive(group.id)
        let isSelected = model.selection == .group(group.id)
        let looks = model.groupLooks(group)
        let presenceItems = model.groupPresence(group, live: live)
        let presence = GroupPresence.sidebarText(presenceItems)
        let working = live.runState == .running
        Button {
            model.selection = .group(group.id)
        } label: {
            HStack(spacing: Self.stackGap) {
                StackedAvatars(members: looks.map { StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: model.live($0.id).activity) },
                               size: Self.stackSize, overlap: Self.stackOverlap)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(Typography.text.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(GroupRowText.secondLine(presence: presence, orbCount: looks.count))
                        .font(Typography.small)
                        .foregroundStyle(live.needsYou ? Palette.warn : Palette.faint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .help(GroupPresence.text(presenceItems) ?? "")
                }
                // The same height with or without a second line, so the rows keep one rhythm.
                .frame(minHeight: 32, alignment: .leading)
                Spacer(minLength: 4)
                let marker = GroupRowText.marker(needsYou: live.needsYou, unread: live.unread, working: working)
                ZStack {
                    switch marker {
                    case .working:
                        WorkingRing()
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    case .unread:
                        Circle()
                            .fill(Palette.accentText)
                            .frame(width: 7, height: 7)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    case nil:
                        EmptyView()
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: marker)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: Radius.medium))
            .background {
                if isSelected { SlidingSelectionFill(space: selectionSpace, radius: Radius.medium) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Abrir o grupo", systemImage: "person.3") { model.selection = .group(group.id) }
            Button("Renomear…", systemImage: "pencil") { model.showGroupNameEditor(of: group.id) }
            Button("Parar grupo", systemImage: "stop.circle") { model.stopGroup(group.id) }
                .disabled(live.runState == .idle)
            Divider()
            Button("Apagar grupo…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
        }
        .deleteGroupDialog(group, isPresented: $isConfirmingDelete)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupRowText.accessibilityLabel(name: group.name, orbCount: looks.count, unread: live.unread,
                                                            working: working, waiting: live.needsYou))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small ring that breathes while the group or a conversation works (a repeating opacity change; still under Reduce
/// Motion, and still a ring, so "working" never looks like the unread dot). The breath is a Core Animation opacity
/// animation (no SwiftUI re-evaluation per frame) that stops when the window is covered, the app is inactive or the ring
/// is scrolled out of view, like the shimmer and the Orbs.
struct WorkingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingDot(color: Palette.accentText, breathes: !reduceMotion, isRing: true)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

struct BreathingDot: NSViewRepresentable {
    let color: Color
    let breathes: Bool
    /// An outline instead of a filled dot.
    var isRing = false

    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateNSView(_ view: BreathingDotView, context: Context) {
        view.isRing = isRing
        view.color = NSColor(color)
        view.breathes = breathes
    }
}

final class BreathingDotView: NSView {
    private static let key = "breath"
    private weak var clipView: NSClipView?
    var color = NSColor.systemBlue { didSet { paint() } }
    var isRing = false { didSet { paint() } }
    var breathes = true { didSet { if breathes != oldValue { update() } } }
    /// For tests: whether the dot is breathing.
    var isBreathing: Bool { layer?.animation(forKey: Self.key) != nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(update), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            center.addObserver(self, selector: #selector(update), name: NSApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(update), name: NSApplication.didResignActiveNotification, object: nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        update()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    override func viewDidHide() {
        super.viewDidHide()
        update()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        update()
    }

    private func observeScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== clipView else { return }
        let center = NotificationCenter.default
        if let clipView { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView) }
        clipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: clip)
    }

    private func paint() {
        layer?.backgroundColor = isRing ? nil : color.cgColor
        layer?.borderColor = color.cgColor
        layer?.borderWidth = isRing ? 1.5 : 0
    }

    @objc private func update() {
        paint()
        let visible = window.map { !isHiddenOrHasHiddenAncestor && (OrbView.animateInactive || $0.occlusionState.contains(.visible)) } ?? false
        let inView = clipView.map { OrbVisibility.isVisible(orb: convert(bounds, to: $0), in: $0.bounds, margin: 20) } ?? true
        guard breathes, visible, NSApp.isActive || OrbView.animateInactive, inView else {
            layer?.removeAnimation(forKey: Self.key)
            // Held still, the dot shows its lit state (as under Reduce Motion).
            layer?.opacity = 1
            return
        }
        guard let layer, layer.animation(forKey: Self.key) == nil else { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.35
        breath.toValue = 1
        breath.duration = 0.9
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
        layer.add(breath, forKey: Self.key)
    }
}
