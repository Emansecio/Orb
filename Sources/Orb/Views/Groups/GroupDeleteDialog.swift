import SwiftUI

extension View {
    /// The confirmation to delete a group, the same in the sidebar's menu and the group's panel. Deleting also leaves the
    /// group's page for the first Orb when it was open (`AppModel.deleteGroup`).
    func deleteGroupDialog(_ group: OrbGroup, isPresented: Binding<Bool>) -> some View {
        modifier(DeleteGroupDialog(group: group, isPresented: isPresented))
    }
}

private struct DeleteGroupDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    let group: OrbGroup
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Apagar o grupo \(group.name)?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Apagar grupo", role: .destructive) { model.deleteGroup(group.id) }
        } message: {
            Text("A conversa do grupo e o quadro saem com ele. Os Orbs continuam como estavam.")
        }
    }
}
