import AppKit
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

/// The motion that only exists for someone watching (Ajustes → Navegador): the cursor takes `travel` to arrive before the action
/// goes, scrolling moves in steps, and a still cursor pulses. On by default. Off, or with Reduce Motion on, the tools do what they
/// did before: no wait, one scroll, the cursor jumps.
enum LiveMotion {
    static let key = "animateBrowserCursor"
    /// How long the cursor takes to get to its target, and how long the action waits for it (the layer animates the same time).
    static let travelSeconds = 0.2
    static let travel = Duration.seconds(travelSeconds)
    /// A cursor that stays still this long between two actions starts to pulse: the Orb is thinking.
    static let idleBeforePulse: TimeInterval = 0.6

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// The setting is on and Reduce Motion is off. Asked from any thread: the system's flag is read on the main actor.
    static func animates(_ defaults: UserDefaults = .standard) async -> Bool {
        guard isOn(defaults) else { return false }
        return await MainActor.run { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    /// A scroll of `pixels` as the steps of an ease-in-out curve whose sum is exactly `pixels`; one step (no animation) when it is
    /// too short for several to show.
    static func scrollSteps(_ pixels: Int) -> [Int] {
        let count = min(7, pixels / 50)
        guard count >= 2 else { return [pixels] }
        var steps: [Int] = []
        var done = 0
        for index in 1...count {
            let t = Double(index) / Double(count)
            let position = index == count ? pixels : Int((Double(pixels) * t * t * (3 - 2 * t)).rounded())
            if position > done { steps.append(position - done) }
            done = max(done, position)
        }
        return steps
    }

    /// The pause between two steps: about a quarter of a second for the whole scroll.
    static let scrollPause = Duration.milliseconds(35)
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
    /// The person took the browser over in the window: the thumbnail does not show the page (the window does).
    case youControl
    /// Another Orb's screen is the one streaming now.
    case paused
    /// The browser went away or the stream broke.
    case failed
    /// The use is over: the closing line, not the card.
    case ended

    /// How the page is covered.
    enum Veil: Equatable, Sendable { case none, blur, opaque }

    /// A button of the card's third line.
    enum Button: Equatable, Sendable { case enlarge, stop, hide, reveal, done, cancel, giveBack }

    /// Most urgent first: the hand-off, then a protected page, the person's own "Privado" (a broken stream still shows its last
    /// frame, so it hides that too), a broken stream, and last what the stream says.
    static func of(outcome: BrowserViewItem.Outcome, phase: LiveFrameStore.Phase, isProtected: Bool, isPrivate: Bool,
                   handoff: Bool, userControls: Bool = false) -> LiveCardState {
        guard outcome == .running else { return .ended }
        if handoff { return .needsYou }
        // A broken stream under the person's hands is shown: they would type into a dead picture otherwise.
        if userControls { return phase == .failed ? .failed : .youControl }
        if isProtected { return .protected }
        if isPrivate { return .privateView }
        if phase == .failed { return .failed }
        switch phase {
        case .live: return .live
        case .paused: return .paused
        case .idle, .connecting: return .connecting
        case .failed: return .failed
        }
    }

    var veil: Veil {
        switch self {
        case .needsYou, .protected, .youControl: .opaque
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
        case .youControl: "Você no controle"
        case .paused: "Pausado"
        case .protected, .failed, .ended: nil
        }
    }

    /// The dot of the chip breathes only while the page is live.
    var pulses: Bool { self == .live || self == .privateView }

    var buttons: [Button] {
        switch self {
        case .live, .connecting: [.enlarge, .stop, .hide]
        case .paused: [.enlarge, .stop]
        case .needsYou: [.done, .cancel]
        case .protected: [.enlarge]
        case .privateView: [.reveal, .stop]
        case .youControl: [.enlarge, .giveBack]
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
        case .live, .privateView:
            ["Escrevendo…", "Pensando…"].contains(work ?? "") ? "Visualização do navegador" : (work ?? "Abrindo o navegador…")
        case .connecting: work ?? "Abrindo o navegador…"
        case .needsYou: handoffCaption(page: handoffPage ?? "")
        case .youControl: "O Orb espera você devolver o navegador"
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
        case .youControl: "Na janela"
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
        case .youControl: "Você está no controle do navegador"
        case .live, .connecting, .privateView, .ended: nil
        }
    }
}

/// Where the Orb's pointer is on a layer that shows a picture of the page.
enum LiveCursor {
    /// The box the driver resolves (`get box`) is already in viewport pixels, scroll taken off, so the picture's scroll is not
    /// applied; `true` would treat boxes as page coordinates.
    static let boxIsPageRelative = false

    /// The point, from the layer's top left, where the middle of `box` is drawn when the picture (`imageSize` in pixels) fills
    /// a layer of `layerSize` the way `resizeAspectFill` does (`fits`: whole, as `resizeAspect` does, in the window). nil when
    /// the picture has no usable viewport. Clamped to the layer: a box outside the viewport leaves the pointer at the nearest edge.
    static func point(of box: CGRect, viewport: CGSize, scroll: CGPoint, imageSize: CGSize, layerSize: CGSize,
                      fits: Bool = false) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0, imageSize.width > 0, imageSize.height > 0,
              layerSize.width > 0, layerSize.height > 0 else { return nil }
        let inViewport = CGPoint(x: box.midX - (boxIsPageRelative ? scroll.x : 0),
                                 y: box.midY - (boxIsPageRelative ? scroll.y : 0))
        let onImage = CGPoint(x: inViewport.x * imageSize.width / viewport.width,
                              y: inViewport.y * imageSize.height / viewport.height)
        let widthScale = layerSize.width / imageSize.width, heightScale = layerSize.height / imageSize.height
        let scale = fits ? min(widthScale, heightScale) : max(widthScale, heightScale)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let x = (layerSize.width - shown.width) / 2 + onImage.x * scale
        let y = (layerSize.height - shown.height) / 2 + onImage.y * scale
        return CGPoint(x: min(max(x, 0), layerSize.width), y: min(max(y, 0), layerSize.height))
    }
}
