import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            DetailView()
        }
        .sheet(isPresented: $model.showNewBot) {
            NewBotSheet()
        }
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
                // One chat view per Orb, rebuilt on switching. Keeping it and scoping the `.id` to the transcript was
                // measured: it made switching to a long conversation about 7x more expensive (the new transcript
                // realized its rows eagerly) and saved nothing on short ones.
                if model.botIDs.contains(id) {
                    ChatView(botID: id)
                        .id(id)
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
