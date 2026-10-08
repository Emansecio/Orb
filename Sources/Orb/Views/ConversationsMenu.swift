import SwiftUI

/// Toolbar button of the chat: the Orb's earlier conversations, to reopen or delete.
struct ConversationsMenuButton: View {
    let botID: UUID
    @State private var isOpen = false

    var body: some View {
        Button("Conversas", systemImage: "clock.arrow.circlepath") { isOpen.toggle() }
            .help("Conversas anteriores deste Orb")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                ConversationsMenu(botID: botID) { isOpen = false }
            }
    }
}

/// Archived conversations of one Orb, newest first. "Nova conversa" puts the current one here.
struct ConversationsMenu: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let onClose: () -> Void

    @State private var query = ""
    @State private var isLoading = true
    /// The conversation whose "Apagar" was clicked and is waiting for the confirmation.
    @State private var confirmingDelete: UUID?

    /// A search field is worth its space past this many conversations.
    static let searchThreshold = 8

    private var all: [ConversationSummary] { model.archives[botID] ?? [] }

    private var shown: [ConversationSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversas anteriores")
                .font(.system(size: 13, weight: .semibold))
            if all.count > Self.searchThreshold {
                TextField("Buscar", text: $query, prompt: Text("Buscar nas conversas"))
                    .textFieldStyle(.roundedBorder)
            }
            if shown.isEmpty {
                Text(isLoading ? "Carregando…" : all.isEmpty
                     ? "Nada por aqui ainda. Ao começar uma nova conversa, a atual fica guardada aqui."
                     : "Nenhuma conversa com “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { entry in
                            ConversationRow(entry: entry, isConfirming: confirmingDelete == entry.id,
                                            onReopen: {
                                                if model.reopenConversation(entry.id, of: botID) { onClose() }
                                            },
                                            onAskDelete: { confirmingDelete = entry.id },
                                            onCancelDelete: { confirmingDelete = nil },
                                            onDelete: {
                                                model.deleteArchivedConversation(entry.id, of: botID)
                                                confirmingDelete = nil
                                            })
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 360)
        .task {
            await model.loadArchive(botID)
            isLoading = false
        }
    }
}

private struct ConversationRow: View {
    let entry: ConversationSummary
    let isConfirming: Bool
    let onReopen: () -> Void
    let onAskDelete: () -> Void
    let onCancelDelete: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                if !isConfirming {
                    Button("Reabrir", action: onReopen)
                        .controlSize(.small)
                    Button("Apagar", systemImage: "trash", action: onAskDelete)
                        .labelStyle(.iconOnly)
                        .controlSize(.small)
                        .help("Apagar esta conversa")
                }
            }
            if isConfirming {
                HStack {
                    Text("Apagar de vez? Não dá para desfazer.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                    Spacer()
                    Button("Cancelar", action: onCancelDelete)
                    Button("Apagar", role: .destructive, action: onDelete)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovering || isConfirming ? Palette.ghostHover : .clear, in: .rect(cornerRadius: 8))
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        let count = entry.messageCount
        return "\(Self.relative(entry.updatedAt)) · \(count) \(count == 1 ? "mensagem" : "mensagens")"
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static func relative(_ date: Date) -> String { formatter.localizedString(for: date, relativeTo: .now) }
}
