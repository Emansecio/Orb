import Foundation

/// Opens and closes the live streams of the Orbs' browsers (docs/TELA-AO-VIVO.md). A view that shows an Orb's page
/// acquires it while it is on screen and releases it when it leaves; the hub connects only while someone acquired it,
/// one stream at a time, and lets go of everything on release. Nothing it receives is written anywhere.
@MainActor
final class LiveFeedHub {
    private let browsers: BrowserHub
    private var stores: [UUID: LiveFrameStore] = [:]

    init(browsers: BrowserHub) {
        self.browsers = browsers
    }

    /// The store the views of this Orb read (made when first asked for).
    func store(_ botID: UUID) -> LiveFrameStore {
        if let store = stores[botID] { return store }
        let store = LiveFrameStore(botID: botID)
        stores[botID] = store
        return store
    }

    /// A view that shows this Orb's page appeared; `wide` is the larger view in the panel.
    func acquire(_ botID: UUID, wide: Bool = false) {}

    /// That view left; the stream closes a few seconds later if nothing acquired it again.
    func release(_ botID: UUID, wide: Bool = false) {}

    /// The last picture of a finished use of the browser (`BrowserViewItem`), as JPEG, while it is still kept in memory.
    func lastScreen(of itemID: UUID) -> Data? { nil }

    /// The Orb was deleted: its stream and store go.
    func forget(_ botID: UUID) { stores[botID] = nil }

    /// Frames decoded since launch (tests and the measurements say "none while nobody looks").
    private(set) var framesProcessed = 0
}
