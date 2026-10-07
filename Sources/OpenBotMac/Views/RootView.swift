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
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .bot(let id):
                if let bot = model.bot(id) {
                    ChatView(bot: bot)
                        .id(id)
                }
            case .routines:
                RoutinesView()
            case .connectors:
                ConnectorsView()
            case .skills:
                SkillsView()
            case nil:
                ContentUnavailableView("Escolha um bot", systemImage: "circle.hexagongrid",
                                       description: Text("Ou crie um novo com ⇧⌘N."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
