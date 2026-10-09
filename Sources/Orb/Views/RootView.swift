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

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            DetailView()
        }
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
        .sheet(isPresented: $model.showNewBot) {
            NewBotSheet()
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

private struct DetailView: View {
    @Environment(AppModel.self) private var model

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
                ContentUnavailableView("Escolha um Orb", systemImage: "circle.hexagongrid",
                                       description: Text("Ou crie um novo com ⌘N."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
