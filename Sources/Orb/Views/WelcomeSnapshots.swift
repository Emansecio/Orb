#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `Orb --snapshot welcome… out.png`: the welcome screen beside the sidebar, over an empty data folder
/// (`ORB_DATA_DIR` with `{"bots":[]}`, or the developer run would make the Atlas). The sidebar and the screen sit in
/// an `HStack`: offscreen, a `NavigationSplitView` leaves its sidebar column white. The Orbs come out still (snapshots
/// render offscreen, where Core Animation layers are not captured).
///
/// - `welcome`: no model yet, the card that connects one.
/// - `welcome-checking`: the connections are not checked yet (launch): hero, words and points, with the action's place kept.
/// - `welcome-ready`: a model is ready, the first Orb.
/// - `welcome-kept`: ready, with two memories kept from deleted Orbs.
/// - `welcome-returning`: the list was emptied ("Hora de um Orb novo").
/// - `welcome-narrow`: the ready screen; use `ORB_SNAPSHOT_WIDTH=1000 ORB_SNAPSHOT_HEIGHT=620` for the smallest window.
@MainActor
enum WelcomeSnapshots {
    static func view(_ screen: String) -> AnyView? {
        switch screen {
        case "welcome":
            return scene(WelcomeView(forcedStage: .connect, copy: .firstUse, kept: [], detectsProviders: false,
                                     claude: ClaudeCodeStatus(isInstalled: true)), copy: .firstUse)
        case "welcome-checking":
            return scene(WelcomeView(forcedStage: .checking, copy: .firstUse, kept: [], detectsProviders: false), copy: .firstUse)
        case "welcome-ready", "welcome-narrow":
            return scene(WelcomeView(forcedStage: .create, copy: .firstUse, kept: [], detectsProviders: false), copy: .firstUse)
        case "welcome-kept":
            let memories = sampleMemories()
            return scene(WelcomeView(forcedStage: .createWithKept, copy: .firstUse, kept: memories, detectsProviders: false), copy: .firstUse)
        case "welcome-returning":
            return scene(WelcomeView(forcedStage: .create, copy: .returning, kept: [], detectsProviders: false), copy: .returning)
        default:
            return nil
        }
    }

    private static func scene(_ welcome: WelcomeView, copy: WelcomeCopy) -> AnyView {
        AnyView(HStack(spacing: 0) {
            SidebarView(invitationCopy: copy).frame(width: 280)
            Divider().overlay(Color.black)
            welcome
        })
    }

    /// Two kept memories, written into a folder of their own that is gone as soon as they are listed (never the data
    /// folder, which may be the real one when `ORB_DATA_DIR` points at it).
    private static func sampleMemories() -> [KeptMemory] {
        let nina = KeptProfile(name: "Nina", role: "Cuida da minha agenda", orb: OrbConfig(color: "sol", eyes: "pilulas", mouth: "sorriso"))
        let luna = KeptProfile(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "lavanda", eyes: "ovais", mouth: "sorriso", cheeks: "blush"))
        return NewBotSnapshots.sampleKept(nina, luna)
    }
}
#endif
