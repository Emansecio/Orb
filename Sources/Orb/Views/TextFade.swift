import AppKit
import QuartzCore

// The words of a reply being written fade in as they arrive instead of appearing at once. Only their colour changes, as
// the layout manager's temporary attributes, so nothing is laid out again; and only what a flush added to the text
// already shown fades: an edit, the finished reply, a paragraph that closed or a row made again show at once.

/// The words added to a streaming `ProseTextView`, fading in on one display link that runs only while a word fades.
@MainActor
final class TextFade: NSObject {
    /// How long a word takes to appear.
    static let duration: CFTimeInterval = 0.4
    /// The words a flush adds start one after the other across this span.
    static let stagger: CFTimeInterval = 0.1
    /// More words than this at once (a paste, a long paragraph a new view catches up with) appear at once.
    static let wordLimit = 160
    /// The live texts kept in `recent`.
    private static let recentLimit = 8
    /// What separates words; a line break inside a paragraph (U+2028) is one.
    private static let spaces = CharacterSet.whitespacesAndNewlines

    /// What the live views showed last (their text without the cursor), the latest first, so a view SwiftUI makes again
    /// for the paragraph being written (a row scrolled back into view) fades only what came since, not what was read.
    private static var recent: [String] = []

    private struct Word {
        let range: NSRange
        let color: NSColor
        let start: CFTimeInterval
    }

    private weak var view: NSTextView?
    private var words: [Word] = []
    private var link: CADisplayLink?

    init(view: NSTextView) {
        self.view = view
    }

    /// The range of `body` that is new: what it adds to `shown` (nil when it does not continue it), or, for a view that
    /// showed nothing yet, to the latest live text it continues (all of it when it continues none).
    static func added(_ body: String, after shown: String?) -> NSRange? {
        let previous = shown ?? recent.first { (body as NSString).hasPrefix($0) } ?? ""
        recent.removeAll { (body as NSString).hasPrefix($0) }
        recent.insert(body, at: 0)
        if recent.count > recentLimit { recent.removeLast() }
        return appended(to: previous, in: body)
    }

    /// The part of `new` after `old`, when `new` only adds to it; nil when it changed `old` or adds nothing.
    static func appended(to old: String, in new: String) -> NSRange? {
        let new = new as NSString, length = (old as NSString).length
        guard new.length > length, length == 0 || new.hasPrefix(old) else { return nil }
        return NSRange(location: length, length: new.length - length)
    }

    /// The words of `range` in `text`, also split where their attributes change, so each piece fades from its own colour
    /// (a link, a quote). Spaces and line breaks are left out: there is nothing in them to fade.
    static func words(in text: NSAttributedString, range: NSRange) -> [NSRange] {
        let string = text.string as NSString
        var words: [NSRange] = []
        text.enumerateAttributes(in: range) { _, run, _ in
            var start: Int?
            for index in run.location..<NSMaxRange(run) {
                let isSpace = UnicodeScalar(string.character(at: index)).map(spaces.contains) ?? false
                if isSpace, let begun = start {
                    words.append(NSRange(location: begun, length: index - begun))
                    start = nil
                } else if !isSpace, start == nil {
                    start = index
                }
            }
            if let begun = start { words.append(NSRange(location: begun, length: NSMaxRange(run) - begun)) }
        }
        return words
    }

    /// When the `index`th of `count` words added together starts, after the first.
    static func delay(of index: Int, among count: Int) -> CFTimeInterval {
        count > 1 ? stagger * CFTimeInterval(index) / CFTimeInterval(count - 1) : 0
    }

    /// How visible a word is `elapsed` seconds after it started: eased out, so it comes quickly and settles softly.
    static func opacity(at elapsed: CFTimeInterval) -> CGFloat {
        let progress = min(max(elapsed / duration, 0), 1)
        return 1 - pow(1 - progress, 3)
    }

    /// Fades in `range` of the text just set, word by word (too many words appear at once), and gives the words still
    /// fading their colours back (`restore`).
    func fade(_ range: NSRange) {
        guard let view, let text = view.textStorage else { return }
        // A lazy transcript can keep a text view mounted outside the viewport; those words need no animation work.
        if view.window != nil, !Self.isVisible(view) { return finish() }
        let added = Self.words(in: text, range: range)
        let now = CACurrentMediaTime()
        if added.count <= Self.wordLimit {
            let linkColor = view.linkTextAttributes?[.foregroundColor] as? NSColor
            for (index, range) in added.enumerated() {
                let isLink = text.attribute(.link, at: range.location, effectiveRange: nil) != nil
                let color = (isLink ? linkColor : nil) ?? text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                words.append(Word(range: range, color: color ?? .textColor, start: now + Self.delay(of: index, among: added.count)))
            }
        }
        apply(at: now)
        run()
    }

    /// The text was set again with what was shown as its start: setting it dropped the temporary colours, so the words
    /// still fading get theirs back before anything is drawn.
    func restore() {
        apply(at: CACurrentMediaTime())
    }

    /// Every word at its own colour now: the text changed other than by growing, or the view left its window.
    func finish() {
        if let layout = view?.layoutManager, let length = view?.textStorage?.length {
            for word in words where NSMaxRange(word.range) <= length {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: word.range)
            }
        }
        words = []
        stop()
    }

    /// Starts the link if a word fades and the view is on screen (a view SwiftUI just made is not in a window yet).
    func run() {
        guard link == nil, !words.isEmpty, let view, view.window != nil else { return }
        guard Self.isVisible(view) else { return finish() }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        // A colour easing in over 0.4 s reads the same at 60 Hz: on a 120 Hz screen the link does half the work, which the
        // chat's scroll gets back while a reply streams.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        // The first tick after scrolling away, hiding the window or leaving the app releases the clock entirely.
        guard let view, Self.isVisible(view) else { return finish() }
        apply(at: link.targetTimestamp)
    }

    private static func isVisible(_ view: NSTextView) -> Bool {
        guard let window = view.window else { return false }
        return !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
            && (OrbView.animateInactive || (NSApp.isActive && window.occlusionState.contains(.visible)))
    }

    /// Each word's colour at `time`; a word fully in is given back its own colour and let go.
    private func apply(at time: CFTimeInterval) {
        guard let layout = view?.layoutManager else { return finish() }
        words.removeAll { word in
            let opacity = Self.opacity(at: time - word.start)
            if opacity >= 1 {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: word.range)
                return true
            }
            layout.addTemporaryAttribute(.foregroundColor, value: word.color.withAlphaComponent(word.color.alphaComponent * opacity),
                                         forCharacterRange: word.range)
            return false
        }
        if words.isEmpty { stop() }
    }

    /// The link retains its target: dropped as soon as nothing fades.
    private func stop() {
        link?.invalidate()
        link = nil
    }
}
