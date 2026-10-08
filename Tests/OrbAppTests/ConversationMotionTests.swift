import Foundation
import SwiftUI
import Testing
@testable import Orb

/// The motion of the chat (docs/MOVIMENTO.md §2.2, 2.3, 2.4, 2.6, 2.8, 2.9): which entrance or animation is chosen, with
/// and without Reduce Motion, which rows count as new, the delays of the staggers and the "first time only" sets. The
/// motion itself is SwiftUI's; what is decided here is tested without a screen.
@Suite("Conversation motion") @MainActor struct ConversationMotionTests {
    private func user(_ text: String = "oi") -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }
    private func reply() -> TranscriptItem { TranscriptItem(.bot(text: "olá", isStreaming: true)) }
    private func items(_ count: Int) -> [TranscriptItem] { (0..<count).map { user("m\($0)") } }
    private func ids(_ items: [TranscriptItem]) -> [UUID] { items.map(\.id) }

    // MARK: Entrance styles

    @Test func aMessageRisesSixPointsWithTheEnterSpring() {
        let motion = EntranceStyle.rise.resolved(reduceMotion: false)
        #expect(motion.distance == 6)
        #expect(motion.scale == 1)
        #expect(motion.animation == Motion.enter)
    }

    @Test func anApprovalCardComesInWithEmphasis() {
        let motion = EntranceStyle.emphasis.resolved(reduceMotion: false)
        #expect(motion.distance == 10)
        #expect(motion.scale == 0.98)
        #expect(motion.animation == Motion.emphasis)
        #expect(TranscriptItem.Kind.approval(ApprovalRequest(toolName: "run_command", title: "t", command: "c", reason: "")).entrance == .emphasis)
        #expect(TranscriptItem.Kind.user(text: "a", attachments: []).entrance == .rise)
        #expect(TranscriptItem.Kind.bot(text: "a", isStreaming: true).entrance == .rise)
        #expect(TranscriptItem.Kind.tool(ToolCall(kind: .shell, title: "t", detail: "d")).entrance == .rise)
        #expect(TranscriptItem.Kind.notice("a").entrance == .rise)
    }

    @Test func theOrbOfAnEmptyChatDropsInFromAbove() {
        let motion = EntranceStyle.drop.resolved(reduceMotion: false)
        #expect(motion.distance == -10)
        #expect(motion.scale == 0.92)
        #expect(motion.animation == .spring(response: 0.55, dampingFraction: 0.68))
    }

    @Test func underReduceMotionEveryEntranceIsAPlainFadeInPlace() {
        let styles: [EntranceStyle] = [.rise, .emphasis, .drop, .staggered(3, start: 0.08), .rise.delayed(0.2)]
        for style in styles {
            let motion = style.resolved(reduceMotion: true)
            #expect(motion.distance == 0, "\(style)")
            #expect(motion.scale == 1, "\(style)")
            #expect(motion.animation == Motion.fade, "\(style)")
        }
    }

    @Test func aDelayedEntranceWaitsAndOneWithoutDelayDoesNot() {
        #expect(EntranceStyle.rise.resolved(reduceMotion: false).animation == Motion.enter)
        #expect(EntranceStyle.rise.delayed(0.08).resolved(reduceMotion: false).animation == Motion.enter.delay(0.08))
    }

    // MARK: Staggers

    @Test func staggeredEntrancesAreThirtyFiveMillisecondsApartAndStopAtTheSixth() {
        let delays = (0..<9).map { EntranceStyle.staggered($0).delay }
        let expected = [0, 0.035, 0.07, 0.105, 0.14, 0.175, 0.175, 0.175, 0.175]
        for (delay, wanted) in zip(delays, expected) { #expect(abs(delay - wanted) < 1e-9) }
    }

    @Test func aSheetsSectionsStartEightyMillisecondsAfterTheSheet() {
        #expect(SheetEntrance.start == 0.08)
        let first = EntranceStyle.staggered(0, start: SheetEntrance.start)
        let third = EntranceStyle.staggered(2, start: SheetEntrance.start)
        #expect(abs(first.delay - 0.08) < 1e-9)
        #expect(abs(third.delay - 0.15) < 1e-9)
        // Together under Reduce Motion: no delay survives.
        #expect(third.resolved(reduceMotion: true).animation == Motion.fade)
    }

    @Test func theEmptyChatComesInInOrder() {
        // The Orb first, then the name 0.08 s later, what it works on, then the suggestions one after another.
        #expect(EmptyChatEntrance.nameDelay == 0.08)
        #expect(EmptyChatEntrance.nameDelay < EmptyChatEntrance.contextDelay)
        #expect(EmptyChatEntrance.contextDelay < EmptyChatEntrance.suggestionsStart)
        let suggestions = (0..<4).map { EntranceStyle.staggered($0, start: EmptyChatEntrance.suggestionsStart).delay }
        #expect(suggestions == suggestions.sorted())
        #expect(suggestions.first == EmptyChatEntrance.suggestionsStart)
    }

    // MARK: Crossfade and scroll

    @Test func theChatSwapIsAnEighteenHundredthsCrossFadeAndAPlainFadeUnderReduceMotion() {
        #expect(Motion.adapted(Motion.crossFade, reduceMotion: false) == Animation.easeInOut(duration: 0.18))
        #expect(Motion.adapted(Motion.crossFade, reduceMotion: true) == Motion.fade)
    }

    @Test func theListGlidesToWhatYouSentAndJumpsUnderReduceMotion() {
        #expect(ScrollMotion.animation(reduceMotion: false) == .smooth(duration: 0.3))
        #expect(ScrollMotion.animation(reduceMotion: true) == nil)
    }

    // MARK: Which rows are new

    @Test func whatWasThereWhenTheChatOpenedIsNotNew() {
        let ledger = TranscriptEntrances()
        let opening = items(5)
        let generation = ledger.observe(opening, isLoading: false)
        for item in opening { #expect(!ledger.isNew(item.id)) }
        #expect(ledger.observe(opening, isLoading: false) == generation)
    }

    @Test func aMessageAddedAtTheEndIsNewUntilItsRowHasAppeared() {
        let ledger = TranscriptEntrances()
        var list = items(3)
        ledger.observe(list, isLoading: false)
        let sent = user("novo")
        list.append(sent)
        ledger.observe(list, isLoading: false)
        #expect(ledger.isNew(sent.id))
        // Asking again (the list's body runs again) says the same until the row is on screen.
        ledger.observe(list, isLoading: false)
        #expect(ledger.isNew(sent.id))
        #expect(list.dropLast().allSatisfy { !ledger.isNew($0.id) })
        ledger.appeared(sent.id)
        #expect(!ledger.isNew(sent.id))
    }

    @Test func aReplyThatArrivesRightAfterTheMessageIsNewToo() {
        let ledger = TranscriptEntrances()
        var list = items(2)
        ledger.observe(list, isLoading: false)
        let sent = user(), answer = reply()
        list += [sent, answer]
        ledger.observe(list, isLoading: false)
        #expect(ledger.isNew(sent.id) && ledger.isNew(answer.id))
    }

    @Test func aRowStopsBeingNewIfItsNeverMade() {
        let ledger = TranscriptEntrances()
        var list = items(1)
        let start = Date(timeIntervalSince1970: 1_000)
        ledger.observe(list, isLoading: false, now: start)
        let sent = user()
        list.append(sent)
        ledger.observe(list, isLoading: false, now: start)
        #expect(ledger.isNew(sent.id, now: start.addingTimeInterval(1.9)))
        #expect(!ledger.isNew(sent.id, now: start.addingTimeInterval(2.1)))
    }

    @Test func aStreamedReplyEndingChangesNothingAboutNewness() {
        // The reply's item is updated in place when it ends (same id, same position): not a new row.
        let ledger = TranscriptEntrances()
        var list = items(2)
        ledger.observe(list, isLoading: false)
        let answer = reply()
        list.append(answer)
        ledger.observe(list, isLoading: false)
        ledger.appeared(answer.id)
        list[list.count - 1].kind = .bot(text: "olá, pronto", isStreaming: false)
        let generation = ledger.generation
        ledger.observe(list, isLoading: false)
        #expect(!ledger.isNew(answer.id))
        #expect(ledger.generation == generation)
    }

    @Test func aConversationReadFromDiskIsNotNewEvenIfShort() {
        let ledger = TranscriptEntrances()
        ledger.observe([], isLoading: true)
        let loaded = items(3)
        let generation = ledger.generation
        ledger.observe(loaded, isLoading: false)
        for item in loaded { #expect(!ledger.isNew(item.id)) }
        #expect(ledger.generation == generation)
        // ... and the first message after it is.
        let sent = user()
        ledger.observe(loaded + [sent], isLoading: false)
        #expect(ledger.isNew(sent.id))
    }

    @Test func theFirstMessageOfAnEmptyChatIsNew() {
        let ledger = TranscriptEntrances()
        ledger.observe([], isLoading: false)
        let sent = user()
        ledger.observe([sent], isLoading: false)
        #expect(ledger.isNew(sent.id))
        #expect(ledger.generation == 0)
    }

    @Test func anotherConversationReplacesTheContentInsteadOfBringingNewRows() {
        let ledger = TranscriptEntrances()
        ledger.observe(items(4), isLoading: false)
        let other = items(2) // fewer than the cap: still a different conversation, by its first item
        let generation = ledger.generation
        ledger.observe(other, isLoading: false)
        #expect(ledger.generation == generation + 1)
        for item in other { #expect(!ledger.isNew(item.id)) }
    }

    @Test func aNewConversationEmptiesTheChatAndCountsAsAReplacement() {
        let ledger = TranscriptEntrances()
        ledger.observe(items(3), isLoading: false)
        let generation = ledger.generation
        ledger.observe([], isLoading: false)
        #expect(ledger.generation == generation + 1)
        // Messages typed into the new one are new rows of it.
        let sent = user()
        ledger.observe([sent], isLoading: false)
        #expect(ledger.isNew(sent.id))
        #expect(ledger.generation == generation + 1)
    }

    @Test func aConversationReopenedOverAnEmptyChatReplacesIt() {
        let ledger = TranscriptEntrances()
        ledger.observe([], isLoading: false)
        let reopened = items(TranscriptEntrances.largestArrival + 4)
        ledger.observe(reopened, isLoading: false)
        #expect(ledger.generation == 1)
        for item in reopened { #expect(!ledger.isNew(item.id)) }
    }

    @Test func aShortConversationReopenedOverAnEmptyChatReplacesItWhenTheSessionSaysSo() {
        // Five items, under the cap: only the session knows another conversation was installed.
        let ledger = TranscriptEntrances()
        ledger.observe([], isLoading: false)
        let reopened = items(5)
        ledger.observe(reopened, isLoading: false, swaps: 1)
        #expect(ledger.generation == 1)
        for item in reopened { #expect(!ledger.isNew(item.id)) }
        // ... and what is typed into it afterwards is new, with no further replacement.
        let sent = user()
        ledger.observe(reopened + [sent], isLoading: false, swaps: 1)
        #expect(ledger.isNew(sent.id))
        #expect(ledger.generation == 1)
    }

    @Test func aNewConversationOverAnEmptyChatReplacesNothing() {
        let ledger = TranscriptEntrances()
        ledger.observe([], isLoading: false)
        ledger.observe([], isLoading: false, swaps: 1)
        #expect(ledger.generation == 0)
    }

    @Test func installingAChatCountsAsASwapOfTheOrbsTranscript() {
        let transcript = OrbTranscript(items: [])
        #expect(transcript.swaps == 0)
        transcript.swapped()
        #expect(transcript.swaps == 1)
    }

    @Test func aTurnRetriedKeepsTheConversationAndOnlyTheResentMessageIsNew() {
        let ledger = TranscriptEntrances()
        let opening = items(3)
        let failed = user("tenta"), notice = TranscriptItem(.notice("Não deu certo: x"))
        ledger.observe(opening + [failed, notice], isLoading: false)
        let generation = ledger.generation
        let resent = user("tenta")
        ledger.observe(opening + [resent], isLoading: false)
        #expect(ledger.generation == generation)
        #expect(ledger.isNew(resent.id))
        #expect(opening.allSatisfy { !ledger.isNew($0.id) })
    }

    @Test func itemsTakenBackAndPutAgainDoNotComeInAgain() {
        // "Tentar de novo" puts the items back when nothing could be sent.
        let ledger = TranscriptEntrances()
        let list = items(4)
        ledger.observe(list, isLoading: false)
        ledger.observe(Array(list.dropLast(2)), isLoading: false)
        ledger.observe(list, isLoading: false)
        #expect(list.allSatisfy { !ledger.isNew($0.id) })
    }

    @Test func aLongStretchOfStatusChangesCostsNothingAndChangesNothing() {
        // The list's body runs for many reasons (a status line, a queued message); the items are the same each time.
        let ledger = TranscriptEntrances()
        let list = items(200)
        ledger.observe(list, isLoading: false)
        for _ in 0..<1_000 { ledger.observe(list, isLoading: false) }
        #expect(ledger.generation == 0)
        #expect(list.allSatisfy { !ledger.isNew($0.id) })
    }

    // MARK: First time per Orb

    @Test func theEmptyChatOfAnOrbComesInTheFirstTimeOnly() {
        let presented = PresentedOrbs()
        let atlas = UUID(), luna = UUID()
        #expect(EmptyChatEntrance.plays(for: atlas, in: presented))
        // Asking does not use it up: the view might be made twice before it appears.
        #expect(EmptyChatEntrance.plays(for: atlas, in: presented))
        #expect(presented.insert(atlas))
        #expect(!EmptyChatEntrance.plays(for: atlas, in: presented))
        #expect(!presented.insert(atlas))
        // Another Orb is its own first time.
        #expect(EmptyChatEntrance.plays(for: luna, in: presented))
    }

    @Test func withoutARootViewTheEmptyChatJustShows() {
        #expect(!EmptyChatEntrance.plays(for: UUID(), in: nil))
    }

    // MARK: Approval card

    @Test func theApprovalPulseGoesFromNothingToTheEdgeAndSettlesBackInNineTenthsOfASecond() {
        #expect(ApprovalPulse.phases.map(ApprovalPulse.opacity) == [0, 0.35, 0.12, 0])
        #expect(abs(ApprovalPulse.totalDuration - 0.9) < 1e-9)
        #expect(ApprovalPulse.opacity(99) == 0)
        // The first phase is the rest the card starts in: nothing animates into it.
        #expect(ApprovalPulse.animation(0) == nil)
        #expect(ApprovalPulse.animation(1) == Animation.easeInOut(duration: 0.25).delay(ApprovalPulse.lead))
        #expect(ApprovalPulse.animation(2) == Animation.easeInOut(duration: 0.3))
    }

    @Test func onlyACardThatArrivedWhileTheChatWasOpenPulsesAndNeverUnderReduceMotion() {
        #expect(ApprovalPulse.pulses(isNew: true, reduceMotion: false))
        #expect(!ApprovalPulse.pulses(isNew: false, reduceMotion: false))
        #expect(!ApprovalPulse.pulses(isNew: true, reduceMotion: true))
    }

    @Test func aShortcutShowsItsButtonPressedForOneBeatAndNotUnderReduceMotion() {
        #expect(ApprovalShortcut.pressDelay(reduceMotion: false) == .milliseconds(120))
        #expect(ApprovalShortcut.pressDelay(reduceMotion: true) == .zero)
        #expect(ApprovalShortcut.pressScale == 0.97)
    }

    @Test func aLongGroupRevealsItsActionsOneAfterAnotherAtMostSixStaggered() {
        // "Mostrar mais": the revealed actions follow `Motion.stagger`; the seventh and later come with the sixth.
        let delays = (0..<10).map { Motion.staggerDelay($0) }
        #expect(delays[0] == 0)
        #expect(abs(delays[5] - 0.175) < 1e-9)
        #expect(delays[6...].allSatisfy { $0 == delays[5] })
    }
}
