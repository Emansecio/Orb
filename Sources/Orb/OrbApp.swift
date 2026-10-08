import SwiftUI
import AppKit

/// `Orb --memory-mcp <folder>` runs only the memory tools for Claude Code (no window); anything else is the app.
@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: MemoryMCPServer.flag), arguments.indices.contains(flag + 1) {
            MemoryMCPServer.serve(directory: URL(fileURLWithPath: arguments[flag + 1]))
            exit(0)
        }
        OrbApp.main()
    }
}

struct OrbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Orb", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
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
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("Orb", systemImage: "circle.hexagongrid.fill") {
            QuickAskView()
                .environment(model)
                .preferredColorScheme(.dark)
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
        // Snapshots render in the background: no Dock icon, never takes focus.
        if snapshot != nil { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev aid: `Orb --snapshot skills-explore out.png` renders one screen offscreen and exits.
        if let snapshot {
            NSApp.windows.forEach { $0.orderOut(nil) }
            Snapshot.render(snapshot.screen, to: snapshot.url)
            return
        }
        // Dev aid: `Orb --render-orbs out.png` writes a sheet of Orbs × activities and exits.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-orbs"), arguments.indices.contains(flag + 1) {
            OrbSheet.render(to: URL(fileURLWithPath: arguments[flag + 1]))
            exit(0)
        }
        // `Orb --render-icon out.png` writes the 1024 px app icon (used by scripts/bundle.sh).
        if let flag = arguments.firstIndex(of: "--render-icon"), arguments.indices.contains(flag + 1) {
            OrbSheet.renderIcon(to: URL(fileURLWithPath: arguments[flag + 1]))
            exit(0)
        }
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Novo Orb…") { model.showNewBot = true }
                .keyboardShortcut("n")
            Button("Nova conversa") {
                if let id = model.selectedBot?.id { model.newConversation(id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Mostrar/ocultar detalhes") { model.showInspector.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
        CommandMenu("Orbs") {
            Button("Orb anterior") { model.selectAdjacentBot(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Próximo Orb") { model.selectAdjacentBot(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Divider()
            ForEach(Array(model.bots.prefix(9).enumerated()), id: \.element.id) { index, bot in
                Button(bot.name) { model.selection = .bot(bot.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}

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

    /// Atlas on the standard macOS icon tile (824 pt rounded square inside a 1024 canvas).
    static func renderIcon(to url: URL) {
        let orb = AppState.initial.bots[0].orb
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x24233A), Color(hex: 0x09090F)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 2))
                .frame(width: 824, height: 824)
            OrbView(config: orb, size: 420, animated: false)
                .offset(y: -20)
        }
        .frame(width: 1024, height: 1024)
        write(icon, scale: 1, to: url)
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
    static func render(_ screen: String, to url: URL) {
        let model = AppModel()
        model.showInspector = false // the inspector column does not render offscreen
        model.sendLaunchPrompt()
        let content: AnyView = switch screen {
        case "app": AnyView(RootView())
        case "skills": AnyView(SkillsView())
        case "skills-explore": AnyView(SkillsView(tab: .explore))
        case "connectors": AnyView(ConnectorsView())
        case "connectors-explore": AnyView(ConnectorsView(tab: .explore))
        case "routines": AnyView(RoutinesView())
        case "models": AnyView(ProviderSettings())
        case "inspector": AnyView(model.bots.first.map { BotInspector(botID: $0.id).frame(width: 360) })
        case "new-orb": AnyView(NewBotSheet())
        case "editor": AnyView(OrbEditor(config: .constant(AppState.initial.bots[0].orb), name: "Atlas", category: .temperament))
        default: AnyView(model.bots.first.map { ChatView(bot: $0) })
        }
        let size = NSSize(width: 1100, height: ProcessInfo.processInfo.environment["ORB_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 760)
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
            exit(0)
        }
    }
}
