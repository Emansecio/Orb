import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Closes the Orb's panel when the window gets narrow and opens it again when it is wide (unless you chose).
    @State private var autoClose = InspectorAutoClose()
    /// What the last automatic change set, to tell it from the user's own toggle.
    @State private var autoChange: Bool?
    /// The Orbs whose empty chat already came in this session: going to another Orb and back does not repeat it (§2.8).
    @State private var presentedEmptyChats = PresentedOrbs()
    /// The queued messages that already came in (ids): reopening the chat does not bring them in again.
    @State private var presentedQueued = PresentedOrbs()
    /// Whether the welcome screen's entrance already played for this empty list (§2.11).
    @State private var welcomeLedger = WelcomeLedger()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            DetailView(welcomeLedger: welcomeLedger)
        }
        // The bar is the sidebar's own color, not the system's grey: the top of the window and the sidebar are one surface.
        .toolbarBackground(Palette.chrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // With Orbs there is always one chosen ("Escolha um Orb" is gone); with none, the welcome screen shows.
        .onChange(of: model.botIDs, initial: true) { _, ids in
            if !ids.isEmpty { welcomeLedger.reset() }
            fixSelection()
        }
        .onChange(of: model.selection) { fixSelection() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard let open = autoClose.windowResized(to: width, isOpen: model.showInspector) else { return }
            autoChange = open
            model.setInspector(open)
        }
        .onChange(of: model.showInspector) { _, isOpen in
            if autoChange == isOpen { autoChange = nil } else { autoClose.userToggled() }
        }
        .environment(\.presentedEmptyChats, presentedEmptyChats)
        .environment(\.presentedQueued, presentedQueued)
        .sheet(isPresented: $model.showNewBot, onDismiss: { model.newBotStart = nil; model.newBotImporting = false; MemoryRelief.orbsClosed() }) {
            // Opened from a kept memory on the welcome screen: the sheet starts from it. Opened to import: on that panel.
            NewBotSheet(kept: model.newBotStart.map { [$0] } ?? [], chosen: model.newBotStart, startsImporting: model.newBotImporting)
        }
        // MARK: MultiOrb (WP6)
        .sheet(isPresented: $model.showNewGroup, onDismiss: { model.newGroupStart = nil; MemoryRelief.orbsClosed() }) {
            NewGroupSheet(startingWith: model.newGroupStart)
        }
        // MARK: end MultiOrb (WP6)
        .systemSheets()
        .alert("Atenção com seus dados", isPresented: Binding(
            get: { !model.dataNotices.isEmpty },
            set: { if !$0 { model.dismissDataNotice() } }
        )) {
            Button("OK") {}
            if let copy = model.dataNotices.first?.copy {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
            }
        } message: {
            Text(model.dataNotices.first?.message ?? "")
        }
    }
}

extension RootView {
    /// Keeps the selection pointing at something that exists (`WelcomeSelection`).
    fileprivate func fixSelection() {
        // MARK: MultiOrb (WP6): a group that was deleted is no selection; the first Orb takes its place.
        if case .group(let id)? = model.selection, !model.groups.contains(where: { $0.id == id }) {
            model.selection = model.botIDs.first.map { .bot($0) }
        }
        let fixed = WelcomeSelection.resolved(model.selection, botIDs: model.botIDs)
        if fixed != model.selection { model.selection = fixed }
    }
}

/// Which page the detail column is showing, as far as a change of page is concerned (§2.9): the key of the
/// cross-fade. Every Orb is the same page: going from one Orb to another is not a page change (the chat swaps its own
/// parts and cross-fades its transcript), so it carries no Orb id. The moments a selection points at nothing yet (an
/// Orb that was just deleted, before the root view picks another) are still the Orb's page, so they cause no fade.
enum DetailPage: Hashable {
    case orb, routines, connectors, skills, welcome

    static func page(for selection: SidebarItem?, botIDs: [UUID]) -> DetailPage {
        switch selection {
        case .routines: .routines
        case .connectors: .connectors
        case .skills: .skills
        case .bot?: botIDs.isEmpty ? .welcome : .orb
        case .group?: .orb // MARK: MultiOrb (WP6): a page of its own once the group screens exist
        case nil: botIDs.isEmpty ? .welcome : .orb
        }
    }

    /// How the page comes and goes: a fade, the old page gone faster than the new one arrives (`.pageSwap`). The welcome
    /// screen leaves at `Motion.exit` when you make the first Orb, so the new Orb's chat does not wait for it.
    var transition: AnyTransition {
        self == .welcome ? .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit)) : .pageSwap
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model
    let welcomeLedger: WelcomeLedger

    var body: some View {
        let page = DetailPage.page(for: model.selection, botIDs: model.botIDs)
        // Pages swap in a ZStack, never a Group or a stack: the page that leaves and the one that arrives are both
        // there during the fade, laid over each other instead of side by side. A change of page is a fade with no
        // direction (`Motion.crossFade`, 0.15 s under Reduce Motion).
        ZStack {
            content
                .id(page)
                .transition(page.transition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .motion(Motion.crossFade, value: page)
        // The Orb's panel belongs to the Orb's page: it is here, not in the chat, so it closes with the page rather than
        // staying a fade-length behind it and vanishing. The user's choice (`showInspector`) is left as it was.
        .inspector(isPresented: Binding(
            get: { model.showInspector && page == .orb && (selectedBotID != nil || selectedGroupID != nil) },
            set: { if page == .orb { model.showInspector = $0 } }
        )) {
            ZStack {
                if let id = selectedBotID {
                    // One panel for every Orb: changing Orbs gives it the other's data instead of building it again (its
                    // form, pickers and switches took about a third of a change). It clears what belongs to one Orb itself.
                    BotInspector(botID: id)
                        .transition(.opacity)
                } else if let id = selectedGroupID {
                    // MARK: MultiOrb (WP6): a group's panel in the same column
                    GroupPanel(groupID: id)
                        .id(id)
                        .transition(.opacity)
                }
            }
            // The two sides of one click (the chat and the panel) change at the same pace.
            .motion(Motion.crossFade, value: selectedBotID ?? selectedGroupID)
            .inspectorColumnWidth(min: 244, ideal: 300, max: 420)
        }
    }

    private var selectedBotID: UUID? {
        if case .bot(let id)? = model.selection, model.botIDs.contains(id) { return id }
        return nil
    }

    // MARK: MultiOrb (WP6)
    private var selectedGroupID: UUID? { model.selectedGroupID }

    @ViewBuilder private var content: some View {
        switch model.selection {
        case .bot(let id):
            // The chat view stays across Orbs and swaps the Orb's own parts when `id` changes (the transcript with a
            // cross-fade, the composer and toolbar at once), so the composer is outside the fade (§2.9).
            if model.botIDs.contains(id) {
                ChatView(botID: id)
            }
        case .routines:
            RoutinesView()
        case .connectors:
            ConnectorsView()
        case .skills:
            SkillsView()
        case .group(let id):
            // MARK: MultiOrb (WP6)
            if model.groups.contains(where: { $0.id == id }) {
                GroupChatView(groupID: id)
                    .id(id)
                    .transition(.opacity)
            }
        case nil:
            // With Orbs the root view picks the first one at once; with none this is the welcome screen.
            if model.botIDs.isEmpty {
                WelcomeView(ledger: welcomeLedger)
            }
        }
    }
}
