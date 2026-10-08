import SwiftUI

/// What deleting an Orb takes with it and what stays, in words. Pure, so the copy is tested.
struct DeleteOrbSummary: Equatable {
    var name: String
    /// Earlier conversations of the Orb; nil until the list has been read.
    var archivedCount: Int?
    var routineCount: Int
    /// The Orb's own working folder as shown to the user ("~/Orbs/Atlas"); nil when it works in the home folder.
    var folder: String?

    init(name: String, archivedCount: Int?, routineCount: Int, folder: String?) {
        self.name = name
        self.archivedCount = archivedCount
        self.routineCount = routineCount
        self.folder = folder
    }

    @MainActor
    init(bot: Bot, archivedCount: Int?, routineCount: Int, home: String = NSHomeDirectory()) {
        let shown = bot.workingDirectory.isEmpty ? nil : OrbFolder.display(bot.workingURL, home: home)
        self.init(name: bot.name, archivedCount: archivedCount, routineCount: routineCount, folder: shown == "~" ? nil : shown)
    }

    /// "Some: a conversa, as 12 conversas arquivadas e as 2 rotinas."
    var goes: String {
        var parts = ["a conversa atual"]
        switch archivedCount {
        case nil: parts.append("as conversas arquivadas")
        case 0?: break
        case 1?: parts.append("1 conversa arquivada")
        case let count?: parts.append("\(count) conversas arquivadas")
        }
        if routineCount == 1 { parts.append("1 rotina") } else if routineCount > 1 { parts.append("\(routineCount) rotinas") }
        return "Some: " + Self.list(parts) + "."
    }

    /// "Fica: a pasta ~/Orbs/Atlas e, se você quiser, a memória."
    var stays: String {
        if let folder { return "Fica: a pasta \(folder) e, se você quiser, a memória." }
        return "Fica: tudo o que está no seu Mac e, se você quiser, a memória."
    }

    /// Where a kept memory goes and what each button does with it.
    static let memoryNote = "Guardada, a memória fica em memoria/_guardadas na pasta de dados do app, e você pode abrir no Finder logo depois. Apagada, não volta."

    /// "a, b e c".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " e " + parts[parts.count - 1]
        }
    }
}

/// The one "Apagar Atlas?" sheet, opened from the sidebar's menu and from the inspector. The first button is the
/// safe one: it keeps the memory.
struct DeleteOrbSheet: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var archivedCount: Int?

    var body: some View {
        if let bot = model.bot(botID) {
            let summary = DeleteOrbSummary(bot: bot, archivedCount: archivedCount, routineCount: model.routines(for: botID).count)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    line("minus.circle.fill", Palette.danger, summary.goes)
                    line("checkmark.circle.fill", Palette.ok, summary.stays)
                    Text(DeleteOrbSummary.memoryNote)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .orbSheet("Apagar \(bot.name)?", size: .medium) {
                SheetFooter(destructiveTitle: "Apagar com a memória",
                            destructive: { model.confirmDelete(botID, keepMemory: false) },
                            cancel: { model.deletingBotID = nil },
                            primaryTitle: "Apagar e guardar a memória",
                            primaryIsDefault: false, // deleting is never what a reflex Return does; Esc still cancels
                            primary: { model.confirmDelete(botID, keepMemory: true) })
            }
            .task {
                await model.loadArchive(botID)
                archivedCount = model.archives[botID]?.count ?? 0
            }
        }
    }

    private func line(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        // Not before the memory has moved: the folder it goes to does not exist until then.
                        Button("Mostrar no Finder") { model.revealKeptMemory(notice) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            .disabled(!notice.isKept)
                    }
                    Spacer(minLength: 4)
                    Button("Fechar", systemImage: "xmark") { model.dismissKeptMemoryNotice() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(10)
                .card(radius: 10, stroke: Palette.lineStrong)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(12))
                    if model.keptMemoryNotice?.id == notice.id { model.dismissKeptMemoryNotice() }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.keptMemoryNotice)
    }
}
