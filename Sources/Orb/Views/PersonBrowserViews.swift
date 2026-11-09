import SwiftUI

// The person's own use of an Orb's browser (docs/historico/NAVEGADOR-DA-PESSOA-PLANO.md): "Abrir o navegador" opens its window, with
// the Orb's logins, and the Orb's browser tools wait until it is handed back. The panel's row is in `BrowserPickerRows`.

/// "Abrir o navegador" in the Orb's menu in the sidebar. While the person has the browser: bringing it forward and handing it
/// back. Nothing without "Navegar na web".
struct PersonBrowserMenuItems: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        if model.bot(botID)?.capabilities.contains(.browser) == true {
            if model.browserWithPerson.contains(botID) {
                Button("Mostrar o navegador", systemImage: Capability.browser.symbol) { model.openBrowserForPerson(botID) }
                Button("Devolver o navegador ao Orb", systemImage: "arrow.uturn.backward") { model.giveBrowserBack(botID) }
            } else {
                Button("Abrir o navegador", systemImage: Capability.browser.symbol) { model.openBrowserForPerson(botID) }
            }
        }
    }
}

/// The composer's sign that the person has the Orb's browser: what the Orb waits on, with its window and the hand-back one
/// click away. Only while they have it.
struct PersonBrowserChip: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    /// The composer is too narrow for words on its chips: only the icon shows.
    var compact = false

    var body: some View {
        Menu {
            Button("Mostrar o navegador", systemImage: Capability.browser.symbol) { model.openBrowserForPerson(botID) }
            Button("Devolver ao Orb", systemImage: "arrow.uturn.backward") { model.giveBrowserBack(botID) }
        } label: {
            if compact {
                Image(systemName: Capability.browser.symbol)
            } else {
                Label("Navegador com você", systemImage: Capability.browser.symbol)
            }
        }
        .menuStyle(.button)
        .buttonStyle(ComposerChipStyle(filled: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Tip.personBrowserChip)
        .accessibilityLabel("Navegador com você")
    }
}
