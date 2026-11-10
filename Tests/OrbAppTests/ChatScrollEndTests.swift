import AppKit
import SwiftUI
import Testing
@testable import Orb

/// Part of `OrbDriverTests` so it runs serialized with it: the chat puts the replies' avatars on screen, and those tests count
/// the orbs of the one shared driver.
extension OrbDriverTests {
    /// A long conversation already in memory (the window opened again, an Orb shown again) opened blank on macOS 15: the
    /// scroll view's initial offset put the view at the end of a content measured by estimate, where the lazy stack had laid
    /// out no row, and only a scroll of the user brought them. Opened twice: the first chat of a process never showed it.
    @Test func aLongChatAlreadyInMemoryOpensWithItsLastRowsOnShow() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        try #require(NSScreen.main != nil)
        let root = TempFolder("OrbChatEnd")
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false)
        let bot = try #require(model.bots.first)
        model.seedConversation(Self.longChat(), for: bot.id)
        for opening in 1...2 {
            let host = NSHostingView(rootView: ChatView(botID: bot.id).environment(model).frame(width: 1100, height: 760))
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1100, height: 760),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = host
            window.orderFrontRegardless()
            defer {
                window.contentView = NSView()
                window.orderOut(nil)
            }
            await waitUntil("the chat's scroll view (opening \(opening))") { Self.chatScroll(in: host) != nil }
            let scroll = try #require(Self.chatScroll(in: host))
            // Nothing scrolls it here: the rows have to be there on their own.
            let shown = await waitUntil("rows in view (opening \(opening))", timeout: .seconds(5)) { Self.rowsInView(scroll) > 0 }
            #expect(shown, "opening \(opening) showed only the canvas")
            let document = try #require(scroll.documentView)
            #expect(document.frame.height - scroll.contentView.bounds.maxY < FollowRule.slack, "opening \(opening) is not at the end")
        }
    }

    /// Replies of every length, so the lazy stack's estimate of the rows it has not measured is far from their height.
    private static func longChat() -> Conversation {
        var items: [TranscriptItem] = []
        let start = Date.now.addingTimeInterval(-86_400)
        for index in 0..<120 {
            var user = TranscriptItem(.user(text: "Pergunta \(index): " + String(repeating: "como está isso? ", count: index % 7 + 1),
                                            attachments: []))
            user.date = start.addingTimeInterval(Double(index) * 600)
            let text = [TranscriptSample.markdown, TranscriptSample.routineReport, "Resposta curta \(index)."][index % 3]
            var reply = TranscriptItem(.bot(text: text, isStreaming: false))
            reply.date = user.date.addingTimeInterval(30)
            items += [user, reply]
        }
        return Conversation(items: items)
    }

    /// The chat's scroll view: the one with the tallest content, once it holds more than a screen.
    private static func chatScroll(in view: NSView) -> NSScrollView? {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let tallest = scrollViews(in: view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        return (tallest?.documentView?.frame.height ?? 0) > 3000 ? tallest : nil
    }

    /// The replies' texts (each one a text view) laid out in the visible part of the chat.
    private static func rowsInView(_ scroll: NSScrollView) -> Int {
        guard let document = scroll.documentView else { return 0 }
        func textViews(in view: NSView) -> [NSView] { (view is NSTextView ? [view] : []) + view.subviews.flatMap(textViews) }
        let visible = scroll.contentView.bounds
        return textViews(in: document).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: scroll.contentView).intersects(visible)
        }.count
    }
}
