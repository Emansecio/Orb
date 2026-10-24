import SwiftUI

/// The sentences of a group's sidebar row, as plain values the tests read.
enum GroupRowText {
    /// The second line: what the group does ("Pesquisador está escrevendo…"), or "3 Orbs".
    static func secondLine(presence: String?, orbCount: Int) -> String {
        if let presence { return presence }
        return orbCount == 1 ? "1 Orb" : "\(orbCount) Orbs"
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
/// made from the palette, ⌥⌘G, the Orbs menu or an Orb's "Criar grupo com…".
struct SidebarGroupsSection: View {
    @Environment(AppModel.self) private var model
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
            }
        }
    }
}

/// One group's row: its Orbs stacked (24 pt, −9 pt overlap, "+N" past three), the name, what it does, and on the right a
/// badge when it waits for you, an unread dot, and a ring while a request runs. Its selection is the sidebar's own.
struct SidebarGroupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrbGroup
    let selectionSpace: Namespace.ID
    @State private var isHovering = false
    @State private var isConfirmingDelete = false

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
            HStack(spacing: 8) {
                StackedAvatars(members: looks.map { StackedAvatars.Member(id: $0.id, orb: $0.orb, activity: model.live($0.id).activity) },
                               size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(GroupRowText.secondLine(presence: presence, orbCount: looks.count))
                        .font(.system(size: 11))
                        .foregroundStyle(live.needsYou ? Palette.warn : Palette.faint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .help(GroupPresence.text(presenceItems) ?? "")
                }
                // The same height with or without a second line, so the rows keep one rhythm.
                .frame(minHeight: 32, alignment: .leading)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if working { WorkingRing() }
                    if live.needsYou {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warn)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    } else if live.unread > 0 {
                        Circle()
                            .fill(Palette.accentText)
                            .frame(width: 7, height: 7)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    }
                }
                .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: live.needsYou || live.unread > 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(isHovering && !isSelected, in: .rect(cornerRadius: 10))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Palette.ghostSelected)
                        .matchedGeometryEffect(id: SidebarSelection.id, in: selectionSpace)
                }
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

/// A small dot that breathes while the group works (a repeating opacity change; still under Reduce Motion). The breath
/// is a Core Animation opacity animation (no SwiftUI re-evaluation per frame) that stops when the window is covered, the
/// app is inactive or the dot is scrolled out of view, like the shimmer and the Orbs.
private struct WorkingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BreathingDot(color: Palette.accentText, breathes: !reduceMotion)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

struct BreathingDot: NSViewRepresentable {
    let color: Color
    let breathes: Bool

    func makeNSView(context: Context) -> BreathingDotView { BreathingDotView() }

    func updateNSView(_ view: BreathingDotView, context: Context) {
        view.color = NSColor(color)
        view.breathes = breathes
    }
}

final class BreathingDotView: NSView {
    private static let key = "breath"
    private weak var clipView: NSClipView?
    var color = NSColor.systemBlue { didSet { layer?.backgroundColor = color.cgColor } }
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

    @objc private func update() {
        layer?.backgroundColor = color.cgColor
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
