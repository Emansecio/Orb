import SwiftUI

// How things come into the chat and the sheets (docs/MOVIMENTO.md §2.2, 2.4, 2.6, 2.8, 2.9), on top of the tokens of
// `Motion`: one small modifier that fades (and moves a few points) a view in when it appears, the ledger that says
// which rows of the transcript are new, and the pure choices behind both, so they are tested without a screen.
//
// Every entrance lives in the view that enters: a row has its own state that flips once when it appears. Nothing here
// animates the list as a whole, so a streamed reply (which never adds or moves a row) costs what it did before, and a
// long conversation does not lay itself out again when a message arrives.

// MARK: - The entrance of one view

/// How a view comes in: where it starts, how it gets there and how long it waits. Resolves to a plain fade under
/// Reduce Motion.
struct EntranceStyle: Equatable, Sendable {
    /// Points below its place it starts (negative: above). Only a translation, so the compositor moves it by itself.
    var distance: CGFloat
    /// Starting scale (1 = none).
    var scale: CGFloat = 1
    var animation: Animation
    /// Seconds to wait after the view appears.
    var delay: Double = 0

    /// A message, a row: rises 6 pt while it appears.
    static let rise = EntranceStyle(distance: 6, animation: Motion.enter)
    /// What needs you (an approval card): a little more distance, and a little scale.
    static let emphasis = EntranceStyle(distance: 10, scale: 0.98, animation: Motion.emphasis)
    /// The Orb of an empty chat, dropping in to land on the floor.
    static let drop = EntranceStyle(distance: -10, scale: 0.92, animation: .spring(response: 0.55, dampingFraction: 0.68))

    func delayed(_ seconds: Double) -> EntranceStyle {
        var copy = self
        copy.delay = seconds
        return copy
    }

    /// The `index`th of a short list that comes in together: `Motion.stagger` apart, the ones past the sixth with the
    /// sixth; `start` seconds after the list appears.
    static func staggered(_ index: Int, start: Double = 0) -> EntranceStyle {
        rise.delayed(start + Motion.staggerDelay(index))
    }

    /// What the view actually does: under Reduce Motion nothing moves or scales, everything fades in 0.15 s, together.
    struct Resolved: Equatable {
        var distance: CGFloat
        var scale: CGFloat
        var animation: Animation
    }

    func resolved(reduceMotion: Bool) -> Resolved {
        if reduceMotion { return Resolved(distance: 0, scale: 1, animation: Motion.fade) }
        return Resolved(distance: distance, scale: scale, animation: delay > 0 ? animation.delay(delay) : animation)
    }
}

/// Fades a view in (and moves it a few points) once, when it appears; a view that does not `enters` is simply there.
/// The state is the view's own, so it is not redone when a lazy list recreates the view later.
struct Entrance: ViewModifier {
    let style: EntranceStyle
    /// Called when the entrance is done (the Orb of an empty chat lands with a poke).
    var landed: (@MainActor () -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown: Bool

    init(_ style: EntranceStyle, enters: Bool, landed: (@MainActor () -> Void)? = nil) {
        self.style = style
        self.landed = landed
        _isShown = State(initialValue: !enters)
    }

    func body(content: Content) -> some View {
        let motion = style.resolved(reduceMotion: reduceMotion)
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown ? 1 : motion.scale)
            .offset(y: isShown ? 0 : motion.distance)
            .onAppear {
                guard !isShown else { return }
                let landed = landed
                withAnimation(motion.animation, completionCriteria: .logicallyComplete) {
                    isShown = true
                } completion: {
                    if let landed { MainActor.assumeIsolated { landed() } }
                }
            }
    }
}

extension View {
    /// Comes in with `style` when it appears, if `enters`.
    func entrance(_ style: EntranceStyle = .rise, enters: Bool = true, landed: (@MainActor () -> Void)? = nil) -> some View {
        modifier(Entrance(style, enters: enters, landed: landed))
    }

    /// A section of a sheet: on the sheet's first appearance it rises and appears in turn, 0.08 s after the sheet
    /// itself (the presentation is the system's). Everything together, without moving, under Reduce Motion.
    func sheetSection(_ index: Int) -> some View {
        entrance(.staggered(index, start: SheetEntrance.start))
    }

    /// `animation` for the changes of `value`, or the 0.15 s fade under Reduce Motion (where `animateChanges(of:)` is
    /// instant): for changes that are opacity transitions, which are not movement.
    func motion(_ animation: Animation = Motion.content, value: some Equatable) -> some View {
        modifier(AdaptedMotion(animation: animation, value: value))
    }
}

private struct AdaptedMotion<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.adapted(animation, reduceMotion: reduceMotion), value: value)
    }
}

enum SheetEntrance {
    /// Seconds after the sheet appears that its first section starts to come in.
    static let start = 0.08
}

extension Motion {
    /// The chat's content swapping for another's (an Orb or a conversation): a cross-fade, with no direction.
    static let crossFade = Animation.easeInOut(duration: 0.18)
}

// MARK: - Which rows are new

/// Tells the rows of a transcript which of them just arrived, so only those come in. An item is new when it appears
/// at the end of a list the view was already showing; what was there when the chat opened, what a conversation read
/// from disk brought, and the rows a lazy list recreates while scrolling are not. A list whose items were replaced
/// (another conversation) is not new rows but new content: `generation` changes then, and the chat cross-fades. The
/// session says so (`swaps`); without it the shape of the list is the guess (an empty list suddenly holding more than
/// `largestArrival`, or a head nobody knew). A burst of items at the end of a list that was showing something is
/// never a swap (nine tools started in one step).
///
/// Asked once per evaluation of the list's body (`observe` does the same when asked again with the same items), and
/// costs the length of what arrived, not of the conversation.
@MainActor
final class TranscriptEntrances {
    /// More than this many items appearing at once is a conversation arriving, not messages.
    nonisolated static let largestArrival = 8
    /// How long an item stays new if its row is not made (it is far off screen).
    nonisolated static let lifetime: TimeInterval = 2

    /// Changes whenever the items on show were replaced by another conversation's.
    private(set) var generation = 0
    private var known: Set<UUID> = []
    private var arrivals: [UUID: Date] = [:]
    private var lastCount = 0
    private var lastID: UUID?
    private var lastSwaps = 0
    private var hasSeen = false
    private var wasLoading = false

    init() {}

    @discardableResult
    func observe(_ items: [TranscriptItem], isLoading: Bool, swaps: Int = 0, now: Date = .now) -> Int {
        defer { wasLoading = isLoading }
        let swapped = swaps != lastSwaps
        lastSwaps = swaps
        // The first look, and a conversation being read from disk, are what is there: settled, nothing new.
        guard hasSeen, !isLoading, !wasLoading else {
            hasSeen = true
            settle(on: items)
            return generation
        }
        // The session says the conversation was replaced (a new one, one reopened from Conversas), however short.
        if swapped {
            if items.isEmpty && lastCount == 0 { settle(on: items) } else { replace(with: items) }
            return generation
        }
        if items.count == lastCount, items.last?.id == lastID { return generation }

        guard let last = items.last else {
            // Emptied: a new conversation (or an Orb's chat cleared).
            if lastCount > 0 { replace(with: items) } else { settle(on: items) }
            return generation
        }
        // A head nobody knew is another conversation, whatever the session said.
        if lastCount > 0, !(items.first.map { known.contains($0.id) } ?? true) {
            replace(with: items)
            return generation
        }
        // New items are the unknown ones at the end. In a list that was showing something they are always arrivals, however
        // many a burst of parallel tools brings at once (only the newest `largestArrival` come in); an empty list suddenly
        // holding more than that is a conversation arriving.
        var arrived: [UUID] = []
        var index = items.count - 1
        while index >= 0, !known.contains(items[index].id), lastCount > 0 || arrived.count <= Self.largestArrival {
            arrived.append(items[index].id)
            index -= 1
        }
        if lastCount == 0, arrived.count > Self.largestArrival {
            replace(with: items)
        } else {
            for id in arrived.prefix(Self.largestArrival) { arrivals[id] = now }
            known.formUnion(arrived)
            lastCount = items.count
            lastID = last.id
            dropExpired(now: now)
        }
        return generation
    }

    /// Whether the row of `id` should come in when it is made. Pure: asking twice gives the same answer until the row
    /// has appeared (`appeared`) or the item has aged.
    func isNew(_ id: UUID, now: Date = .now) -> Bool {
        guard let arrival = arrivals[id] else { return false }
        return now.timeIntervalSince(arrival) < Self.lifetime
    }

    /// The row of `id` is on screen: it will not come in again.
    func appeared(_ id: UUID) {
        arrivals[id] = nil
    }

    private func settle(on items: [TranscriptItem]) {
        known = Set(items.lazy.map(\.id))
        arrivals.removeAll()
        lastCount = items.count
        lastID = items.last?.id
    }

    private func replace(with items: [TranscriptItem]) {
        generation &+= 1
        settle(on: items)
    }

    private func dropExpired(now: Date) {
        guard !arrivals.isEmpty else { return }
        arrivals = arrivals.filter { now.timeIntervalSince($0.value) < Self.lifetime }
    }
}

/// The entrance a transcript row has: an approval card comes in with emphasis, everything else rises.
extension TranscriptItem.Kind {
    var entrance: EntranceStyle {
        if case .approval = self { return .emphasis }
        return .rise
    }

    /// What the Orb said (its reply, its greeting): the last of these at the end of the chat carries the living avatar.
    var isReply: Bool {
        switch self {
        case .bot, .greeting: true
        default: false
        }
    }
}

/// Fades and moves a row of the transcript in when it is new, then forgets it was.
struct RowEntrance: ViewModifier {
    let id: UUID
    let style: EntranceStyle
    let isNew: Bool
    let entrances: TranscriptEntrances

    func body(content: Content) -> some View {
        content
            .modifier(Entrance(style, enters: isNew))
            .onAppear { entrances.appeared(id) }
    }
}

// MARK: - The empty chat

/// The order the empty chat comes in (§2.8): the Orb drops in first; its name and role follow 0.08 s later, then
/// what it works on, then the suggestions in turn.
enum EmptyChatEntrance {
    static let nameDelay = 0.08
    static let contextDelay = 0.12
    static let suggestionsStart = 0.16

    /// Whether the entrance plays: the first time this Orb's empty chat shows in the session. Where nothing records
    /// that (no root view: a preview, a snapshot) the chat just shows.
    @MainActor static func plays(for orb: UUID, in presented: PresentedOrbs?) -> Bool {
        guard let presented else { return false }
        return !presented.contains(orb)
    }
}

// MARK: - Scrolling to what you sent

enum ScrollMotion {
    /// The list glides to the message you just sent when it was already at the end.
    static let sent = Animation.smooth(duration: 0.3)

    /// No animation under Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : sent }
}

// MARK: - Once per Orb, per session

/// The Orbs whose empty chat already played its entrance this session (§2.8): switching to another Orb and back does
/// not play it again. A reference held by the root view, so it outlives the chat views and costs no re-render.
final class PresentedOrbs: @unchecked Sendable {
    private var ids: Set<UUID> = []

    init() {}

    @MainActor func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Whether this is the first time `id` was recorded.
    @MainActor @discardableResult func insert(_ id: UUID) -> Bool { ids.insert(id).inserted }
}

extension EnvironmentValues {
    /// Nil where there is no root view (previews, snapshots): the empty chat then shows without its entrance.
    @Entry var presentedEmptyChats: PresentedOrbs? = nil
    /// The queued messages (by id) that already came in this session; nil where there is no root view. A bubble that is
    /// made again (the chat reopened, the lazy list recreating the row) does not enter a second time.
    @Entry var presentedQueued: PresentedOrbs? = nil
}

// MARK: - The pulse of an approval card

/// One soft pulse on the border of an approval card that has just arrived, in the warning color, and then it stops:
/// the border goes from nothing to 0.35 to 0.12 and back to nothing in 0.9 s. Nothing under Reduce Motion.
enum ApprovalPulse {
    /// Rest, peak, settle, rest. (The sequence ends at rest by itself, whether or not the animator returns to its first phase.)
    static let phases = [0, 1, 2, 3]
    static let opacities = [0, 0.35, 0.12, 0]
    /// Seconds each phase takes to be reached; they add up to 0.9.
    static let durations = [0, 0.25, 0.3, 0.35]

    static func opacity(_ phase: Int) -> Double {
        opacities.indices.contains(phase) ? opacities[phase] : 0
    }

    /// Seconds the pulse waits after the card appears, so it starts as the card settles, not while it still arrives.
    static let lead = 0.2

    static func animation(_ phase: Int) -> Animation? {
        guard durations.indices.contains(phase), durations[phase] > 0 else { return nil }
        let curve = Animation.easeInOut(duration: durations[phase])
        return phase == 1 ? curve.delay(lead) : curve
    }

    static var totalDuration: Double { durations.reduce(0, +) }

    /// Whether the card pulses: only a card that arrived while the chat was open, and never under Reduce Motion.
    static func pulses(isNew: Bool, reduceMotion: Bool) -> Bool { isNew && !reduceMotion }
}

/// The border that pulses; invisible at rest.
struct ApprovalPulseBorder: View {
    let radius: CGFloat
    /// Changing it plays the pulse once.
    let trigger: Int

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(Palette.warn, lineWidth: 1.5)
            .phaseAnimator(ApprovalPulse.phases, trigger: trigger) { border, phase in
                border.opacity(ApprovalPulse.opacity(phase))
            } animation: { phase in
                ApprovalPulse.animation(phase)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
