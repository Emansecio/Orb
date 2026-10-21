import Foundation

// The Orb's browser in the transcript (docs/TELA-AO-VIVO.md, 3): a turn that uses it gets one `.browserView` item, opened at
// the first browser tool, counting each action and closed when the turn ends. Only words are kept in the item; the page
// itself is never written anywhere (`LiveFrameStore`).

extension BotSession {
    /// Opens this turn's browser item at its first browser tool and counts the action on it. One change of the transcript per
    /// action, never per frame. With the setting off no item is opened (a use already open goes on counting and closes as usual).
    func noteBrowserTool(_ call: ToolCall) {
        guard let model, LiveScreenBrowser.countsAsUse(call) else { return }
        let store = model.liveScreens.store(id)
        let opened = call.title == LiveScreenBrowser.openTitle ? LiveScreenText.host(of: WorkPhrase.firstLine(of: call.detail)) : nil
        let host = LiveScreenText.host(of: store.url) ?? opened
        if let itemID = browserViewID {
            mutateItems { items in
                guard let index = items.lastIndex(where: { $0.id == itemID }), case .browserView(var view) = items[index].kind else { return }
                view.actions += 1
                if let host { view.host = host }
                items[index].kind = .browserView(view)
            }
            return
        }
        guard LiveScreenSetting.isOn(), call.title != LiveScreenBrowser.closeTitle else { return }
        let item = TranscriptItem(.browserView(BrowserViewItem(host: host ?? "", startedAt: .now, actions: 1)))
        browserViewID = item.id
        mutateItems { $0.append(item) }
    }

    /// Closes this turn's browser item: the end time, the page it ended on, how it ended. The hub keeps the last picture first,
    /// so the closing line already finds it when it appears.
    func closeBrowserView(_ outcome: BrowserViewItem.Outcome) {
        guard let itemID = browserViewID, let model else { return }
        browserViewID = nil
        let path = LiveScreenText.path(of: model.liveScreens.store(id).url)
        model.liveScreens.endUse(id, itemID: itemID)
        mutateItems { items in
            guard let index = items.lastIndex(where: { $0.id == itemID }), case .browserView(var view) = items[index].kind else { return }
            view.outcome = outcome
            view.endedAt = .now
            if let path { view.lastPath = path }
            items[index].kind = .browserView(view)
        }
    }

    /// Tells the hub whether a hand-off card is open, so the page is protected while it is. Only while this turn has a card.
    func syncHandoffPending() {
        guard browserViewID != nil, let model else { return }
        let pending = (conversation?.items ?? []).contains {
            if case .approval(let request) = $0.kind { request.isHandoff && request.decision == nil } else { false }
        }
        model.liveScreens.setHandoffPending(id, pending)
    }
}

enum LiveScreenBrowser {
    static let openTitle = "Abrindo página"
    static let closeTitle = "Fechando o navegador"
    /// `browser_tab` reads the person's own browser, not the Orb's: no page of it streams.
    static let readTabTitle = "Lendo a aba do navegador"

    /// A call of the Orb's own browser (`browse_*`).
    static func countsAsUse(_ call: ToolCall) -> Bool {
        call.kind == .browser && call.title != readTabTitle
    }
}

extension AppModel {
    /// The hand-off card the Orb waits on, when it waits on one. Reads the conversation only while the Orb waits for
    /// something, so a card that asks this does not depend on every change of the transcript.
    func pendingHandoff(of botID: UUID) -> ApprovalRequest? {
        guard live(botID).needsYou else { return nil }
        return pendingApprovals(of: botID).last { $0.isHandoff }
    }

    /// Whether the live card of this Orb's turn stands for its hand-off card (the permission card then draws nothing).
    func liveCardDrawsHandoff(of botID: UUID) -> Bool {
        sessions[botID]?.browserViewID != nil
    }
}
