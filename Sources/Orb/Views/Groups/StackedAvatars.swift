import SwiftUI

/// The Orbs of a group one over the other: up to three, or two and a "+N" pill for the rest (the third place). The
/// sidebar and the header use it at 24 pt, overlapped by 9 pt, each Orb ringed in the chrome's color so they separate.
/// Only an Orb that is doing something moves; the others rest.
struct StackedAvatars: View {
    struct Member: Equatable {
        var id: UUID
        var orb: OrbConfig
        var activity: OrbActivity = .idle
    }

    let members: [Member]
    var size: CGFloat = 24

    static let overlap: CGFloat = 9

    /// How many Orbs are drawn and how many the "+N" pill counts: what the stack shows for `count` Orbs.
    static func plan(count: Int) -> (shown: Int, extra: Int) {
        count <= 3 ? (max(0, count), 0) : (2, count - 2)
    }

    var body: some View {
        let plan = Self.plan(count: members.count)
        HStack(spacing: -Self.overlap) {
            ForEach(members.prefix(plan.shown), id: \.id) { member in
                BotAvatar(orb: member.orb, size: size, activity: member.activity, paused: member.activity == .idle)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
            }
            if plan.extra > 0 {
                Text("+\(plan.extra)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: size)
                    .background(Palette.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Palette.chrome, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}
