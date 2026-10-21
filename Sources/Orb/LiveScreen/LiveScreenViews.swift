import SwiftUI

/// The chat's row for one use of the Orb's browser: the live card while the turn uses it, the closing line after.
struct LiveScreenRow: View {
    let itemID: UUID
    let view: BrowserViewItem
    let botID: UUID

    var body: some View {
        EmptyView()
    }
}

/// The panel's "Tela" tab: the Orb's page, live and larger.
struct LiveScreenTab: View {
    let botID: UUID

    var body: some View {
        EmptyView()
    }
}
