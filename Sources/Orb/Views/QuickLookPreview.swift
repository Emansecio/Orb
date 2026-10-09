import AppKit
import QuickLookUI

/// The system's Quick Look panel for the attachments of a message: the arrow keys go from one to the next and Esc
/// closes it. The panel asks this object for its items, so it needs nothing from the responder chain.
@MainActor
final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPreview()
    private var urls: [URL] = []

    /// Opens the panel on `paths[index]`. Files that are gone are left out (the click looks again); with nothing left
    /// there is nothing to show.
    static func show(_ paths: [String], at index: Int) {
        let (urls, start) = items(paths, at: index)
        guard !urls.isEmpty else { return }
        shared.urls = urls
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(urls[start])
            return
        }
        panel.dataSource = shared
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        panel.makeKeyAndOrderFront(nil)
    }

    /// The files that exist, and where the one asked for is among them (the next one when it is gone itself).
    nonisolated static func items(_ paths: [String], at index: Int,
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (urls: [URL], start: Int) {
        var urls: [URL] = []
        var start = 0
        for (position, path) in paths.enumerated() where path.hasPrefix("/") && exists(path) {
            if position < index { start += 1 }
            urls.append(URL(fileURLWithPath: path))
        }
        return (urls, min(start, max(urls.count - 1, 0)))
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }
}
