import Foundation

// What `ui_read` shows and what `ui_act` can rely on: the outline of one window, the ids in it, and the snapshot that
// remembers what each id was so a later action can tell the interface changed.

// MARK: - Text helpers

enum UIText {
    /// Compares titles the way a person would: no case, no accents, "..." is "…", a curly apostrophe is a straight one.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "...", with: "…")
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A menu title without its trailing "…", for matching "Exportar" against "Exportar…".
    static func foldedWithoutEllipsis(_ text: String) -> String {
        var folded = fold(text)
        while folded.hasSuffix("…") || folded.hasSuffix(" ") { folded.removeLast() }
        return folded
    }

    /// One line, at most `limit` characters: the way a value or title is shown in the outline.
    static func clean(_ text: String, limit: Int = 80) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count > limit ? flat.prefix(limit - 1) + "…" : flat
    }

    static func quoted(_ text: String) -> String { "“\(text)”" }
}

// MARK: - Roles

enum UIRole {
    private static let names: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menubutton", "AXComboBox": "combobox", "AXTextField": "field", "AXTextArea": "textarea",
        "AXSearchField": "searchfield", "AXStaticText": "text", "AXLink": "link", "AXImage": "image", "AXSlider": "slider",
        "AXIncrementor": "stepper", "AXDisclosureTriangle": "disclosure", "AXTabGroup": "tabs", "AXTable": "table",
        "AXOutline": "outline", "AXRow": "row", "AXColumn": "column", "AXCell": "cell", "AXList": "list",
        "AXScrollArea": "scroll", "AXScrollBar": "scrollbar", "AXSplitGroup": "split", "AXSplitter": "splitter",
        "AXGroup": "group", "AXRadioGroup": "radiogroup", "AXToolbar": "toolbar", "AXWindow": "window", "AXSheet": "sheet",
        "AXDrawer": "drawer", "AXMenuBar": "menubar", "AXMenuBarItem": "menubaritem", "AXMenu": "menu", "AXMenuItem": "menuitem",
        "AXWebArea": "web", "AXProgressIndicator": "progress", "AXBusyIndicator": "busy", "AXLevelIndicator": "level",
        "AXValueIndicator": "indicator", "AXColorWell": "colorwell", "AXSeparator": "separator", "AXHeading": "heading",
        "AXPopover": "popover", "AXDockItem": "dockitem", "AXGrowArea": "handle", "AXHandle": "handle",
        "AXLayoutArea": "layout", "AXLayoutItem": "layout", "AXUnknown": "element",
    ]

    /// "AXButton" → "button". Roles this list does not know lose their "AX" prefix and are lowercased.
    static func short(_ raw: String) -> String {
        if let name = names[raw] { return name }
        let bare = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
        return bare.isEmpty ? "element" : bare.lowercased()
    }

    /// Containers that only arrange other elements: left out of the outline unless they carry text.
    static let layoutOnly: Set<String> = ["group", "scroll", "split", "radiogroup", "layout", "cell", "element"]
    /// Leaves with nothing to say when they have no text.
    static let emptyIsNoise: Set<String> = ["text", "image", "separator", "scrollbar", "splitter", "indicator", "handle", "busy"]
    /// Roles whose AXValue is worth reading (others carry layout or huge text, like a web area's whole page).
    static let carriesValue: Set<String> = [
        "text", "field", "searchfield", "textarea", "combobox", "popup", "menubutton", "checkbox", "radio", "slider", "stepper",
        "progress", "level", "disclosure", "colorwell",
    ]
}

// MARK: - One element

struct UIElementInfo: Equatable {
    var rawRole = ""
    var role = "element"
    var title: String?
    var description: String?
    var help: String?
    var placeholder: String?
    var value: String?
    var enabled = true
    var focused = false
    var selected = false
    var hidden = false
    var size: CGSize?
    var secure = false

    /// The AX attributes read for every element, in one round trip. AXValue is not among them: a password field's value
    /// must never be requested.
    static let attributeNames = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue",
        "AXEnabled", "AXFocused", "AXSelected", "AXHidden", "AXSize",
    ]

    init() {}

    init(attributes: [String: AXAttributeValue]) {
        func text(_ name: String) -> String? {
            guard let value = attributes[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return UIText.clean(value)
        }
        rawRole = attributes["AXRole"]?.string ?? ""
        role = UIRole.short(rawRole)
        title = text("AXTitle")
        description = text("AXDescription")
        help = text("AXHelp")
        placeholder = text("AXPlaceholderValue")
        enabled = attributes["AXEnabled"]?.bool ?? true
        focused = attributes["AXFocused"]?.bool ?? false
        selected = attributes["AXSelected"]?.bool ?? false
        hidden = attributes["AXHidden"]?.bool ?? false
        if case .size(let size)? = attributes["AXSize"] { self.size = size }
        let kind = UIText.fold(attributes["AXRoleDescription"]?.string ?? "")
        secure = attributes["AXSubrole"]?.string == "AXSecureTextField" || kind.contains("secure") || kind.contains("seguro")
    }

    /// Zero-size elements exist in the tree but nobody sees them.
    var isInvisible: Bool { hidden || (size.map { $0.width <= 0 || $0.height <= 0 } ?? false) }

    /// What a later `ui_act` compares to know it found the same element: the title, else the description. The value
    /// is left out because it changes as the user works.
    var identity: String { title ?? description ?? "" }

    var hasText: Bool { title != nil || description != nil || help != nil || !(value ?? "").isEmpty }

    /// The words that `query` is matched against.
    var searchText: String {
        UIText.fold([role, rawRole, title, description, help, placeholder, value].compactMap { $0 }.joined(separator: " "))
    }

    static func format(value number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    /// Reads the value of an element that is not a password field.
    static func readValue(of element: any AccessibilityElement, info: UIElementInfo) -> String? {
        guard !info.secure, UIRole.carriesValue.contains(info.role) else { return nil }
        switch element.attribute("AXValue") {
        case .string(let text)?: return UIText.clean(text).isEmpty ? nil : UIText.clean(text)
        case .number(let number)?: return format(value: number)
        case .bool(let flag)?: return flag ? "1" : "0"
        default: return nil
        }
    }

    /// The outline line, without the id.
    var line: String {
        var parts = [role]
        let primary = title ?? description ?? (role == "text" ? value : nil)
        if let primary { parts.append(UIText.quoted(primary)) }
        if title != nil, let description, description != title { parts.append("desc=\"\(description)\"") }
        if primary == nil, let help { parts.append("help=\"\(help)\"") }
        if let value, value != primary { parts.append("value=\"\(value)\"") }
        if secure { parts.append("value=<oculto>") }
        if let placeholder, (value ?? "").isEmpty { parts.append("placeholder=\"\(placeholder)\"") }
        var flags: [String] = []
        if !enabled { flags.append("desativado") }
        if focused { flags.append("foco") }
        if selected { flags.append("selecionado") }
        if !flags.isEmpty { parts.append("[" + flags.joined(separator: ", ") + "]") }
        return parts.joined(separator: " ")
    }
}

// MARK: - The outline

enum UIOutlineCut: String, Hashable, Sendable {
    case lines, depth, visited, time
    /// The app stopped answering in the middle: the walk ended at the first call it failed.
    case hung
    /// A web page was read only near its top (the browser tools read pages better).
    case web
    /// The text reached its character cap.
    case characters
}

struct UIOutlineLimits: Sendable {
    var maxLines = 400
    var maxDepth = 12
    /// Elements examined at most; every one costs a round trip to the app.
    var maxVisited = 3000
    /// Seconds the walk may take before it stops and says so; nil leaves it to the caller's deadline (4 s here).
    var seconds: Double?
    /// Characters of outline at most (`ToolOutputBudget.fit`).
    var maxCharacters = 14_000
    /// Levels read under a web area when there is no query: a page has thousands of elements.
    var webDepth = 3
}

struct UIOutline {
    var lines: [String] = []
    var entries: [String: UISnapshot.Entry] = [:]
    /// The live element behind each listed id.
    var elements: [String: any AccessibilityElement] = [:]
    /// Elements that would have been listed without the line cap.
    var total = 0
    var matched = 0
    var cuts: Set<UIOutlineCut> = []
    var cancelled = false
    /// Why the walk stopped early because of the app (hung, gone, permission off); nil when it did not.
    var failure: AXFailure?
    /// The window's frame on screen, when it said.
    var windowFrame: CGRect?
}

enum UIOutlineBuilder {
    private final class Node {
        let id: String
        let info: UIElementInfo
        let element: any AccessibilityElement
        var frame: CGRect?
        var actionable = false
        var children: [Node] = []
        let matches: Bool
        /// It matches the query, or something under it does.
        var keep: Bool

        init(id: String, info: UIElementInfo, element: any AccessibilityElement, matches: Bool) {
            self.id = id
            self.info = info
            self.element = element
            self.matches = matches
            keep = matches
        }
    }

    private struct Walk {
        var visited = 0
        var cuts: Set<UIOutlineCut> = []
        let started = Date()
        var cancelled = false
        var failure: AXFailure?
        /// The window's top-left corner, which entry frames are relative to.
        var origin: CGPoint?
        var windowFrame: CGRect?
    }

    /// Read in one round trip per element: what the line shows, the children and the frame. AXValue is not among them
    /// (a password field's value must never be requested).
    static let readNames = UIElementInfo.attributeNames + ["AXChildren", "AXPosition"]

    /// Actions a click can trigger.
    static let clickActions: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]

    /// The outline of one window. Elements get ids `<prefix>.<position among its parent's children>`, counting every
    /// child (also the ones left out), so an id does not move when something beside it appears or disappears.
    static func outline(of window: any AccessibilityElement, prefix: String, query: String?, limits: UIOutlineLimits) -> UIOutline {
        let wanted = query.map(UIText.fold).flatMap { $0.isEmpty ? nil : $0 }
        var walk = Walk()
        let roots = visit(window, id: prefix, depth: 0, webDepth: nil, wanted: wanted, limits: limits, walk: &walk)
        var outline = UIOutline(cuts: walk.cuts, cancelled: walk.cancelled, failure: walk.failure, windowFrame: walk.windowFrame)
        let listed = roots.filter(\.keep)
        outline.total = listed.reduce(0) { $0 + count($1) }
        outline.matched = wanted == nil ? 0 : listed.reduce(0) { $0 + countMatches($1) }
        var ordered: [(node: Node, depth: Int)] = []
        for node in listed { collect(node, depth: 0, limits: limits, into: &ordered) }
        if outline.total > ordered.count { outline.cuts.insert(.lines) }
        let lines = ordered.map { String(repeating: "  ", count: $0.depth) + $0.node.id + " " + $0.node.info.line }
        let fitted = ToolOutputBudget.fit(lines, budget: limits.maxCharacters)
        if fitted.omitted > 0 { outline.cuts.insert(.characters) }
        outline.lines = fitted.kept
        for (node, _) in ordered.prefix(fitted.kept.count) {
            outline.entries[node.id] = UISnapshot.Entry(rawRole: node.info.rawRole, label: node.info.identity, secure: node.info.secure,
                                                        frame: node.frame, actionable: node.actionable)
            outline.elements[node.id] = node.element
        }
        return outline
    }

    private static func visit(_ element: any AccessibilityElement, id: String, depth: Int, webDepth: Int?, wanted: String?,
                              limits: UIOutlineLimits, walk: inout Walk) -> [Node] {
        if walk.failure != nil { return [] }
        if AXWork.isCancelled { walk.cancelled = true; return [] }
        if walk.visited >= limits.maxVisited { walk.cuts.insert(.visited); return [] }
        if Date().timeIntervalSince(walk.started) >= limits.seconds ?? 4 { walk.cuts.insert(.time); return [] }
        walk.visited += 1

        let attributes: [String: AXAttributeValue]
        switch element.read(readNames) {
        case .values(let values):
            attributes = values
        case .failed(.invalidElement) where depth > 0:
            return [] // gone while the walk went by
        case .failed(let failure):
            // The first call the app fails ends the walk: a hung app would fail every other one too, a second at a time.
            walk.failure = failure
            if failure == .cannotComplete { walk.cuts.insert(.hung) }
            return []
        }
        var info = UIElementInfo(attributes: attributes)
        var frame: CGRect?
        if case .point(let origin)? = attributes["AXPosition"], let size = info.size {
            if depth == 0 {
                walk.origin = origin
                walk.windowFrame = CGRect(origin: origin, size: size)
            }
            if let windowOrigin = walk.origin {
                frame = CGRect(x: origin.x - windowOrigin.x, y: origin.y - windowOrigin.y, width: size.width, height: size.height)
            }
        }
        if info.isInvisible { return [] }
        info.value = UIElementInfo.readValue(of: element, info: info)

        var children: [Node] = []
        let list = attributes["AXChildren"]?.elements ?? []
        // Under a web area without a query only the first levels are read; the browser tools are for pages.
        let childWebDepth = webDepth.map { $0 + 1 } ?? (info.rawRole == "AXWebArea" && wanted == nil ? 1 : nil)
        if depth >= limits.maxDepth {
            if !list.isEmpty { walk.cuts.insert(.depth) }
        } else if let childWebDepth, childWebDepth > limits.webDepth {
            if !list.isEmpty { walk.cuts.insert(.web) }
        } else {
            for (index, child) in list.enumerated() {
                children += visit(child, id: "\(id).\(index + 1)", depth: depth + 1, webDepth: childWebDepth, wanted: wanted,
                                  limits: limits, walk: &walk)
            }
        }

        if depth > 0, !info.hasText, UIRole.layoutOnly.contains(info.role) || UIRole.emptyIsNoise.contains(info.role) {
            return children
        }
        let node = Node(id: id, info: info, element: element, matches: wanted.map { info.searchText.contains($0) } ?? true)
        node.frame = frame
        node.children = children
        node.keep = node.matches || children.contains(where: \.keep)
        if node.keep, depth > 0, walk.failure == nil {
            node.actionable = !clickActions.isDisjoint(with: element.actionNames())
        }
        return [node]
    }

    private static func count(_ node: Node) -> Int { 1 + node.children.filter(\.keep).reduce(0) { $0 + count($1) } }
    private static func countMatches(_ node: Node) -> Int {
        (node.matches ? 1 : 0) + node.children.filter(\.keep).reduce(0) { $0 + countMatches($1) }
    }

    private static func collect(_ node: Node, depth: Int, limits: UIOutlineLimits, into ordered: inout [(node: Node, depth: Int)]) {
        guard ordered.count < limits.maxLines else { return }
        ordered.append((node, depth))
        for child in node.children where child.keep { collect(child, depth: depth + 1, limits: limits, into: &ordered) }
    }

    /// The menu bar's top-level menus, ids `m1`, `m2`…
    static func menuBar(of root: any AccessibilityElement)
        -> (lines: [String], entries: [String: UISnapshot.Entry], elements: [String: any AccessibilityElement])? {
        guard let bar = root.element("AXMenuBar"), let items = bar.elements("AXChildren"), !items.isEmpty else { return nil }
        var lines: [String] = []
        var entries: [String: UISnapshot.Entry] = [:]
        var elements: [String: any AccessibilityElement] = [:]
        for (index, item) in items.enumerated() {
            guard let attributes = item.read(UIElementInfo.attributeNames).attributes else { continue }
            let info = UIElementInfo(attributes: attributes)
            guard !info.isInvisible else { continue }
            let id = "m\(index + 1)"
            lines.append(id + " " + info.line)
            entries[id] = UISnapshot.Entry(rawRole: info.rawRole, label: info.identity, secure: false, actionable: true)
            elements[id] = item
        }
        return lines.isEmpty ? nil : (lines, entries, elements)
    }
}

// MARK: - Snapshot

/// Where a screenshot sits, to turn its pixels back into points on screen.
struct ShotGeometry: Codable, Sendable, Equatable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per point.
    var scale: Double
    /// The window's frame on screen, in points, when the image was taken.
    var windowFrame: CGRect
    /// The `CGWindowID` that was captured.
    var windowID: UInt32

    init(pixelWidth: Int, pixelHeight: Int, scale: Double, windowFrame: CGRect, windowID: UInt32) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.windowFrame = windowFrame
        self.windowID = windowID
    }
}

/// What one `ui_read` showed: for each id its role and name, and which window it came from. `ui_act` finds the element
/// again from the id and refuses to act when the live element no longer looks like this.
struct UISnapshot: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        /// The AX role ("AXButton").
        var rawRole: String
        /// Title, else description, as shown in the outline.
        var label: String
        var secure: Bool
        /// Position and size in points relative to the window's top-left corner; nil when not read.
        var frame: CGRect?
        /// Whether the element has an action a click can trigger (press, pick, confirm…).
        var actionable: Bool

        init(rawRole: String, label: String, secure: Bool, frame: CGRect? = nil, actionable: Bool = false) {
            self.rawRole = rawRole
            self.label = label
            self.secure = secure
            self.frame = frame
            self.actionable = actionable
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rawRole = try c.value(.rawRole, default: "")
            label = try c.value(.label, default: "")
            secure = try c.value(.secure, default: false)
            frame = try? c.decodeIfPresent(CGRect.self, forKey: .frame)
            actionable = (try? c.decodeIfPresent(Bool.self, forKey: .actionable)) ?? false
        }
    }

    var app: AccessibilityApp
    /// Position of the window among the app's windows when it was read; nil when only the menus were read.
    var windowIndex: Int?
    var windowTitle: String
    var entries: [String: Entry]
    var takenAt: Date
    /// Counts the readings of this app by this Orb, so a live reference can be tied to the reading it came from.
    var generation: Int
    /// Screenshot mark number → element id, for the marks drawn on the last screenshot of this window.
    var marks: [Int: String]
    /// Where that screenshot sits; nil when no screenshot goes with this reading.
    var shot: ShotGeometry?

    init(app: AccessibilityApp, windowIndex: Int?, windowTitle: String, entries: [String: Entry], takenAt: Date = .now,
         generation: Int = 0, marks: [Int: String] = [:], shot: ShotGeometry? = nil) {
        self.app = app
        self.windowIndex = windowIndex
        self.windowTitle = windowTitle
        self.entries = entries
        self.takenAt = takenAt
        self.generation = generation
        self.marks = marks
        self.shot = shot
    }

    private enum CodingKeys: String, CodingKey {
        case app, windowIndex, windowTitle, entries, takenAt, generation, marks, shot
    }

    // Fields added later fall back to defaults, so a snapshot stored by an older version still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(AccessibilityApp.self, forKey: .app)
        windowIndex = try c.decodeIfPresent(Int.self, forKey: .windowIndex)
        windowTitle = try c.value(.windowTitle, default: "")
        entries = (try? c.decodeIfPresent([String: Entry].self, forKey: .entries)) ?? [:]
        takenAt = try c.value(.takenAt, default: .distantPast)
        generation = (try? c.decodeIfPresent(Int.self, forKey: .generation)) ?? 0
        let stored = (try? c.decodeIfPresent([String: String].self, forKey: .marks)) ?? [:]
        marks = Dictionary(stored.compactMap { key, id in Int(key).map { ($0, id) } }, uniquingKeysWith: { first, _ in first })
        shot = try? c.decodeIfPresent(ShotGeometry.self, forKey: .shot)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(windowIndex, forKey: .windowIndex)
        try c.encode(windowTitle, forKey: .windowTitle)
        try c.encode(entries, forKey: .entries)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encode(generation, forKey: .generation)
        // JSON keys are strings: an Int-keyed dictionary would be written as a flat array.
        try c.encode(Dictionary(uniqueKeysWithValues: marks.map { (String($0.key), $0.value) }), forKey: .marks)
        try c.encodeIfPresent(shot, forKey: .shot)
    }

    /// Whether a call naming `name` may be about this app: the same test that finds the app (`RunningAppMatcher`),
    /// an exact name or bundle identifier, or a name that contains the text.
    func isFor(_ name: String) -> Bool {
        let wanted = UIText.fold(name)
        guard !wanted.isEmpty else { return false }
        return UIText.fold(app.name).contains(wanted) || app.bundleID.map { UIText.fold($0) == wanted } ?? false
    }
}

/// The last snapshot per Orb and app. Kept in memory, and mirrored to a small file per app so the approval check (which
/// runs in the Orb app) can see a snapshot taken by the tools server that Claude Code started (another process).
final class UISnapshotStore: @unchecked Sendable {
    static let shared = UISnapshotStore()

    private struct Key: Hashable {
        var bot: UUID?
        var app: String
    }

    private let lock = NSLock()
    private var snapshots: [Key: UISnapshot] = [:]
    private let directory: URL?
    /// A reading older than this is forgotten (and its file deleted): the screen it described is long gone, and the file is
    /// readable by any process of the user.
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    init(directory: URL? = FileManager.default.temporaryDirectory.appending(path: "OrbAccessibility"),
         maxAge: TimeInterval = 3_600, now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory
        self.maxAge = maxAge
        self.now = now
    }

    /// The snapshot in `url`, or nil when it cannot be read or is older than `maxAge` (then the file is deleted).
    private func fresh(at url: URL) -> UISnapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(UISnapshot.self, from: data) else { return nil }
        guard now().timeIntervalSince(snapshot.takenAt) <= maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return snapshot
    }

    private static func key(_ app: AccessibilityApp, bot: UUID?) -> Key {
        Key(bot: bot, app: UIText.fold(app.bundleID ?? app.name))
    }

    func save(_ snapshot: UISnapshot, bot: UUID?) {
        lock.withLock { snapshots[Self.key(snapshot.app, bot: bot)] = snapshot }
        guard let directory, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: snapshot.app, in: directory), options: .atomic)
    }

    /// The Orb's own last reading of the app, else the last one anybody made (another process's, from the file).
    func snapshot(bot: UUID?, app: AccessibilityApp) -> UISnapshot? {
        let key = Self.key(app, bot: bot)
        let own: UISnapshot? = lock.withLock {
            guard let snapshot = snapshots[key] else { return nil }
            guard now().timeIntervalSince(snapshot.takenAt) <= maxAge else { snapshots[key] = nil; return nil }
            return snapshot
        }
        if let own { return own }
        guard let directory else { return nil }
        return fresh(at: file(for: app, in: directory))
    }

    /// The newest reading this Orb made in this process, of any app: what `ui_act` acts on when no app is named (never
    /// the app in front, which is the one the user is using).
    func latest(bot: UUID?) -> UISnapshot? {
        lock.withLock {
            snapshots.filter { $0.key.bot == bot && now().timeIntervalSince($0.value.takenAt) <= maxAge }
                .map(\.value).max { $0.takenAt < $1.takenAt }
        }
    }

    /// Every snapshot that may be what a call is about, for judging a call before it runs: those of the named app (a
    /// name or bundle identifier), or all of them when no app is named, newest first.
    func candidates(matching app: String?) -> [UISnapshot] {
        var found = lock.withLock {
            snapshots = snapshots.filter { now().timeIntervalSince($0.value.takenAt) <= maxAge }
            return Array(snapshots.values)
        }
        if let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix("ax-") && name.hasSuffix(".json") {
                if let snapshot = fresh(at: directory.appending(path: name)) { found.append(snapshot) }
            }
        }
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty { found = found.filter { $0.isFor(app) } }
        return found.sorted { $0.takenAt > $1.takenAt }
    }

    private func file(for app: AccessibilityApp, in directory: URL) -> URL {
        let safe = UIText.fold(app.bundleID ?? app.name).map { $0.isLetter || $0.isNumber || $0 == "." ? String($0) : "_" }.joined()
        return directory.appending(path: "ax-\(safe).json")
    }
}

// MARK: - Merging readings

extension UISnapshot {
    /// Whether both readings are of the same window of the same running app.
    func isSameWindow(as other: UISnapshot) -> Bool {
        app.pid == other.app.pid && windowIndex != nil && windowIndex == other.windowIndex && windowTitle == other.windowTitle
    }

    /// This reading with what `previous` knew about the same window, when it is less than `within` seconds older: the
    /// marks and geometry of the screenshot taken of it and, when this reading is `partial` (a query lists only part of
    /// the window), the ids it listed and this one did not. A mark is dropped when its id now names something else. Ids
    /// name positions, and every action checks the live element against its entry before touching it.
    func carryingOver(from previous: UISnapshot?, partial: Bool, within: TimeInterval = 60) -> UISnapshot {
        guard let previous, isSameWindow(as: previous), takenAt.timeIntervalSince(previous.takenAt) < within else { return self }
        var merged = self
        if partial { merged.entries = previous.entries.merging(entries) { _, new in new } }
        if marks.isEmpty, shot == nil {
            let known = merged.entries
            merged.marks = previous.marks.filter { _, id in
                guard let old = previous.entries[id], let now = known[id] else { return false }
                return now.rawRole == old.rawRole && now.label == old.label
            }
            merged.shot = previous.shot
        }
        return merged
    }
}
