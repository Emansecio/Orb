#if DEBUG || ORB_DEV_TOOLS
import AppKit
import SwiftUI

/// Scenes for review: `Orb --snapshot transcript-browser-live|transcript-browser-need|transcript-browser-done|inspector-screen out.png`.
/// The store is seeded with a drawn page (no browser runs), so the card, the hand-off and the panel's tab show with a
/// picture. Dev aid; nothing is saved.
@MainActor
enum LiveScreenSnapshots {
    /// The items of a chat scene, and the store and session state that goes with them.
    static func items(_ screen: String, model: AppModel, bot: Bot) -> [TranscriptItem] {
        LiveScreenLayerView.countsOffscreenWindows = true
        let user = TranscriptItem(.user(text: "Confere os pagamentos de hoje no painel e me diz quem falta entregar.", attachments: []))
        let intro = TranscriptItem(.bot(text: "Vou abrir o painel do checkout e filtrar os pagamentos de hoje.", isStreaming: false))
        func tool(_ title: String, _ detail: String, state: ToolCall.State = .done) -> TranscriptItem {
            TranscriptItem(.tool(ToolCall(kind: .browser, title: title, detail: detail, state: state, output: state == .done ? "ok" : nil)))
        }
        var view = BrowserViewItem(host: "checkout.acessosfit.com.br", startedAt: .now.addingTimeInterval(-95), actions: 6)
        let store = model.liveScreens.store(bot.id)
        switch screen {
        case "transcript-browser-need":
            let card = TranscriptItem(.browserView(view))
            model.session(bot.id).browserViewID = card.id
            seed(store, url: "https://checkout.acessosfit.com.br/login", isProtected: true)
            var request = ApprovalRequest.handoff(botName: bot.name, page: "https://checkout.acessosfit.com.br/login — “Entrar”")
            request.reason = "Termine lá o que falta (entrar no site, digitar um código, resolver a verificação) e clique em Pronto."
            model.setAwaitingApproval(true, of: bot.id)
            return [user, intro, card, tool("Abrindo página", "https://checkout.acessosfit.com.br"),
                    tool("Mostrando o navegador para você", "", state: .running), TranscriptItem(.approval(request))]
        case "transcript-browser-done":
            view.outcome = .done
            view.endedAt = .now
            view.actions = 14
            view.lastPath = "/pagamentos"
            seed(store, url: nil, isProtected: false)
            return [user, intro, TranscriptItem(.browserView(view)), tool("Abrindo página", "https://checkout.acessosfit.com.br"),
                    tool("Clicando em Pagamentos", ""),
                    TranscriptItem(.bot(text: "Hoje entraram 2 pagamentos e 1 está pendente.", isStreaming: false))]
        default:
            let card = TranscriptItem(.browserView(view))
            model.session(bot.id).browserViewID = card.id
            seed(store, url: "https://checkout.acessosfit.com.br/pagamentos", isProtected: false)
            model.live(bot.id).setWork(WorkLine(verb: "Clicando em", target: "Pagamentos"))
            return [user, intro, card, tool("Abrindo página", "https://checkout.acessosfit.com.br"),
                    tool("Clicando em Pagamentos", "", state: .running)]
        }
    }

    /// The panel's tab on a live page.
    static func tab(model: AppModel, botID: UUID) {
        LiveScreenLayerView.countsOffscreenWindows = true
        seed(model.liveScreens.store(botID), url: "https://checkout.acessosfit.com.br/pagamentos", isProtected: false)
    }

    private static func seed(_ store: LiveFrameStore, url: String?, isProtected: Bool) {
        store.setURL(url)
        store.setProtected(isProtected)
        guard url != nil else { return }
        store.setPhase(.live)
        store.deliver(frame())
    }

    /// The Orb's pointer on the "Pagamentos" entry of the menu, once the views are listening for it (pointers are not replayed).
    static func point(model: AppModel, botID: UUID) async {
        try? await Task.sleep(for: .milliseconds(500))
        model.liveScreens.store(botID).point(LivePointer(rect: CGRect(x: 60, y: 120, width: 160, height: 48), kind: .click))
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// A drawn page, 640 x 400 px for a 1280 x 800 viewport: a bar on top, a menu on the left and a table.
    static func frame() -> LiveFrame {
        let size = CGSize(width: 640, height: 400)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ hex: UInt32, _ rect: CGRect) {
            context.setFillColor(NSColor(hex: hex).cgColor)
            // Drawn from the top left, as a page is.
            context.fill(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        }
        fill(0xF4F6F9, CGRect(origin: .zero, size: size))
        fill(0xFFFFFF, CGRect(x: 0, y: 0, width: 640, height: 40))
        fill(0xE3E7EE, CGRect(x: 0, y: 40, width: 640, height: 1))
        fill(0xFFFFFF, CGRect(x: 0, y: 41, width: 150, height: 359))
        fill(0xE8F0FF, CGRect(x: 10, y: 58, width: 130, height: 28))
        for (index, width) in [96, 70, 80].enumerated() {
            fill(0xC9D0DA, CGRect(x: 22, y: 100 + index * 36, width: width, height: 8))
        }
        fill(0xFFFFFF, CGRect(x: 180, y: 130, width: 440, height: 130))
        for row in 0..<4 {
            fill(0xEEF1F5, CGRect(x: 180, y: 160 + row * 32, width: 440, height: 1))
            fill(0xC9D0DA, CGRect(x: 196, y: 140 + row * 32, width: 70 + row * 14, height: 8))
            fill(row == 2 ? 0xFFE08A : 0xBFE8D2, CGRect(x: 560, y: 138 + row * 32, width: 44, height: 12))
        }
        fill(0xD5DAE2, CGRect(x: 180, y: 76, width: 220, height: 30))
        return LiveFrame(image: context.makeImage()!, viewport: CGSize(width: 1280, height: 800), scroll: .zero,
                         timestamp: .now, isStale: false)
    }
}
#endif
