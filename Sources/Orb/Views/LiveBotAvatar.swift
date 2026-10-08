import SwiftUI

/// An Orb's avatar that follows what the Orb does. It reads the Orb's activity and poke and nothing else, so the
/// view around it (the panel's form, the empty chat) does not re-render when the Orb starts or stops working,
/// talking or watching you type: only this avatar does.
struct LiveBotAvatar: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let orb: OrbConfig
    var size: CGFloat = 28
    var interactive = false
    /// Added to the Orb's own pokes (e.g. the empty chat's landing).
    var extraPoke = 0

    var body: some View {
        let live = model.live(botID)
        BotAvatar(orb: orb, size: size, activity: live.activity, poke: live.poke &+ extraPoke, interactive: interactive)
    }
}
