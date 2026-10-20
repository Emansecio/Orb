import SwiftUI

/// An Orb's avatar that follows what the Orb does. It reads the Orb's activity, prompts sent, cues and whether you dictate
/// to it, and nothing else, so the view around it (the panel's form, the empty chat) does not re-render when the Orb starts
/// or stops working, talking or watching you type: only this avatar does.
struct LiveBotAvatar: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let orb: OrbConfig
    var size: CGFloat = 28
    var interactive = false
    /// Makes the Orb land (the empty chat's entrance): changes once, when it touches the floor.
    var landing = 0
    /// Holds still (the Orb eases into its resting pose and stops producing frames).
    var paused = false
    /// Lives only while it has something to do: working, celebrating, watching you type. Once the Orb is idle it
    /// settles into the resting pose and stops, so a reply that stays on screen costs nothing.
    var restsWhenIdle = false
    /// Off for the Orb on a stage with room around it (the empty chat): a big hair or hat keeps its full size there.
    var fits = true
    /// Lives for a few seconds (its entrance, the pointer on it, work), then settles and rests (`SettlingOrb`).
    var settles = false
    /// An interactive Orb that rests when idle wakes while the pointer is on it, so its gaze and click still work.
    @State private var hovering = false

    var body: some View {
        let live = model.live(botID)
        // While you dictate to it, an Orb with nothing else to do listens.
        let hearing = model.dictation.botID == botID && model.dictation.phase == .listening
        let activity = hearing && [.idle, .attentive].contains(live.activity) ? OrbActivity.listening : live.activity
        SettlingOrb(idle: settles && activity == .idle, wake: live.poke &+ landing) { settled in
            BotAvatar(orb: orb, size: size, activity: activity, celebration: live.celebration,
                      paused: paused || settled || (restsWhenIdle && activity == .idle && !hovering), ack: live.poke, landing: landing,
                      cue: live.cue, interactive: interactive, fits: fits)
        }
        .onHover { if interactive && restsWhenIdle { hovering = $0 } }
    }
}
