import Foundation

// WP-A: the two pieces of `LiveBrowserSource` that need the browser package's additions to `BrowserHub`. They are placeholders
// here so this package compiles alone; at the merge each body becomes the one-line call in its comment, and the file goes.

extension BrowserHubLiveSource {
    func pageLooksSensitive(botID: UUID) -> Bool {
        // TODO(WP-A): `browsers.pageLooksSensitive(botID: botID)`. Until then only the stream's own address is judged
        // (`LiveProtection.setAddress`), plus the hand-off card the interface reports (`LiveFeedHub.setHandoffPending`).
        false
    }

    func setPointerHandler(_ handler: (@Sendable (UUID, LivePointer) -> Void)?) {
        // TODO(WP-A): `browsers.setPointerHandler(handler)`. Until then the card shows no cursor.
    }
}
