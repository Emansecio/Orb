import SwiftUI

/// What deleting an Orb takes with it and what stays, in words. Pure, so the copy is tested.
struct DeleteOrbSummary: Equatable {
    var name: String
    var routineCount: Int
    /// The Orb's own working folder as shown to the user ("~/Orbs/Atlas"); nil when it works in the home folder.
    var folder: String?
    /// The groups it belongs to: it leaves them (MultiOrb).
    var groupCount: Int = 0
    /// The names of the groups it is one of the two Orbs of: those are undone, with their conversation and board.
    var undoneGroups: [String] = []

    /// "A conversa, 2 rotinas e a participação em 2 grupos vão embora."
    var goes: String {
        var parts = ["a conversa"]
        if routineCount == 1 { parts.append("1 rotina") } else if routineCount > 1 { parts.append("\(routineCount) rotinas") }
        // MARK: MultiOrb (WP6): it also leaves the groups it is in ("também sai de N grupos").
        // The groups it undoes get their own line (`undone`); here only the ones that go on without it.
        let left = groupCount - undoneGroups.count
        if left == 1 { parts.append("a participação em 1 grupo") } else if left > 1 { parts.append("a participação em \(left) grupos") }
        let subject = Self.list(parts)
        return subject.prefix(1).uppercased() + subject.dropFirst() + (parts.count == 1 ? " vai embora." : " vão embora.")
    }

    /// "O grupo Lançamento fica com 1 Orb e é desfeito, com a conversa e o quadro."; nil when no group is undone.
    var undone: String? {
        guard !undoneGroups.isEmpty else { return nil }
        if undoneGroups.count == 1 { return "O grupo \(undoneGroups[0]) fica com 1 Orb e é desfeito, com a conversa e o quadro." }
        return "Os grupos \(Self.list(undoneGroups)) ficam com 1 Orb e são desfeitos, com a conversa e o quadro de cada um."
    }

    /// "A pasta ~/Orbs/Atlas continua no seu Mac e, se você quiser, a memória também."
    var stays: String {
        if let folder { return "A pasta \(folder) continua no seu Mac e, se você quiser, a memória também." }
        return "Tudo o que está no seu Mac continua lá e, se você quiser, a memória também."
    }

    /// Where a kept memory goes and what each button does with it.
    static let memoryNote = "Guardada, a memória vai para Memórias guardadas (Ajustes → Geral), e um Orb novo pode começar dela. Apagada, não volta."

    /// "3 Orbs", "1 Orb"; nil for none (so a sentence leaves it out).
    static func counted(_ count: Int, _ one: String, _ many: String) -> String? {
        switch count {
        case ...0: nil
        case 1: "1 \(one)"
        default: "\(count) \(many)"
        }
    }

    /// "a, b e c".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " e " + parts[parts.count - 1]
        }
    }
}

extension DeleteOrbSummary {
    @MainActor
    init(bot: Bot, routineCount: Int, groups: [OrbGroup] = [], home: String = NSHomeDirectory()) {
        let shown = bot.workingDirectory.isEmpty ? nil : OrbFolder.display(bot.workingURL, home: home)
        let joined = groups.filter { $0.memberIDs.contains(bot.id) }
        // The same rule as leaving a group (`AppModel.leave`): at the smallest size the group is undone.
        let undone = joined.filter { $0.memberIDs.count <= OrbGroup.memberLimits.lowerBound }.map(\.name)
        self.init(name: bot.name, routineCount: routineCount, folder: shown == "~" ? nil : shown,
                  groupCount: joined.count, undoneGroups: undone)
    }
}

/// A line of what a destructive sheet takes away or leaves: a red minus (what goes) or a green check (what stays) and the
/// sentence. "Apagar Atlas?" and "Redefinir o Orb?" use it.
struct SummaryLine: View {
    enum Kind {
        case goes, stays

        var symbol: String { self == .goes ? "minus.circle.fill" : "checkmark.circle.fill" }
        var color: Color { self == .goes ? Palette.danger : Palette.ok }
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(Typography.text)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                // A count that arrives later, an option that changes the sentence.
                .contentTransition(.opacity)
        }
        .motion(Motion.content, value: text)
    }
}

/// The one "Apagar Atlas?" sheet, opened from the sidebar's menu and from the inspector. The first button is the
/// safe one: it keeps the memory.
struct DeleteOrbSheet: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        if let bot = model.bot(botID) {
            let summary = DeleteOrbSummary(bot: bot, routineCount: model.routines(for: botID).count, groups: model.groups)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SummaryLine(.goes, summary.goes)
                    if let undone = summary.undone { SummaryLine(.goes, undone) }
                    SummaryLine(.stays, summary.stays)
                    Text(DeleteOrbSummary.memoryNote)
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Spacing.sheetEdge)
                .padding(.bottom, Spacing.l)
            }
            .orbSheet("Apagar \(bot.name)?", size: .medium) {
                SheetFooter(destructiveTitle: "Apagar tudo, inclusive a memória",
                            destructive: { model.confirmDelete(botID, keepMemory: false) },
                            cancel: { model.deletingBotID = nil },
                            primaryTitle: "Apagar, guardando a memória",
                            primaryIsDefault: false, // deleting is never what a reflex Return does; Esc still cancels
                            primaryIsDestructive: true, // the Orb goes either way: red, not the white of "do this"
                            destructiveHelp: Tip.deleteWithMemory, primaryHelp: Tip.deleteKeepingMemory,
                            primary: { model.confirmDelete(botID, keepMemory: true) })
            }
            // As tall as what it says (three lines and the buttons), not the sheets' usual height with a gap under them.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Memória de Atlas guardada · Mostrar no Finder": a strip at the top of the sidebar that goes away by itself.
struct KeptMemoryBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.keptMemoryNotice {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message)
                            .font(Typography.label.weight(.medium))
                            .foregroundStyle(Palette.ink)
                        // Not before the memory has moved: the folder it goes to does not exist until then.
                        Button("Mostrar no Finder") { model.revealKeptMemory(notice) }
                            .buttonStyle(.link)
                            .help(Tip.keptMemoryInFinder)
                            .font(Typography.label)
                            .disabled(!notice.isKept)
                    }
                    Spacer(minLength: 4)
                    Button("Fechar", systemImage: "xmark") { model.dismissKeptMemoryNotice() }
                        .labelStyle(.iconOnly)
                        // 20 pt target (the 10 pt glyph alone was ~10 pt).
                        .buttonStyle(CircleGhostStyle(side: 20, fontSize: 10))
                        .fontWeight(.semibold)
                        .help(Tip.dismissNotice)
                        .foregroundStyle(Palette.muted)
                }
                .padding(10)
                .card(radius: Radius.medium, stroke: Palette.lineStrong)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.adapted(.arrive, reduceMotion: reduceMotion))
                .accessibilityElement(children: .contain)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(12))
                    if model.keptMemoryNotice?.id == notice.id { model.dismissKeptMemoryNotice() }
                }
            }
        }
        // The strip rises 6 pt in `Motion.enter` and leaves by fading in `Motion.exit` (`arrive`); a 0.15 s fade under Reduce Motion.
        .motion(Motion.enter, value: model.keptMemoryNotice)
    }
}
