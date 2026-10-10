import AppKit

// A small AppKit app for the Accessibility smoke tests (`AXSmokeTests`): the controls the tools have to cope with, and a
// record of what each one received, one JSON object per line on stdout. It never activates itself (no `activate`, windows
// are ordered front without making the app active), so a test can tell its own effect on the front app from the fixture's.
// It quits when the process that started it is gone.

// MARK: - Log

func log(_ event: String, _ fields: [String: Any] = [:]) {
    var object = fields
    object["event"] = event
    object["t"] = Date().timeIntervalSince1970
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

// MARK: - Views

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Draws and takes clicks, but exposes nothing to Accessibility: only a screenshot (and a coordinate) can find it.
final class CanvasView: NSView {
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        bounds.fill()
        NSColor.black.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        log("canvas", ["x": point.x, "y": point.y, "clicks": event.clickCount])
    }
}

@MainActor final class Controller: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    var counter = 0
    let counterLabel = NSTextField(labelWithString: "Contagem: 0")
    let delayedLabel = NSTextField(labelWithString: "Aguardando")
    let table = NSTableView()

    // MARK: Actions

    @objc func increment(_ sender: Any?) {
        counter += 1
        counterLabel.stringValue = "Contagem: \(counter)"
        log("button", ["name": "Somar", "count": counter])
    }

    @objc func changeLater(_ sender: Any?) {
        log("button", ["name": "Mudar depois"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            delayedLabel.stringValue = "Pronto"
            log("delayed", ["label": "Pronto"])
        }
    }

    @objc func popup(_ sender: NSPopUpButton) {
        log("popup", ["title": sender.titleOfSelectedItem ?? ""])
    }

    @objc func mark(_ sender: Any?) { log("menu", ["item": "Marcar"]) }
    @objc func delete(_ sender: Any?) { log("menu", ["item": "Excluir"]) }

    // MARK: Delegates

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // A secure field's text is logged as its length only.
        if field is NSSecureTextField { log("text", ["field": "Senha", "length": field.stringValue.count]) } else {
            log("text", ["field": field.identifier?.rawValue ?? "", "value": field.stringValue])
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        log("text", ["field": "Notas", "value": view.string])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 200 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "Linha \(row + 1)")
        cell.setAccessibilityLabel("Linha \(row + 1)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        log("select", ["row": table.selectedRow + 1])
    }

    @objc func scrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        log("scroll", ["y": clip.bounds.origin.y])
    }
}

// MARK: - Window

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()

@MainActor func label(_ text: String, _ x: CGFloat, _ y: CGFloat) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.frame = CGRect(x: x, y: y, width: 90, height: 20)
    return field
}

@MainActor func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 760, height: 640), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "Fixture"
    window.isReleasedWhenClosed = false
    let content = FlippedView(frame: CGRect(x: 0, y: 0, width: 760, height: 640))
    window.contentView = content

    // Button and counter.
    let button = NSButton(title: "Somar", target: controller, action: #selector(Controller.increment))
    button.frame = CGRect(x: 20, y: 20, width: 100, height: 28)
    controller.counterLabel.frame = CGRect(x: 130, y: 24, width: 160, height: 20)
    content.addSubview(button)
    content.addSubview(controller.counterLabel)

    // The button that changes a label after 500 ms.
    let later = NSButton(title: "Mudar depois", target: controller, action: #selector(Controller.changeLater))
    later.frame = CGRect(x: 320, y: 20, width: 130, height: 28)
    controller.delayedLabel.frame = CGRect(x: 460, y: 24, width: 160, height: 20)
    content.addSubview(later)
    content.addSubview(controller.delayedLabel)

    // Text fields.
    content.addSubview(label("Nome", 20, 66))
    let name = NSTextField(frame: CGRect(x: 110, y: 62, width: 240, height: 24))
    name.placeholderString = "Nome"
    name.identifier = NSUserInterfaceItemIdentifier("Nome")
    name.setAccessibilityLabel("Nome")
    name.delegate = controller
    content.addSubview(name)

    content.addSubview(label("Senha", 380, 66))
    let secret = NSSecureTextField(frame: CGRect(x: 460, y: 62, width: 200, height: 24))
    secret.setAccessibilityLabel("Senha")
    secret.delegate = controller
    content.addSubview(secret)

    // Text view.
    let notes = NSTextView(frame: CGRect(x: 0, y: 0, width: 330, height: 70))
    notes.isRichText = false
    notes.delegate = controller
    notes.setAccessibilityLabel("Notas")
    let notesScroll = NSScrollView(frame: CGRect(x: 20, y: 100, width: 330, height: 70))
    notesScroll.documentView = notes
    notesScroll.hasVerticalScroller = true
    notesScroll.borderType = .bezelBorder
    content.addSubview(notesScroll)

    // Popup.
    let popup = NSPopUpButton(frame: CGRect(x: 380, y: 100, width: 160, height: 26), pullsDown: false)
    popup.addItems(withTitles: ["Um", "Dois", "Três"])
    popup.target = controller
    popup.action = #selector(Controller.popup)
    popup.setAccessibilityLabel("Número")
    content.addSubview(popup)

    // Table of 200 rows.
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
    column.title = "Item"
    column.width = 290
    controller.table.addTableColumn(column)
    controller.table.dataSource = controller
    controller.table.delegate = controller
    controller.table.setAccessibilityLabel("Tabela")
    let tableScroll = NSScrollView(frame: CGRect(x: 20, y: 190, width: 330, height: 200))
    tableScroll.documentView = controller.table
    tableScroll.hasVerticalScroller = true
    tableScroll.borderType = .bezelBorder
    content.addSubview(tableScroll)

    // A tall scroll area.
    let tall = FlippedView(frame: CGRect(x: 0, y: 0, width: 300, height: 18_000))
    for index in 0..<600 {
        let row = NSTextField(labelWithString: "Trecho \(index + 1)")
        row.frame = CGRect(x: 8, y: index * 30, width: 200, height: 20)
        tall.addSubview(row)
    }
    let tallScroll = NSScrollView(frame: CGRect(x: 380, y: 190, width: 320, height: 200))
    tallScroll.documentView = tall
    tallScroll.hasVerticalScroller = true
    tallScroll.borderType = .bezelBorder
    tallScroll.setAccessibilityLabel("Rolagem")
    tallScroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(controller, selector: #selector(Controller.scrolled), name: NSView.boundsDidChangeNotification,
                                           object: tallScroll.contentView)
    content.addSubview(tallScroll)

    // A canvas with no Accessibility element.
    content.addSubview(label("Canvas", 20, 410))
    let canvas = CanvasView(frame: CGRect(x: 20, y: 436, width: 240, height: 160))
    content.addSubview(canvas)
    Shared.canvas = canvas
    return window
}

@MainActor enum Shared {
    static var canvas: CanvasView?
    static var cover: NSWindow?
}

/// A magenta window over the fixture's own, to test capturing a covered window; driven by "cover" / "uncover" on stdin.
@MainActor func setCover(_ on: Bool, over window: NSWindow) {
    log("cover", ["on": on])
    if !on { Shared.cover?.orderOut(nil); return }
    let panel = Shared.cover ?? NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    panel.setFrame(window.frame, display: true)
    panel.backgroundColor = .magenta
    panel.isOpaque = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.setAccessibilityLabel("Cobertura")
    panel.orderFrontRegardless()
    Shared.cover = panel
}

/// The center of the canvas in screen points with the origin at the top left of the main display (what Accessibility uses).
@MainActor func canvasCenter(in window: NSWindow) -> [Double] {
    guard let canvas = Shared.canvas else { return [0, 0] }
    let onScreen = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return [onScreen.midX, primaryHeight - onScreen.midY]
}

/// The center of the canvas in points from the window's top left corner (title bar included): where a screenshot of the window has it.
@MainActor func canvasInWindow(_ window: NSWindow) -> [Double] {
    guard let canvas = Shared.canvas else { return [0, 0] }
    let rect = canvas.convert(canvas.bounds, to: nil)
    return [rect.midX, window.frame.height - rect.midY]
}

@MainActor func makeMenus() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "Fixture")
    appMenu.addItem(withTitle: "Encerrar Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let actions = NSMenuItem()
    let actionsMenu = NSMenu(title: "Ações")
    let markItem = NSMenuItem(title: "Marcar", action: #selector(Controller.mark), keyEquivalent: "k")
    markItem.keyEquivalentModifierMask = [.command]
    markItem.target = controller
    let deleteItem = NSMenuItem(title: "Excluir", action: #selector(Controller.delete), keyEquivalent: "")
    deleteItem.target = controller
    actionsMenu.addItem(markItem)
    actionsMenu.addItem(deleteItem)
    actions.submenu = actionsMenu
    main.addItem(actions)
    app.mainMenu = main
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        let window = makeWindow()
        self.window = window
        // In front of other windows without making the app the active one.
        window.orderFrontRegardless()
        log("ready", ["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                      "frame": [window.frame.origin.x, window.frame.origin.y, window.frame.width, window.frame.height],
                      "canvasCenter": canvasCenter(in: window), "canvasInWindow": canvasInWindow(window)])
        // Commands from the test, one per line: cover, uncover, quit. Stdin closing means the test is gone.
        Thread.detachNewThread {
            while let line = readLine() {
                DispatchQueue.main.async {
                    switch line {
                    case "cover": setCover(true, over: window)
                    case "uncover": setCover(false, over: window)
                    case "quit": exit(0)
                    default: break
                    }
                }
            }
            exit(0)
        }
        // Gone when whoever started it is gone.
        let parent = getppid()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if getppid() != parent { exit(0) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { log("activated") }
    func applicationDidResignActive(_ notification: Notification) { log("resigned") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
