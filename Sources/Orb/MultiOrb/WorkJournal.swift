import Foundation

/// One piece of work that was in flight, kept on disk so the next launch can pick it up (`AppModel.resumeInterruptedWork`).
/// A flat struct with optional fields, so a version that reads a file with a kind it does not know skips that entry only.
struct WorkEntry: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// A turn of an Orb's own conversation (never a routine's run, a request's or a group's).
        case chatTask
        /// A request of the person to a group, from the message that starts it until the group has nothing left to do.
        case groupRun
        /// A request one Orb made of another outside any group.
        case request
        /// An Orb's pulse run (`botID`). Never resumed: the next pulse covers it (`AppModel.resumeInterruptedWork` drops it).
        case pulse
        case unknown

        init(from decoder: Decoder) throws { self = try decoder.rawValue(Self.self, fallback: .unknown) }
    }

    var id = UUID()
    var kind: Kind
    var startedAt: Date
    /// Times the app already took this up again after a close: one per interruption, so a task that closes the app is not
    /// restarted for ever.
    var resumes = 0
    /// `chatTask`: the Orb and the conversation of the turn.
    var botID: UUID?
    var chatID: UUID?
    /// `chatTask`: background processes the Orb had running when the app quit (they die with it).
    var lostJobs = 0
    /// `groupRun`: the group, the run's id in the thread and what was asked.
    var groupID: UUID?
    var runID: UUID?
    var text: String?
    /// `request`: the message as it was sent.
    var envelope: OrbEnvelope?
}

extension WorkEntry {
    /// Tolerant decoding: everything but the kind has a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, default: UUID())
        kind = try c.value(.kind, default: Kind.unknown)
        startedAt = try c.value(.startedAt, default: Date.now)
        resumes = try c.value(.resumes, default: 0)
        botID = (try? c.decodeIfPresent(UUID.self, forKey: .botID)) ?? nil
        chatID = (try? c.decodeIfPresent(UUID.self, forKey: .chatID)) ?? nil
        lostJobs = try c.value(.lostJobs, default: 0)
        groupID = (try? c.decodeIfPresent(UUID.self, forKey: .groupID)) ?? nil
        runID = (try? c.decodeIfPresent(UUID.self, forKey: .runID)) ?? nil
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        envelope = (try? c.decodeIfPresent(OrbEnvelope.self, forKey: .envelope)) ?? nil
    }
}

/// The file `execucoes.json`.
struct WorkJournalFile: Codable, Equatable, Sendable {
    var entries: [WorkEntry] = []
    var lastLaunch: Date?
    /// The last run ended through the normal quit (`AppModel`'s willTerminate). False at a launch means a crash or a kill.
    var cleanQuit = true
    /// The launches that found the previous run had not quit cleanly, newest last (only the recent ones are kept).
    var recentCrashLaunches: [Date] = []
}

extension WorkJournalFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.lossyArray(.entries)
        lastLaunch = (try? c.decodeIfPresent(Date.self, forKey: .lastLaunch)) ?? nil
        cleanQuit = try c.value(.cleanQuit, default: true)
        recentCrashLaunches = try c.lossyArray(.recentCrashLaunches)
    }
}

extension Store {
    static let workJournalFileName = "execucoes.json"
    private var workJournalURL: URL { directory.appendingPathComponent(Self.workJournalFileName) }

    func readWorkJournal() -> StoreRead<WorkJournalFile> {
        Self.gate.reading(workJournalURL) { read(WorkJournalFile.self, from: workJournalURL, ifUnreadable: "o registro de trabalho em andamento começou vazio") }
    }

    func saveWorkJournal(_ file: WorkJournalFile) {
        enqueue(touching: [workJournalURL]) { write(file, to: workJournalURL) }
    }
}

/// What the app was doing when it closed, so the next launch goes on with it. An entry is added when a piece of work begins and
/// removed when it ends, fails or the person stops it (Parar); quitting leaves them all (`freeze`), and that is what resumes.
/// Written only on those events, through the store's writer queue (atomic). The entries of the previous run wait in `inherited`
/// until `beginLaunch` decides what to do with them, so the work of this run cannot erase them by accident.
@MainActor
final class WorkJournal {
    /// Two launches after a crash within this long are a loop: nothing is resumed.
    static let crashWindow: TimeInterval = 10 * 60

    private let store: Store
    private var live: [WorkEntry] = []
    private(set) var inherited: [WorkEntry]
    private var lastLaunch: Date?
    private var cleanQuit: Bool
    private var recentCrashLaunches: [Date]
    private(set) var launched = false
    /// Set when the app quits: the turns that end then must not erase what the next launch resumes.
    private(set) var frozen = false

    init(store: Store) {
        self.store = store
        let file = store.readWorkJournal().value ?? WorkJournalFile()
        inherited = file.entries
        lastLaunch = file.lastLaunch
        cleanQuit = file.cleanQuit
        recentCrashLaunches = file.recentCrashLaunches
    }

    var entries: [WorkEntry] { inherited + live }

    /// Whether some request between Orbs is being kept (the hub then reconciles on its changes; otherwise it need not look).
    var tracksRequests: Bool { live.contains { $0.kind == .request } }

    // MARK: Launch and quit

    /// Called once at launch, before any work of this run is recorded. Returns what to resume, already counted as resumed once
    /// and kept (it ends like any other work). Nothing comes back when the previous run crashed twice in `crashWindow` (the
    /// resumed work may be what crashes it), or for an entry that was already resumed: the "Continuar" notice stays for those.
    func beginLaunch(now: Date = .now) -> [WorkEntry] {
        guard !launched else { return [] }
        launched = true
        if lastLaunch != nil, !cleanQuit { recentCrashLaunches.append(now) }
        recentCrashLaunches = recentCrashLaunches.filter { now.timeIntervalSince($0) < Self.crashWindow }
        let loop = recentCrashLaunches.count >= 2
        lastLaunch = now
        cleanQuit = false
        let previous = inherited
        inherited = []
        var resumed: [WorkEntry] = []
        if !loop {
            for var entry in previous where entry.kind != .unknown && entry.resumes < 1 {
                entry.resumes += 1
                resumed.append(entry)
            }
        }
        live += resumed
        persist()
        return resumed
    }

    /// The normal quit: the next launch knows this run ended on purpose.
    func markCleanQuit() {
        guard launched else { return }
        cleanQuit = true
        persist()
    }

    /// The app is quitting: from now on nothing is removed. `lostJobs`: how many background processes each Orb had running (they
    /// are killed with the app), noted on its task.
    func freeze(lostJobs: [UUID: Int] = [:]) {
        guard !frozen else { return }
        frozen = true
        for index in live.indices where live[index].kind == .chatTask {
            if let bot = live[index].botID, let count = lostJobs[bot] { live[index].lostJobs = count }
        }
        persist()
    }

    // MARK: An Orb's own chat

    /// A turn of the Orb's own conversation begins. A turn that continues work resumed after a close keeps its entry (and its count).
    func chatTaskBegan(bot: UUID, chat: UUID, at date: Date = .now) {
        guard !frozen, !live.contains(where: { $0.kind == .chatTask && $0.botID == bot && $0.chatID == chat }) else { return }
        live.append(WorkEntry(kind: .chatTask, startedAt: date, botID: bot, chatID: chat))
        persist()
    }

    /// The turn ended, failed or was stopped. Without `chat`, any of the Orb's.
    func chatTaskEnded(bot: UUID, chat: UUID? = nil) {
        remove { $0.kind == .chatTask && $0.botID == bot && (chat == nil || $0.chatID == chat) }
    }

    // MARK: Groups

    /// The group runs open now (called whenever the hub's runs change). A group has one open run: the entry follows it, keeping its
    /// count when a resumed run takes the place of the interrupted one.
    func syncGroupRuns(_ open: [GroupRun]) {
        guard !frozen else { return }
        var changed = false
        for run in open {
            let text = run.request.clipped(to: 2_000)
            if let index = live.firstIndex(where: { $0.kind == .groupRun && $0.groupID == run.groupID }) {
                guard live[index].runID != run.id else { continue }
                live[index].runID = run.id
                live[index].text = text
                live[index].startedAt = run.startedAt
                changed = true
            } else {
                live.append(WorkEntry(kind: .groupRun, startedAt: run.startedAt, groupID: run.groupID, runID: run.id, text: text))
                changed = true
            }
        }
        let groups = Set(open.map(\.groupID))
        let before = live.count
        live.removeAll { $0.kind == .groupRun && !groups.contains($0.groupID ?? UUID()) }
        if changed || live.count != before { persist() }
    }

    func dropGroupRun(_ groupID: UUID) {
        remove { $0.kind == .groupRun && $0.groupID == groupID }
    }

    // MARK: Requests between Orbs

    /// An Orb asked another (outside any group). Nested requests (made while serving another request or a routine) are not kept:
    /// whoever asked is redone from the start, and asks again.
    func requestBegan(_ envelope: OrbEnvelope, at date: Date = .now) {
        guard !frozen, envelope.kind == .ask, envelope.groupID == nil, envelope.servingRequest == nil, envelope.servingRoutine == nil,
              !live.contains(where: { $0.kind == .request && $0.envelope?.id == envelope.id }) else { return }
        live.append(WorkEntry(kind: .request, startedAt: date, envelope: envelope))
        persist()
    }

    /// The requests still open (called whenever the hub's requests change): the others are over.
    func syncRequests(open: Set<UUID>) {
        remove { $0.kind == .request && !open.contains($0.envelope?.id ?? UUID()) }
    }

    func dropRequest(_ id: UUID) {
        remove { $0.kind == .request && $0.envelope?.id == id }
    }

    // MARK: The pulse

    /// An Orb's pulse run begins. Kept so a close does not lose track of it; the next launch drops it (`dropPulse`).
    func pulseBegan(bot: UUID, at date: Date = .now) {
        guard !frozen, !live.contains(where: { $0.kind == .pulse && $0.botID == bot }) else { return }
        live.append(WorkEntry(kind: .pulse, startedAt: date, botID: bot))
        persist()
    }

    func dropPulse(bot: UUID) {
        remove { $0.kind == .pulse && $0.botID == bot }
    }

    // MARK: Writing

    private func remove(where matches: (WorkEntry) -> Bool) {
        guard !frozen else { return }
        let before = live.count
        live.removeAll(where: matches)
        if live.count != before { persist() }
    }

    private func persist() {
        store.saveWorkJournal(WorkJournalFile(entries: inherited + live, lastLaunch: lastLaunch, cleanQuit: cleanQuit,
                                              recentCrashLaunches: recentCrashLaunches))
    }
}
