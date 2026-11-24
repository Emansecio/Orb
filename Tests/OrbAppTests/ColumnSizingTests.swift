import AppKit
import SwiftUI
import Testing
@testable import Orb

/// `ColumnSizing.TrimView` clears `sizingOptions` on column hosting views while leaving the window's root hosting view alone.
@MainActor
struct ColumnSizingTests {
    @Test func trimsColumnHostingViewsWithoutTouchingTheWindowRoot() async {
        let root = NSHostingView(rootView: Text("Janela").padding().frame(width: 400, height: 300))
        let column = NSHostingView(rootView: Text("Coluna").padding().frame(width: 120))
        let trimmer = ColumnSizing.TrimView()
        root.addSubview(column)
        root.addSubview(trimmer)
        #expect(!root.sizingOptions.isEmpty && !column.sizingOptions.isEmpty)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            window.contentView = NSView()
            window.close()
        }

        await waitUntil("the column hosting view's sizingOptions to be trimmed") { column.sizingOptions.isEmpty }
        #expect(!root.sizingOptions.isEmpty)
    }
}
