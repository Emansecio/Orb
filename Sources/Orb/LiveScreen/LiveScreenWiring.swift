import Foundation

// What the interface (WP-C) calls on the live feed hub that the feed's own package (WP-B) adds to it. These stand in so the
// interface compiles and is tested on its own; when the two merge, the hub's own versions replace them and this file goes.

extension LiveFeedHub {
    // WP-B: replace on merge
    /// The Orb's use of the browser (`BrowserViewItem`) ended: the hub keeps its last picture under `itemID` (never of a
    /// protected page) and lets go of the stream.
    func endUse(_ botID: UUID, itemID: UUID) {}

    // WP-B: replace on merge
    /// A hand-off waits for the person (or no longer does): the page is protected while it does.
    func setHandoffPending(_ botID: UUID, _ pending: Bool) {}
}
