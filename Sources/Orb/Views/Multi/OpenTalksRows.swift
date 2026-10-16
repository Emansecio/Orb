import SwiftUI

/// The requests between Orbs still open outside groups, in Ajustes under the switches: who asked whom, what, where it stands,
/// and Parar for the whole conversation. Nothing when there are none.
struct OpenTalksRows: View {
    @Environment(AppModel.self) private var model
    @Binding var talks: [DelegationHub.OpenTalk]

    var body: some View {
        if !talks.isEmpty {
            Text("Conversas abertas entre Orbs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(talks) { talk in
            LabeledContent {
                Button("Parar") {
                    model.delegation.cancelChain(talk.chainID, by: .user)
                    talks = model.delegation.openTalks()
                }
                .help("Para esta conversa entre Orbs inteira: o pedido e o que ele puxou de outros Orbs.")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(talk.title)
                    Text(talk.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}
