import SwiftUI

/// The sentences of a group's sidebar row, as plain values the tests read.
enum GroupRowText {
    /// The second line: what the group does ("Pesquisador está escrevendo…"), "Pausado: continuar?", or "3 Orbs".
    static func secondLine(presence: String?, orbCount: Int, paused: Bool) -> String {
        if paused { return "Pausado: continuar?" }
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

/// The groups of the sidebar, between the Orbs and the workspace. Hidden while there is no group: a group is made from the
/// palette, ⌥⌘G, the Orbs menu or an Orb's "Criar grupo com…".
struct SidebarGroupsSection: View {
    @Environment(AppModel.self) private var model
    let selectionSpace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Grupos")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
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
        let presence = GroupPresence.text(model.groupPresence(group, live: live))
        let paused: Bool = { if case .paused = live.runState { true } else { false } }()
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
                    Text(GroupRowText.secondLine(presence: presence, orbCount: looks.count, paused: paused))
                        .font(.system(size: 11))
                        .foregroundStyle(live.needsYou || paused ? Palette.warn : Palette.faint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
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
            Button("Parar grupo", systemImage: "stop.circle") { model.stopGroup(group.id) }
                .disabled(live.runState == .idle)
            Divider()
            Button("Apagar grupo…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
        }
        .confirmationDialog("Apagar o grupo \(group.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Apagar grupo", role: .destructive) {
                model.deleteGroup(group.id)
                if model.selection == .group(group.id) { model.selection = model.botIDs.first.map { .bot($0) } }
            }
        } message: {
            Text("A conversa do grupo e o quadro saem com ele. Os Orbs continuam como estavam.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupRowText.accessibilityLabel(name: group.name, orbCount: looks.count, unread: live.unread,
                                                            working: working, waiting: live.needsYou))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small dot that breathes while the group works (a repeating opacity change; still under Reduce Motion).
private struct WorkingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(Palette.accentText)
            .frame(width: 7, height: 7)
            .opacity(lit || reduceMotion ? 1 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
            .accessibilityHidden(true)
    }
}
