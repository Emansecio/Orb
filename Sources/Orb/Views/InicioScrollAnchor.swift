import AppKit
import SwiftUI

/// Keeps the beginning of the results at the same visible position when sections above it change height.
/// Coordinates are kept outside SwiftUI state, so scrolling does not invalidate the page for every pixel.
@MainActor final class InicioScrollAnchor {
    weak var scrollView: NSScrollView?
    private var previousDocumentY: CGFloat?
    private var previousViewportY: CGFloat?

    func observe(viewportY: CGFloat) {
        guard let scrollView else { previousDocumentY = nil; previousViewportY = nil; return }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        let documentY = viewportY + origin.y
        defer { previousDocumentY = documentY; previousViewportY = viewportY }
        guard let previousDocumentY, let previousViewportY, previousViewportY < 0 else { return }
        let change = documentY - previousDocumentY
        guard abs(change) > 0.5 else { return }
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clip.bounds.height)
        let adjusted = min(max(origin.y + change, 0), maxY)
        clip.scroll(to: NSPoint(x: origin.x, y: adjusted))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Finds the owning scroll view without replacing its delegate or installing a second scroll observer.
struct InicioScrollAnchorBridge: NSViewRepresentable {
    let anchor: InicioScrollAnchor
    func makeNSView(context: Context) -> Probe { Probe(anchor: anchor) }
    func updateNSView(_ view: Probe, context: Context) { view.connect() }

    final class Probe: NSView {
        private let anchor: InicioScrollAnchor
        init(anchor: InicioScrollAnchor) { self.anchor = anchor; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        func connect() { if let scroll = enclosingScrollView { anchor.scrollView = scroll } }
    }
}
