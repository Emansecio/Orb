import SwiftUI

/// The Orbs of a group one over the other: up to three, or two and a "+N" pill in the third place. The slot has a fixed
/// width (three overlapped avatars, whatever the count), so the names beside it start at the same x in every row. The
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

    /// The width of the slot: three avatars overlapped, the same for every group.
    static func slotWidth(size: CGFloat) -> CGFloat { size * 3 - overlap * 2 }

    /// Where the place `index` starts (0, 1, 2), from the left edge of the slot.
    static func offset(of index: Int, size: CGFloat) -> CGFloat { CGFloat(index) * (size - overlap) }

    var body: some View {
        let plan = Self.plan(count: members.count)
        ZStack(alignment: .leading) {
            ForEach(Array(members.prefix(plan.shown).enumerated()), id: \.element.id) { index, member in
                BotAvatar(orb: member.orb, size: size, activity: member.activity, paused: member.activity == .idle)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
                    .offset(x: Self.offset(of: index, size: size))
            }
            if plan.extra > 0 {
                Text("+\(plan.extra)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: size, height: size)
                    .background(Palette.raised, in: .circle)
                    .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
                    .offset(x: Self.offset(of: plan.shown, size: size))
            }
        }
        .frame(width: Self.slotWidth(size: size), height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}
