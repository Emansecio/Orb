import SwiftUI
import AppKit

/// `Orb --pipe-tools` declares the Orb's tools to the Claude Code CLI (which is only a pipe to the model): no window, and none of
/// the app's AppKit/SwiftUI setup, so `OrbApp.main()` is never reached; anything else is the app.
@main
enum Launcher {
    static func main() {
        if let options = ClaudePipeServer.Options(arguments: CommandLine.arguments) {
            ClaudePipeServer.run(options)
        }
        #if !(DEBUG || ORB_DEV_TOOLS)
        // The review screens are not in this build. Leave before OrbApp exists: no model, no window, no data folder is touched.
        if CommandLine.arguments.contains(where: ["--snapshot", "--render-orbs"].contains) {
            let note = "--snapshot e --render-orbs só existem em build de desenvolvimento (swift build) ou num release feito com "
                + "ORB_DEV_TOOLS (swift build -c release -Xswiftc -DORB_DEV_TOOLS).\n"
            FileHandle.standardError.write(Data(note.utf8))
            exit(64)
        }
        #endif
        #if DEBUG || ORB_DEV_TOOLS
        // The benches never take the focus: accessory before the app finishes launching, not after.
        if CommandLine.arguments.contains(where: ["--bench-panels", "--bench-scroll"].contains) { NSApplication.shared.setActivationPolicy(.accessory) }
        #endif
        OrbApp.main()
    }
}

struct OrbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(firstUse: DevRun.isActive ? .initial : .firstUse)

    var body: some Scene {
        Window("Orb", id: "main") {
            RootView()
                .environment(model)
                .resetShield(model)
                .frame(minWidth: 1000, minHeight: 620)
                .preferredColorScheme(.dark)
                .task {
                    // The bots are read when the task runs, not while the scene's body is evaluated (the body must not depend on them).
                    OrbImages.prewarmResting(model.bots.map(\.orb), selected: model.selectedBot?.orb,
                                             scale: NSScreen.main?.backingScaleFactor ?? 2)
                }
                #if DEBUG || ORB_DEV_TOOLS
                .task { await SwitchBench.runIfAsked(model) }
                .task { await PanelsBench.runIfAsked(model) }
                .task { await ScrollBench.runIfAsked(model) }
                #endif
                .task {
                    // Snapshots send their own launch prompt; the regular window must not send it again.
                    if !CommandLine.arguments.contains("--snapshot") { model.sendLaunchPrompt() }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .resetShield(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            QuickAskView()
                .environment(model)
                .resetShield(model)
                .preferredColorScheme(.dark)
        } label: {
            // Idle, an Orb working, or Orbs waiting for a permission (with an orange dot).
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snapshot: (screen: String, url: URL)? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 2) else { return nil }
        return (arguments[flag + 1], URL(fileURLWithPath: arguments[flag + 2]))
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Snapshots and sheets render in the background: no Dock icon, never takes focus.
        let renders = ["--snapshot", "--render-orbs", "--render-icon", "--bench-panels", "--bench-scroll"]
        if CommandLine.arguments.contains(where: renders.contains) { NSApp.setActivationPolicy(.accessory) }
        #if DEBUG || ORB_DEV_TOOLS
        // The benches run like a snapshot: an accessory app with its window off screen, so they never take the focus.
        if PanelsBench.isAsked || ScrollBench.isAsked {
            NSApp.setActivationPolicy(.accessory)
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { PanelsBench.hideWindows() } }
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The panel that says an Orb has the screen (any process holding a takeover tells the app).
        if snapshot == nil, !CommandLine.arguments.contains(where: ["--render-orbs", "--render-icon"].contains) { TakeoverHUD.shared.install() }
        // Dev aid: `Orb --snapshot skills-explore out.png` renders one screen offscreen and exits.
        #if DEBUG || ORB_DEV_TOOLS
        if let snapshot {
            NSApp.windows.forEach { $0.orderOut(nil) }
            Snapshot.render(snapshot.screen, to: snapshot.url)
            return
        }
        #else
        // Not reached in practice (`Launcher.main` already left), kept as a second guard before any UI is set up.
        if snapshot != nil {
            FileHandle.standardError.write(Data("--snapshot só existe em build de desenvolvimento (swift build ou ORB_DEV_TOOLS)\n".utf8))
            exit(64)
        }
        #endif
        // Dev aid: `Orb --render-orbs out.png` writes a sheet of Orbs × activities and exits.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-orbs"), arguments.indices.contains(flag + 1) {
            #if DEBUG || ORB_DEV_TOOLS
            // `Orb --render-orbs bench <count> [working] [seconds]`: CPU benchmark of live orbs (see `OrbBench`).
            if arguments[flag + 1] == "bench" {
                NSApp.windows.forEach { $0.orderOut(nil) }
                OrbBench.run(arguments: Array(arguments.dropFirst(flag + 2)))
                return
            }
            // `Orb --render-orbs out.png cabelos`: one of the design-review sheets (`OrbDesignSheet.names`).
            if arguments.indices.contains(flag + 2) {
                let rendered = OrbDesignSheet.render(arguments[flag + 2], to: URL(fileURLWithPath: arguments[flag + 1]))
                if !rendered { FileHandle.standardError.write(Data("folhas: \(OrbDesignSheet.names.joined(separator: ", "))\n".utf8)) }
                DevRun.finish(status: rendered ? 0 : 1)
            }
            #else
            // The bench and the review sheets are not in this build: say so instead of writing the activities sheet
            // to a file called "bench" or ignoring the sheet's name.
            let note = "--render-orbs só existe em debug ou num release feito com "
                + "ORB_DEV_TOOLS (swift build -c release -Xswiftc -DORB_DEV_TOOLS).\n"
            FileHandle.standardError.write(Data(note.utf8))
            DevRun.finish(status: 1)
            #endif
            #if DEBUG || ORB_DEV_TOOLS
            OrbSheet.render(to: URL(fileURLWithPath: arguments[flag + 1]))
            DevRun.finish()
            #endif
        }
        // `Orb --render-icon out.png [pixels]` writes the app icon (1024 px by default; used by scripts/bundle.sh).
        if let flag = arguments.firstIndex(of: "--render-icon"), arguments.indices.contains(flag + 1) {
            let pixels = arguments.indices.contains(flag + 2) ? Int(arguments[flag + 2]) : nil
            AppIcon.render(to: URL(fileURLWithPath: arguments[flag + 1]), pixels: min(max(pixels ?? 1024, 16), 4096))
            DevRun.finish()
        }
        // So a tap on a banner reaches the app even when that tap is what launched it.
        ApprovalNotifications.prepareAtLaunch()
        // The global shortcut for the menu bar panel, when the user turned it on.
        GlobalHotKey.shared.restore()
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(GlobalHotKey.defaultsKey) private var globalShortcut = false

    /// Brings the main window forward (it may be closed or behind Settings) before a command that shows something in it.
    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    var body: some Commands {
        // While a sheet is open the commands that would open another one wait for it.
        let sheetOpen = model.hasOpenSheet
        CommandGroup(replacing: .newItem) {
            Button(CommandName.newBot) { showMain(); model.showNewBot = true }
                .keyboardShortcut(AppShortcut.newBot)
                .disabled(sheetOpen)
        }
        CommandGroup(after: .sidebar) {
            Button(CommandName.toggleInspector) { model.toggleInspector() }
                .keyboardShortcut(AppShortcut.toggleInspector)
                .disabled(sheetOpen)
        }
        // The system's Quit is ignored while a sheet is open (see `AppTermination`).
        CommandGroup(replacing: .appTermination) {
            Button(CommandName.quit) { AppTermination.quit() }
                .keyboardShortcut("q")
        }
        CommandGroup(replacing: .help) {
            Button(CommandName.shortcuts) { showMain(); model.showShortcuts = true }
                .disabled(sheetOpen)
        }
        CommandMenu("Orbs") {
            Button(CommandName.goTo) { showMain(); model.showCommandPalette = true }
                .keyboardShortcut(AppShortcut.goTo)
                .disabled(sheetOpen)
            Divider()
            Button(CommandName.writeMessage) { showMain(); model.focusComposer() }
                .keyboardShortcut(AppShortcut.writeMessage)
                .disabled(model.commandBotID == nil || sheetOpen)
            // MARK: MultiOrb (WP6): with a group on show, ⌘. stops the group's request.
            Button(CommandName.stop) { model.stopSelection() }
                .keyboardShortcut(AppShortcut.stop)
                .disabled(!model.canStopSelection)
            Button(CommandName.sendToBackground) { model.sendCurrentCommandToBackground() }
                .keyboardShortcut(AppShortcut.sendToBackground)
                .disabled(!model.canSendCommandToBackground)
            Button(CommandName.newGroup) { showMain(); model.showNewGroup = true }
                .keyboardShortcut(AppShortcut.newGroup)
                .disabled(sheetOpen || model.botIDs.count < 2)
            Button(CommandName.openFolder) {
                if let id = model.commandBotID { model.openFolder(of: id) }
            }
            .keyboardShortcut(AppShortcut.openFolder)
            .disabled(model.commandBotID == nil)
            Divider()
            // Disabled (not just ignored) with a sheet open: an enabled item would keep ⌥↓ and the like from the sheet's
            // text field, and switching the screen would close the sheet along with what was typed in it.
            Button(CommandName.previousBot) { model.selectAdjacentBot(offset: -1) }
                .keyboardShortcut(AppShortcut.previousBot)
                .disabled(sheetOpen)
            Button(CommandName.nextBot) { model.selectAdjacentBot(offset: 1) }
                .keyboardShortcut(AppShortcut.nextBot)
                .disabled(sheetOpen)
            Divider()
            Button(CommandName.routines) { showMain(); model.selection = .routines }
                .keyboardShortcut(AppShortcut.routines)
                .disabled(sheetOpen)
            Button(CommandName.connectors) { showMain(); model.selection = .connectors }
                .keyboardShortcut(AppShortcut.connectors)
                .disabled(sheetOpen)
            Button(CommandName.skills) { showMain(); model.selection = .skills }
                .keyboardShortcut(AppShortcut.skills)
                .disabled(sheetOpen)
            Divider()
            // Only the names and the order are read, so a status or a new unread message does not rebuild the menu.
            ForEach(Array(model.sidebarBotIDs.prefix(9).enumerated()), id: \.element) { index, id in
                Button(model.live(id).look.name) { showMain(); model.selection = .bot(id) }
                    .keyboardShortcut(AppShortcut.bot(at: index))
                    .disabled(sheetOpen)
            }
            Divider()
            Toggle(CommandName.globalShortcut, isOn: GlobalHotKey.toggleBinding($globalShortcut))
        }
    }
}

#if DEBUG || ORB_DEV_TOOLS
/// Static sheet of Orbs × activities, for design review (composited exactly like the app).
@MainActor
enum OrbSheet {
    static func render(to url: URL) {
        let activities: [OrbActivity] = [.idle, .speaking, .thinking, .typing, .searching, .waiting, .happy, .error, .sleepy]
        let orbs = AppState.initial.bots.map(\.orb) + [
            OrbConfig(color: "rosa", eyes: "ovais", cheeks: "blush", hair: "tufinho", accessories: ["laco"]),
            OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", mustache: "classico", accessories: ["fones"]),
            OrbConfig(color: "menta", eyes: "felizes", mouth: "sorriso", cheeks: "sardas", accessories: ["flor"]),
            OrbConfig(color: "sol", eyes: "pontos", mouth: "sorrisao", mustache: "enrolado", mustacheColor: 0x5A3B22),
            OrbConfig(color: "noite", eyes: "pilulas", hair: "topete", accessories: ["cartola"]),
            OrbConfig(color: "perola", eyes: "pilulas", cheeks: "blush", accessories: ["aureola"]),
        ]
        let sheet = VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Color.clear.frame(width: 1)
                ForEach(activities) { activity in
                    Text(activity.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 110)
                }
            }
            ForEach(Array(orbs.enumerated()), id: \.offset) { _, orb in
                HStack(spacing: 20) {
                    Color.clear.frame(width: 1)
                    ForEach(activities) { activity in
                        OrbView(config: orb, activity: activity, size: 92, animated: false)
                            .frame(width: 110, height: 130)
                    }
                }
            }
        }
        .padding(30)
        .background(Palette.canvas)
        .environment(\.colorScheme, .dark)

        write(sheet, scale: 2, to: url)
    }

    private static func write(_ view: some View, scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// Offscreen render of one screen with real data, for visual review without touching the user's screen.
@MainActor
enum Snapshot {
    static func render(_ requested: String, to url: URL) {
        // The Keychain stays untouched: a seed with token-looking values would leave orphan items there.
        let model = AppModel(secretVault: MemoryVault())
        // `readme-<scene>`: the scene with a model connected (the README's pictures).
        let screen = ReadmeSnapshots.prepare(requested, model: model) ?? requested
        model.showInspector = false // the inspector column does not render offscreen
        if screen.hasSuffix("-profile") { ProfileSnapshots.fill(model) }
        if screen.hasPrefix("routine") || screen == "inspector-routines" { RoutinesSnapshots.seed(model) }
        model.sendLaunchPrompt()
        let height = ProcessInfo.processInfo.environment["ORB_SNAPSHOT_HEIGHT"].flatMap(Double.init)
        let content: AnyView = switch screen {
        case "app": AnyView(RootView())
        case "showcase": ReadmeSnapshots.app(model)
        case "permission": ReadmeSnapshots.permission(model)
        case "skills": AnyView(SkillsView())
        case "skills-explore": AnyView(SkillsView(tab: .explore))
        case "connectors": AnyView(ConnectorsView(tab: .installed))
        case "connectors-explore": AnyView(ConnectorsView(tab: .explore))
        case "routines": AnyView(RoutinesView())
        case "models": AnyView(ProviderSettings())
        case "browser-settings": AnyView(BrowserSettings().frame(width: 640, height: 720))
        case "inspector", "inspector-memory", "inspector-folder", "inspector-routines", "inspector-screen":
            // The tab after the dash: memory, folder, routines or screen (the Orb's page, seeded with a drawn one).
            AnyView(model.bots.first.map { bot in
                if screen == "inspector-screen" { LiveScreenSnapshots.tab(model: model, botID: bot.id) }
                return BotInspector(botID: bot.id, tab: InspectorTab.allCases.first { screen == "inspector-" + $0.rawValue } ?? .general)
                    .frame(width: 360)
            })
        case "memory-sheet": AnyView(model.bots.first.map { MemorySheet(botID: $0.id, name: $0.name) })
        case "approvals": AnyView(model.bots.first.map { ApprovalCardsSample(bot: $0) })
        case "new-orb": AnyView(NewBotSheet(height: height.map { CGFloat($0) }))
        case "new-orb-import": AnyView(NewBotSheet(height: height.map { CGFloat($0) }, startsImporting: true))
        case "new-orb-import-preview": NewBotSnapshots.importSheet(height: height.map { CGFloat($0) }, confirmed: false)
        case "new-orb-marketplace": NewBotSnapshots.marketplaceSheet(height: height.map { CGFloat($0) })
        case "new-orb-imported": NewBotSnapshots.importSheet(height: height.map { CGFloat($0) }, confirmed: true)
        case "new-orb-kept": NewBotSnapshots.keptSheet(height: height.map { CGFloat($0) })
        case "sidebar", "sidebar-profile": AnyView(SidebarView().frame(width: 280))
        case "quickask": AnyView(SystemSnapshots.quickAsk(model, approvals: false))
        case "quickask-approvals": AnyView(SystemSnapshots.quickAsk(model, approvals: true))
        case "quickask-reply": AnyView(SystemSnapshots.quickAsk(model, approvals: false, reply: true))
        case "delete-orb": AnyView(model.bots.first.map { DeleteOrbSheet(botID: $0.id) })
        case "palette": AnyView(CommandPalette())
        case "shortcuts": AnyView(ShortcutsSheet())
        case "menubar-icons": AnyView(SystemSnapshots.menuBarIcons())
        case "editor": AnyView(OrbEditor(config: .constant(AppState.initial.bots[0].orb), name: "Atlas", category: .temperament))
        case let screen where screen.hasPrefix("editor-"):
            // `editor-hair`, `editor-eyes`…: the editor on one category, with a look that has hair and a hat.
            AnyView(OrbEditor(config: .constant(OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush",
                                                          hair: "chiquinhas", accessories: ["laco"])),
                              name: "Lia", category: OrbCategory(rawValue: String(screen.dropFirst(7))) ?? .color)
                .frame(width: 540))
        case let name where name.hasPrefix("transcript"):
            AnyView(model.bots.first.map { TranscriptSample.view(name, model: model, bot: $0) })
        default:
            RoutinesSnapshots.view(screen, model: model)
                ?? SidebarCategorySnapshots.view(screen, model: model)
                ?? ContextSnapshots.view(screen, model: model)
                ?? UsageSnapshots.view(screen, model: model)
                ?? Snapshot.composerScene(screen, model: model)
                ?? SettingsSnapshots.view(screen, firstBotID: model.bots.first?.id)
                ?? CatalogSnapshots.view(screen, model: model)
                ?? MultiOrbSnapshots.view(screen, model: model)
                ?? AnyView(model.bots.first.map { ChatView(botID: $0.id) })
        }
        let size = NSSize(width: ProcessInfo.processInfo.environment["ORB_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1100, height: height ?? 760)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NavigationStack { content }
            .environment(model)
            .preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        Task {
            // Give catalogs and images time to load.
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["ORB_SNAPSHOT_WAIT"] ?? "") ?? 8))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            DevRun.finish()
        }
    }
}

/// `--snapshot approvals`: a single card, a grouped one and an answered one, for visual review.
private struct ApprovalCardsSample: View {
    let bot: Bot

    private static func answeredHandoff(botName: String) -> ApprovalRequest {
        var card = ApprovalRequest.handoff(botName: botName, page: "https://github.com/login — “Sign in to GitHub”")
        card.decision = .once
        return card
    }

    var body: some View {
        let items = [ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/README.md"),
                     ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/notas.txt"),
                     ApprovalItem(toolName: "run_command", title: "Rodando no Terminal", command: "git commit -am \"Atualiza notas\"")]
        VStack(alignment: .leading, spacing: 12) {
            ApprovalCard(request: ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade",
                                                  reason: "", suggestions: [.shell("brew", "upgrade"), .shell("brew")]), botID: bot.id)
            ApprovalCard(request: ApprovalRequest(toolName: "batch", title: "3 ações precisam da sua permissão",
                                                  command: "", reason: "\(bot.name) precisa da sua permissão para continuar.",
                                                  suggestions: [.shell("git"), .folder("/Users/x/Projetos/app")], items: items), botID: bot.id)
            ApprovalCard(request: ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "rm -rf build",
                                                  reason: "", decision: .deny, note: "use a lixeira"), botID: bot.id)
            ApprovalCard(request: .handoff(botName: bot.name, page: "https://github.com/login — “Sign in to GitHub”"), botID: bot.id)
            ApprovalCard(request: Self.answeredHandoff(botName: bot.name), botID: bot.id)
        }
        .padding(24)
        .background(Palette.canvas)
    }
}
#endif
