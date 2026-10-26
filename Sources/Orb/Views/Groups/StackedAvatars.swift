import SwiftUI

/// The Orbs of a group one over the other: up to three, or two and a "+N" pill in the third place. The slot has a fixed
/// width (three overlapped avatars, whatever the count), so the names beside it start at the same x in every row. The
/// header uses it at 24 pt, overlapped by 9 pt, the sidebar smaller (`SidebarGroupRow`), each Orb ringed in the chrome's color so they separate.
/// Only an Orb that is doing something moves; the others rest.
struct StackedAvatars: View {
    struct Member: Equatable {
        var id: UUID
        var orb: OrbConfig
        var activity: OrbActivity = .idle
    }

    let members: [Member]
    var size: CGFloat = 24
    /// How much of an avatar the next one covers: the header's 9 pt, or what a narrower slot asks (the sidebar).
    var overlap: CGFloat = StackedAvatars.headerOverlap

    static let headerOverlap: CGFloat = 9

    /// How many Orbs are drawn and how many the "+N" pill counts: what the stack shows for `count` Orbs.
    static func plan(count: Int) -> (shown: Int, extra: Int) {
        count <= 3 ? (max(0, count), 0) : (2, count - 2)
    }

    /// The width of the slot: three avatars overlapped, the same for every group.
    static func slotWidth(size: CGFloat, overlap: CGFloat) -> CGFloat { size * 3 - overlap * 2 }

    /// Where the place `index` starts (0, 1, 2), from the left edge of the slot.
    static func offset(of index: Int, size: CGFloat, overlap: CGFloat) -> CGFloat { CGFloat(index) * (size - overlap) }

    var body: some View {
        let plan = Self.plan(count: members.count)
        ZStack(alignment: .leading) {
            ForEach(Array(members.prefix(plan.shown).enumerated()), id: \.element.id) { index, member in
                BotAvatar(orb: member.orb, size: size, activity: member.activity, paused: member.activity == .idle)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
                    .offset(x: Self.offset(of: index, size: size, overlap: overlap))
            }
            if plan.extra > 0 {
                Text("+\(plan.extra)")
                    .font(Typography.small.weight(.semibold))
                    // Past 9 Orbs the count has two digits: it shrinks to stay inside a small circle.
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(Palette.secondary)
                    .frame(width: size, height: size)
                    .background(Palette.raised, in: .circle)
                    .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
                    .offset(x: Self.offset(of: plan.shown, size: size, overlap: overlap))
            }
        }
        .frame(width: Self.slotWidth(size: size, overlap: overlap), height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}
