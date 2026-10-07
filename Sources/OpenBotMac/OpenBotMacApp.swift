import SwiftUI
import AppKit

@main
struct OpenBotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("OpenBot", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
                .task { await runDemoIfRequested() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("OpenBot", systemImage: "circle.hexagongrid.fill") {
            QuickAskView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .menuBarExtraStyle(.window)
    }
}

extension OpenBotMacApp {
    /// Dev aid: `OPENBOT_DEMO=1` sends a prompt to the selected bot shortly after launch,
    /// to watch the Orb go through listening → task activities → celebrating without typing.
    @MainActor
    private func runDemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["OPENBOT_DEMO"] != nil, let bot = model.selectedBot else { return }
        try? await Task.sleep(for: .seconds(2))
        model.send("Organize meus downloads e pesquise o que há de novo no macOS", to: bot.id)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev aid: `OpenBot --render-orbs out.png` writes a sheet of Orbs × activities and exits.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-orbs"), arguments.indices.contains(flag + 1) {
            OrbSheet.render(to: URL(fileURLWithPath: arguments[flag + 1]))
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
            Button("Novo bot…") { model.showNewBot = true }
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
        CommandMenu("Bots") {
            Button("Bot anterior") { model.selectAdjacentBot(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Próximo bot") { model.selectAdjacentBot(offset: 1) }
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
        let activities: [OrbActivity] = [.idle, .thinking, .typing, .searching, .waiting, .happy, .error, .sleepy]
        let orbs = SeedData.make().bots.map(\.orb) + [
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

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
