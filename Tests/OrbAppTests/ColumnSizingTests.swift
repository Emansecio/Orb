import AppKit
import SwiftUI
import Testing
@testable import Orb

/// `ColumnSizing` reaches a column's `NSHostingView` through a protocol, whatever its private `Content` type.
@MainActor
struct ColumnSizingTests {
    @Test func aHostingViewOfAnyContentLosesItsSizeAnswers() {
        let view = NSHostingView(rootView: Text("Orb").padding().frame(width: 120))
        #expect(!view.sizingOptions.isEmpty)
        let found = (view as NSView) as? SizingTrimmable
        #expect(found != nil)
        found?.trimSizing()
        #expect(view.sizingOptions.isEmpty)
    }
}
