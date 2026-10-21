import CoreGraphics
import Foundation

// The plain logic of the live screen's interface (docs/TELA-AO-VIVO.md, 3): which state the card is in, the words it and
// its closing line say, and where the Orb's pointer lands on a picture. No view in here, so it is tested without one.

/// The switch in Ajustes → Navegador. On by default; off, a turn adds no `.browserView` item and nothing connects.
enum LiveScreenSetting {
    static let key = "showBrowserScreen"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// What the card shows. One state at a time, chosen by `of(...)` from what the stream and the turn say.
enum LiveCardState: Equatable, Sendable {
    /// The page, with the Orb's pointer on it.
    case live
    /// Nothing has come yet (the stream is opening).
    case connecting
    /// A hand-off waits for the person (a login, a code, a captcha): the page is opaque.
    case needsYou
    /// The page shows a secret: opaque, with no way to look.
    case protected
    /// Hidden by the person ("Privado"): blurred.
    case privateView
    /// Another Orb's screen is the one streaming now.
    case paused
    /// The browser went away or the stream broke.
    case failed
    /// The use is over: the closing line, not the card.
    case ended

    /// How the page is covered.
    enum Veil: Equatable, Sendable { case none, blur, opaque }

    /// A button of the card's third line.
    enum Button: Equatable, Sendable { case enlarge, stop, hide, reveal, done, cancel }

    /// Most urgent first: the hand-off, then a protected page, a broken stream, the person's own "Privado", and last what
    /// the stream says.
    static func of(outcome: BrowserViewItem.Outcome, phase: LiveFrameStore.Phase, isProtected: Bool, isPrivate: Bool,
                   handoff: Bool) -> LiveCardState {
        guard outcome == .running else { return .ended }
        if handoff { return .needsYou }
        if isProtected { return .protected }
        if phase == .failed { return .failed }
        if isPrivate { return .privateView }
        switch phase {
        case .live: return .live
        case .paused: return .paused
        case .idle, .connecting: return .connecting
        case .failed: return .failed
        }
    }

    var veil: Veil {
        switch self {
        case .needsYou, .protected: .opaque
        case .privateView: .blur
        default: .none
        }
    }

    /// Whether frames are drawn at all. An opaque page never reaches the thumbnail, so nothing could leak from it.
    var showsFrames: Bool { veil != .opaque }

    /// The last picture shown dimmed: a broken stream and a paused one hold what they had.
    var dimsPage: Bool { self == .failed || self == .paused }

    /// The Orb's pointer is drawn only over a page that is live.
    var showsPointer: Bool { self == .live }

    /// The small word beside the host (nil: none, as for a protected page or an error).
    var chip: String? {
        switch self {
        case .live, .privateView: "Ao vivo"
        case .connecting: "Conectando"
        case .needsYou: "Precisa de você"
        case .paused: "Pausado"
        case .protected, .failed, .ended: nil
        }
    }

    /// The dot of the chip breathes only while the page is live.
    var pulses: Bool { self == .live || self == .privateView }

    /// Only the working states shimmer their caption: a wait or an error is still.
    var shimmers: Bool { self == .live || self == .connecting || self == .privateView }

    var buttons: [Button] {
        switch self {
        case .live, .connecting: [.enlarge, .stop, .hide]
        case .paused: [.enlarge, .stop]
        case .needsYou: [.done, .cancel]
        case .protected: [.enlarge]
        case .privateView: [.reveal, .stop]
        case .failed, .ended: []
        }
    }

    /// Whether a click on the thumbnail opens the larger view (a hidden or opaque page has nothing more to show there,
    /// except a protected one, whose larger view says why).
    var enlarges: Bool { self != .failed && self != .ended && self != .needsYou }
}

/// The words of the card and of its closing line.
enum LiveScreenText {
    /// "checkout.acessosfit.com.br" for "https://www.checkout.acessosfit.com.br/pagamentos"; nil for what has no host.
    static func host(of address: String?) -> String? {
        guard let address, let host = URL(string: address)?.host(percentEncoded: false), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "/pagamentos" for "https://x.com/pagamentos?id=7#top": the path alone, never the query (it may carry a token).
    /// nil when the address has no host; a long path is cut in the middle.
    static func path(of address: String?, limit: Int = 40) -> String? {
        guard let address, let url = URL(string: address), url.host(percentEncoded: false) != nil else { return nil }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        guard path.count > limit else { return path }
        let half = (limit - 1) / 2
        return path.prefix(half) + "…" + path.suffix(half)
    }

    /// "45 s", "2 min", "1 h 05 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return ElapsedFormat.text(seconds: total)
    }

    /// "1 ação", "14 ações".
    static func actions(_ count: Int) -> String { count == 1 ? "1 ação" : "\(count) ações" }

    /// The closing line: "Usou o navegador · checkout.acessosfit · 2 min · 14 ações · terminou em /pagamentos". What is not
    /// known is left out (a use cut by a crash has no end time).
    static func closingLine(_ view: BrowserViewItem) -> String {
        var parts = ["Usou o navegador"]
        if !view.host.isEmpty { parts.append(view.host) }
        if let end = view.endedAt, end > view.startedAt { parts.append(duration(end.timeIntervalSince(view.startedAt))) }
        if view.actions > 0 { parts.append(actions(view.actions)) }
        if let path = view.lastPath, !path.isEmpty {
            let verb = switch view.outcome {
            case .failed: "falhou em"
            case .stopped: "parou em"
            case .done, .running: "terminou em"
            }
            parts.append("\(verb) \(path)")
        }
        return parts.joined(separator: " · ")
    }

    /// What the opaque thumbnail of a hand-off says under its lock, from the page the card names (`ApprovalRequest.command`).
    static func handoffVeil(page: String) -> String {
        switch BrowserHandoff.reason(url: page, title: page) {
        case "a login page", "a login form": "Página de login"
        case "a bot check (captcha)": "Verificação"
        case "a verification code (2FA) request": "Código de verificação"
        default: "Precisa de você"
        }
    }

    /// The card's caption for a hand-off: what the person has to do there.
    static func handoffCaption(page: String) -> String {
        switch BrowserHandoff.reason(url: page, title: page) {
        case "a login page", "a login form": "Entre na sua conta para o Orb continuar"
        case "a bot check (captcha)": "Resolva a verificação para o Orb continuar"
        case "a verification code (2FA) request": "Digite o código para o Orb continuar"
        default: "Termine no navegador para o Orb continuar"
        }
    }

    /// The caption under the chip. `work` is what the Orb says it is doing; `lastAction` what it did before the browser went.
    static func caption(for state: LiveCardState, work: String?, handoffPage: String?, lastAction: String?) -> String {
        switch state {
        case .live, .connecting, .privateView: work ?? "Abrindo o navegador…"
        case .needsYou: handoffCaption(page: handoffPage ?? "")
        case .protected: "Conteúdo protegido"
        case .paused: "Pausado: outro Orb está na tela"
        case .failed: lastAction.map { "O navegador fechou · última ação: \($0)" } ?? "O navegador fechou"
        case .ended: ""
        }
    }

    /// What the thumbnail says under its lock for a state that covers the page.
    static func veilText(for state: LiveCardState, handoffPage: String?) -> String {
        switch state {
        case .needsYou: handoffVeil(page: handoffPage ?? "")
        case .privateView: "Privado"
        default: "Protegido"
        }
    }

    /// What VoiceOver says for the card: its kind and what the Orb is doing.
    static func spoken(caption: String) -> String { "Tela ao vivo, navegador, \(caption)" }

    /// What VoiceOver is told when the state changes (nil: nothing to say).
    static func announcement(for state: LiveCardState) -> String? {
        switch state {
        case .needsYou: "O Orb precisa de você no navegador"
        case .protected: "Conteúdo protegido"
        case .failed: "O navegador fechou"
        case .paused: "Tela pausada"
        case .live, .connecting, .privateView, .ended: nil
        }
    }
}

/// Where the Orb's pointer is on a layer that shows a picture of the page.
enum LiveCursor {
    /// The box the driver resolves is taken as page coordinates (CSS pixels from the top of the document), so the scroll of the
    /// picture is taken off to land on it; the WP-A driver says if its boxes are relative to the viewport instead.
    static let boxIsPageRelative = true

    /// The point, from the layer's top left, where the middle of `box` is drawn when the picture (`imageSize` in pixels) fills
    /// a layer of `layerSize` the way `resizeAspectFill` does. nil when the picture has no usable viewport. Clamped to the
    /// layer: a box outside the viewport leaves the pointer at the nearest edge.
    static func point(of box: CGRect, viewport: CGSize, scroll: CGPoint, imageSize: CGSize, layerSize: CGSize) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0, imageSize.width > 0, imageSize.height > 0,
              layerSize.width > 0, layerSize.height > 0 else { return nil }
        let inViewport = CGPoint(x: box.midX - (boxIsPageRelative ? scroll.x : 0),
                                 y: box.midY - (boxIsPageRelative ? scroll.y : 0))
        let onImage = CGPoint(x: inViewport.x * imageSize.width / viewport.width,
                              y: inViewport.y * imageSize.height / viewport.height)
        let scale = max(layerSize.width / imageSize.width, layerSize.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let x = (layerSize.width - shown.width) / 2 + onImage.x * scale
        let y = (layerSize.height - shown.height) / 2 + onImage.y * scale
        return CGPoint(x: min(max(x, 0), layerSize.width), y: min(max(y, 0), layerSize.height))
    }
}
