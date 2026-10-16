import SwiftUI

/// The requests between Orbs still open outside groups, in Ajustes right under the switches: who asked whom, what, where it
/// stands, and Parar for the whole conversation. No section at all when there are none.
struct OpenTalksSection: View {
    @Environment(AppModel.self) private var model
    @Binding var talks: [DelegationHub.OpenTalk]

    var body: some View {
        if !talks.isEmpty {
            Section("Conversas abertas entre Orbs") {
                ForEach(talks) { talk in
                    LabeledContent {
                        Button("Parar") {
                            model.delegation.cancelChain(talk.chainID, by: .user)
                            talks = model.delegation.openTalks()
                        }
                        .help("Para esta conversa entre Orbs inteira: o pedido e o que ele puxou de outros Orbs")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(talk.title)
                            Text(talk.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
