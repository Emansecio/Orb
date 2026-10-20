import SwiftUI
import AppKit

/// Stops the window's columns from measuring themselves at every layout.
///
/// Each column of the split view (the sidebar, the chat, the Orb's panel) is a hosting view of its own, and a hosting view
/// answers to its smallest, ideal and largest size (`sizingOptions`), asked again at every layout. While a panel slides
/// (the chat column changes width at every frame) that was more than half of the layout: the whole column measured three
/// more times at sizes that defeat SwiftUI's caches. The split view sets the columns' sizes (`navigationSplitViewColumnWidth`,
/// `inspectorColumnWidth`); nothing uses what the columns would say about theirs. Measured with `PanelsBench` on a 2.200-item
/// chat: 57 -> 115 fps opening and closing the panel, 55 -> 93 fps the sidebar.
///
/// The window's own hosting view is left as it is: it gives the window its minimum size.
struct ColumnSizing: NSViewRepresentable {
    /// Only here so that the panel opening updates this view: the panel's column may be made by then.
    let panelIsOpen: Bool

    func makeNSView(context: Context) -> TrimView { TrimView() }

    func updateNSView(_ view: TrimView, context: Context) { view.trimSoon() }

    final class TrimView: NSView {
        /// The hosting views already trimmed (a view that goes away leaves the table by itself).
        private let trimmed = NSHashTable<NSView>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trimSoon()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Joining the window and updating happen while SwiftUI updates its views, and the panel's column may only exist after
        /// the first opening: it waits a turn of the main loop, and looks again when the window is done with its next layout.
        func trimSoon() {
            DispatchQueue.main.async { [weak self] in self?.trim() }
        }

        private func trim() {
            #if DEBUG || ORB_DEV_TOOLS
            if ProcessInfo.processInfo.environment["ORB_NO_SIZING_TRIM"] != nil { return } // the "before" of `PanelsBench`
            #endif
            guard let root = window?.contentView else { return }
            func visit(_ view: NSView) {
                // `NSHostingView<Content>` is generic over private types, so it is told apart by name and reached through a
                // protocol (the cast finds the conformance of its real `Content`); the window's own `AppKitWindowHostingView`
                // is another class.
                if String(describing: type(of: view)).hasPrefix("NSHostingView<"), !trimmed.contains(view),
                   let column = view as? SizingTrimmable {
                    trimmed.add(view)
                    column.trimSizing()
                }
                view.subviews.forEach(visit)
            }
            visit(root)
        }
    }
}

/// A column's hosting view, whatever its content: lets `ColumnSizing` turn off its size answers.
@MainActor
protocol SizingTrimmable {
    func trimSizing()
}

extension NSHostingView: SizingTrimmable {
    func trimSizing() { sizingOptions = [] }
}
