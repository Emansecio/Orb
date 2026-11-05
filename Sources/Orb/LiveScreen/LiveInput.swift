import AppKit

// The person's input to the Orb's page while they have its browser (docs/TELA-AO-VIVO.md, 7): where a click on the window's
// picture lands on the page, and the stream's messages for mouse and keys (agent-browser 0.39's `input_mouse` and
// `input_keyboard`, the same ones its own dashboard sends; checked against a live browser: click, typing, an accented
// letter, Backspace and the wheel). Plain functions, tested without a view. Nothing here keeps or logs what is typed.

enum LiveInput {
    // MARK: Where on the page

    /// The point of the page (its viewport's CSS pixels, from the top left) under `point` (from the top left of a layer of
    /// `layerSize` that shows the picture whole, as `resizeAspect` does). nil off the picture (the bars beside it) or
    /// without a usable picture.
    static func pagePoint(_ point: CGPoint, layerSize: CGSize, imageSize: CGSize, viewport: CGSize) -> CGPoint? {
        guard let shown = shownRect(layerSize: layerSize, imageSize: imageSize), viewport.width > 0, viewport.height > 0,
              shown.contains(point) else { return nil }
        return CGPoint(x: ((point.x - shown.minX) / shown.width * viewport.width).rounded(),
                       y: ((point.y - shown.minY) / shown.height * viewport.height).rounded())
    }

    /// Where the picture is drawn in the layer (from the top left), fitted whole and centered.
    static func shownRect(layerSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, layerSize.width > 0, layerSize.height > 0 else { return nil }
        let scale = min(layerSize.width / imageSize.width, layerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (layerSize.width - size.width) / 2, y: (layerSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The page's CSS pixels in one point of the layer (for the wheel, whose deltas come in points).
    static func pagePixelsPerPoint(layerSize: CGSize, imageSize: CGSize, viewport: CGSize) -> CGFloat {
        guard let shown = shownRect(layerSize: layerSize, imageSize: imageSize), viewport.width > 0 else { return 1 }
        return viewport.width / shown.width
    }

    // MARK: Mouse

    enum MouseEvent: String { case pressed = "mousePressed", released = "mouseReleased", moved = "mouseMoved", wheel = "mouseWheel" }
    enum MouseButton: String { case left, right, middle, none }

    static func mouse(_ event: MouseEvent, at point: CGPoint, button: MouseButton, clickCount: Int = 0,
                      modifiers: NSEvent.ModifierFlags = [], delta: CGVector = .zero) -> String {
        var message: [String: Any] = [
            "type": "input_mouse", "eventType": event.rawValue, "x": point.x, "y": point.y,
            "button": button.rawValue, "clickCount": clickCount, "modifiers": bits(of: modifiers),
        ]
        if event == .wheel {
            message["deltaX"] = delta.dx
            message["deltaY"] = delta.dy
        }
        return json(message)
    }

    /// The wheel's deltas for the page: the trackpad's in points, a mouse wheel's in lines (about 40 pixels each), and with
    /// the sign the page expects (positive scrolls down), whatever "natural scrolling" is set to.
    static func wheelDelta(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, precise: Bool, pixelsPerPoint: CGFloat) -> CGVector {
        let unit = (precise ? 1 : 40) * pixelsPerPoint
        // `scrollingDelta` is how the content moves (negative: it goes up, showing what is below), with "natural scrolling"
        // already counted in; the page wants how far its view goes, the opposite.
        return CGVector(dx: (-scrollingDeltaX * unit).rounded(), dy: (-scrollingDeltaY * unit).rounded())
    }

    // MARK: Keys

    /// A key that types nothing, as the page knows it: its name, its code and its Windows key code (`text` is what it types).
    private struct NamedKey {
        let key: String
        let code: String
        let windowsCode: Int
        var text: String?
    }

    /// By the Mac's key code (layout independent), the keys a page has to know by name.
    private static let namedKeys: [UInt16: NamedKey] = [
        36: NamedKey(key: "Enter", code: "Enter", windowsCode: 13, text: "\r"),
        76: NamedKey(key: "Enter", code: "NumpadEnter", windowsCode: 13, text: "\r"),
        48: NamedKey(key: "Tab", code: "Tab", windowsCode: 9),
        51: NamedKey(key: "Backspace", code: "Backspace", windowsCode: 8),
        117: NamedKey(key: "Delete", code: "Delete", windowsCode: 46),
        53: NamedKey(key: "Escape", code: "Escape", windowsCode: 27),
        123: NamedKey(key: "ArrowLeft", code: "ArrowLeft", windowsCode: 37),
        124: NamedKey(key: "ArrowRight", code: "ArrowRight", windowsCode: 39),
        125: NamedKey(key: "ArrowDown", code: "ArrowDown", windowsCode: 40),
        126: NamedKey(key: "ArrowUp", code: "ArrowUp", windowsCode: 38),
        115: NamedKey(key: "Home", code: "Home", windowsCode: 36),
        119: NamedKey(key: "End", code: "End", windowsCode: 35),
        116: NamedKey(key: "PageUp", code: "PageUp", windowsCode: 33),
        121: NamedKey(key: "PageDown", code: "PageDown", windowsCode: 34),
    ]

    /// The message for a key going down or up; nil for what stays with the app (⌘ shortcuts, a dead key still waiting for
    /// its letter, a function key the page has no name for). `characters` is what the Mac typed with the layout in use
    /// (ABNT2's ç, an accent and its letter), so the page gets the same letter the person sees.
    static func key(down: Bool, keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.contains(.command) { return nil }
        let eventType = down ? "keyDown" : "keyUp"
        if let named = namedKeys[keyCode] {
            var message: [String: Any] = ["type": "input_keyboard", "eventType": eventType, "key": named.key, "code": named.code,
                                          "windowsVirtualKeyCode": named.windowsCode, "modifiers": bits(of: modifiers)]
            if down, let text = named.text { message["text"] = text }
            return json(message)
        }
        guard let characters, isTypable(characters) else { return nil }
        var message: [String: Any] = ["type": "input_keyboard", "eventType": eventType, "key": characters,
                                      "windowsVirtualKeyCode": windowsCode(of: characters), "modifiers": bits(of: modifiers)]
        if characters == " " { message["code"] = "Space" }
        // Control with a letter is a shortcut of the page (⌃A), not text.
        if down, !modifiers.contains(.control) { message["text"] = characters }
        return json(message)
    }

    /// The most a paste types: past it the rest is left out (a key per character goes over the stream).
    static let pasteLimit = 20_000

    /// Text pasted into the page, typed a character at a time (the stream types one key's text and nothing longer, measured on
    /// 0.39: a whole string in one key, or a `char` event, types nothing); a line break is Enter. Empty for nothing to type.
    static func text(_ text: String) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return clean.prefix(pasteLimit).compactMap { character -> String? in
            if character == "\n" { return key(down: true, keyCode: 36, characters: "\r", modifiers: []) }
            if character == "\t" { return key(down: true, keyCode: 48, characters: "\t", modifiers: []) }
            let typed = String(character)
            guard isTypable(typed) else { return nil }
            return json(["type": "input_keyboard", "eventType": "keyDown", "key": typed, "text": typed,
                         "windowsVirtualKeyCode": windowsCode(of: typed), "modifiers": 0])
        }
    }

    /// Something to type: no control character, and none of the Mac's private codes for function keys (F1, the arrows…).
    private static func isTypable(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// A letter's or a digit's Windows key code is its capital's ASCII; anything else has none the page needs.
    private static func windowsCode(of characters: String) -> Int {
        guard characters.count == 1, let scalar = characters.uppercased().unicodeScalars.first, scalar.isASCII else { return 0 }
        let value = Int(scalar.value)
        return (65...90).contains(value) || (48...57).contains(value) || value == 32 ? value : 0
    }

    /// The page's modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
    static func bits(of modifiers: NSEvent.ModifierFlags) -> Int {
        (modifiers.contains(.option) ? 1 : 0) | (modifiers.contains(.control) ? 2 : 0)
            | (modifiers.contains(.command) ? 4 : 0) | (modifiers.contains(.shift) ? 8 : 0)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
