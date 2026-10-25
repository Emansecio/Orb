#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

/// `--snapshot` modes of an Orb's conversations (`OrbChats`), with made-up data in the snapshot's own folder:
/// - `chats-sidebar`: the open Orb with five conversations (the newest three, the one on show among them, "2 conversas mais antigas",
///   "Nova conversa"); the Orb ends a turn in "Ajustar texto do anúncio Wellhub", left for "Análise da campanha 21/10",
///   and something landed unseen in "Orçamento de novembro".
/// - `chats-collapsed`: the same sidebar with the conversations folded under the Orb's row (the chevron beside its name).
/// - `chats-elsewhere`: that conversation's chat: the strip above the field, and a message typed that will wait.
/// - `chats-new`: a new, empty conversation of an Orb that has others.
@MainActor
enum ChatsSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen.hasPrefix("chats-"), let orb = model.bots.first else { return nil }
        let id = orb.id, session = model.session(id)
        var chats = OrbChats(first: id, updated: .now.addingTimeInterval(-9 * 86_400))
        var made: [UUID] = []
        for (title, age) in [("Configurar conversões do WhatsApp", 5.0 * 86_400), ("Orçamento de novembro", 2 * 86_400),
                             ("Ajustar texto do anúncio Wellhub", 3600), ("Análise da campanha 21/10", 60)] {
            let chat = UUID()
            chats.add(chat, at: .now.addingTimeInterval(-age))
            chats.rename(chat, to: title)
            made.append(chat)
        }
        model.selection = .bot(id)
        session.isUnloaded = false
        switch screen {
        case "chats-new":
            chats.add(UUID(), at: .now)
            session.chatID = chats.active
            session.conversation = Conversation()
            model.setChats(chats, for: id)
            return AnyView(ChatView(botID: id))
        default:
            // The Orb ends a turn in the conversation you left: it is `conversation`, the one on show is parked.
            session.chatID = made[3]
            session.workingChatID = made[2]
            session.conversation = conversation([("Reescreva o anúncio da Wellhub com foco em academia perto de casa",
                                                  "Vou abrir o texto atual e o relatório de cliques.")])
            session.parkedChat = conversation([("Analise mais detalhada da campanha de ontem 21",
                                               "Gympass gerou 34 dos 54 cliques. Os anúncios do mesmo dia vêm a seguir.")])
            session.turnTask = Task { try? await Task.sleep(for: .seconds(3600)) } // what makes a message wait (`canQueue`)
            model.setStatus("Pensando", of: id)
            chats.markUnread(made[1])
            if screen == "chats-collapsed" { chats.collapsed = true }
            model.setChats(chats, for: id)
            if screen == "chats-elsewhere" {
                model.setDraft("E o orçamento de novembro?", for: id)
                return AnyView(ChatView(botID: id))
            }
            return AnyView(SidebarView().frame(width: 280))
        }
    }

    private static func conversation(_ turns: [(String, String)]) -> Conversation {
        var conversation = Conversation()
        for (asked, said) in turns {
            conversation.items += [TranscriptItem(.user(text: asked, attachments: [])), TranscriptItem(.bot(text: said, isStreaming: false))]
        }
        return conversation
    }
}
#endif
