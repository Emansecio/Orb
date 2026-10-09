import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        // With Orbs there is always one chosen ("Escolha um Orb" is gone); with none, the welcome screen shows.
        .onChange(of: model.botIDs, initial: true) { _, ids in
            if !ids.isEmpty { welcomeLedger.reset() }
            fixSelection()
        }
        .onChange(of: model.selection) { fixSelection() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard let open = autoClose.windowResized(to: width, isOpen: model.showInspector) else { return }
            autoChange = open
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.showInspector = open }
        }
        .onChange(of: model.showInspector) { _, isOpen in
            if autoChange == isOpen { autoChange = nil } else { autoClose.userToggled() }
        }
        .environment(\.presentedEmptyChats, presentedEmptyChats)
        .environment(\.presentedQueued, presentedQueued)
        .sheet(isPresented: $model.showNewBot, onDismiss: { model.newBotStart = nil; model.newBotImporting = false }) {
            // Opened from a kept memory on the welcome screen: the sheet starts from it. Opened to import: on that panel.
            NewBotSheet(kept: model.newBotStart.map { [$0] } ?? [], chosen: model.newBotStart, startsImporting: model.newBotImporting)
        }
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
        let fixed = WelcomeSelection.resolved(model.selection, botIDs: model.botIDs)
        if fixed != model.selection { model.selection = fixed }
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let welcomeLedger: WelcomeLedger

    /// No Orbs and nothing else chosen: the front door.
    private var showsWelcome: Bool {
        model.botIDs.isEmpty && model.selection == nil
    }

    var body: some View {
        Group {
            switch model.selection {
            case .bot(let id):
                // The chat view stays across Orbs and swaps the Orb's own parts when `id` changes (the transcript with a
                // cross-fade, the composer, panel and toolbar at once), so the composer is outside the fade (§2.9).
                if model.botIDs.contains(id) {
                    ChatView(botID: id)
                }
            case .routines:
                RoutinesView()
            case .connectors:
                ConnectorsView()
            case .skills:
                SkillsView()
            case nil:
                // With Orbs the root view picks the first one at once; with none this is the welcome screen.
                if model.botIDs.isEmpty {
                    WelcomeView(ledger: welcomeLedger)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        // Coming in and out of the welcome screen is the chat's own cross-fade (§2.9).
        .animation(Motion.adapted(Motion.crossFade, reduceMotion: reduceMotion), value: showsWelcome)
    }
}
