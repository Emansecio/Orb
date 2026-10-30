#if DEBUG || ORB_DEV_TOOLS
import SwiftUI

@MainActor enum InicioSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen == "inicio" || screen.hasPrefix("inicio-") else { return nil }
        if screen == "inicio-empty" {
            model.bots = []
            model.routines = []
            model.selection = .inicio
            return AnyView(InicioView())
        }
        let support = Bot(name: "Atendente", role: "Atendimento", orb: OrbConfig(color: "ceu", eyes: "pilulas", mouth: "sorriso"))
        let campaign = Bot(name: "Campanhas", role: "Análise de campanha", orb: OrbConfig(color: "indigo", eyes: "ovais", mouth: "sorriso"))
        let site = Bot(name: "Página", role: "Conteúdo", orb: OrbConfig(color: "menta", eyes: "pilulas", mouth: "sorriso"))
        model.bots = [support, campaign, site]
        var routine = Routine(name: "Atendimento diário", botID: support.id, prompt: "Acompanhe os retornos", schedule: .everyHours(1))
        routine.followUps = [RoutineFollowUp(subject: "Ana", channel: "E-mail", nextStep: "Verificar resposta à proposta")]
        let run = RoutineRun(date: .now.addingTimeInterval(-3600), finishedAt: .now.addingTimeInterval(-3500), succeeded: true,
                             summary: "Duas respostas recebidas; um acompanhamento continua em aberto.")
        routine.runs = [run]
        model.routines = [routine]
        model.inicio = InicioHistory()
        model.recordInicioRoutine(bot: support.id, routine: routine.id, run: run, outcome: .completed)
        let answer = TranscriptItem(.bot(text: "Relatório da campanha atualizado.", isStreaming: false))
        model.session(campaign.id).ensureLoaded()
        model.seedConversation(Conversation(items: [answer]), for: campaign.id)
        model.recordInicioChat(bot: campaign.id, chat: campaign.id, item: answer.id, date: .now.addingTimeInterval(-1800),
                               text: "Relatório da campanha atualizado.", succeeded: true)
        if screen == "inicio-attention" {
            let check = GoalCheck(progress: 35, status: .attention, note: "Aguardando resposta")
            let flagged = RoutineRun(date: .now.addingTimeInterval(-300), succeeded: false, summary: "Não foi possível atualizar o relatório.", check: check)
            routine.goal = RoutineGoal(target: "Acompanhar os retornos", check: check)
            routine.runs.insert(flagged, at: 0)
            model.routines = [routine]
            model.recordInicioRoutine(bot: support.id, routine: routine.id, run: flagged, outcome: .attention)
        }
        if screen == "inicio-working" { model.setStatus("Consultando mensagens", of: support.id) }
        if screen == "inicio-many" || screen == "inicio-long" {
            for index in 0..<12 {
                model.recordInicioChat(bot: site.id, chat: site.id, item: UUID(), date: .now.addingTimeInterval(Double(-index * 60)),
                                       text: screen == "inicio-long" ? String(repeating: "Atualização com descrição mais extensa. ", count: 8) : "Atualização \(index + 1) concluída.", succeeded: true)
            }
        }
        model.selection = .inicio
        if screen == "inicio-interactive" {
            for index in 0..<12 {
                model.recordInicioChat(bot: site.id, chat: site.id, item: UUID(), date: .now,
                                       text: "Atualização fictícia \(index + 1)", succeeded: true)
            }
            return AnyView(ZStack(alignment: .bottomTrailing) {
                RootView()
                HStack {
                    Button("Simular trabalho") {
                        model.setStatus(model.live(support.id).isWorking ? nil : "Consultando mensagens", of: support.id)
                    }
                    Button("Simular resultado") {
                        model.recordInicioChat(bot: site.id, chat: site.id, item: UUID(), date: .now,
                                               text: "Resultado novo da prévia", succeeded: true)
                    }
                }.buttonStyle(PrimaryPillStyle()).padding()
            })
        }
        if screen == "inicio-sidebar" {
            return AnyView(HStack(spacing: 0) {
                SidebarView().frame(width: Snapshot.paneWidth(280))
                InicioView()
            })
        }
        if screen == "inicio-reduced-motion" {
            return AnyView(InicioView(reduceMotionOverride: true))
        }
        return AnyView(InicioView())
    }
}
#endif
