import SwiftUI

/// `--snapshot sidebar-categories`: Orbs sorted in two categories, one open and one folded with a message waiting.
/// `-hidden` puts the open Orb in the folded one (its heading carries the selection); `-naming` has the field open for a
/// new category, under an empty one; `-dragging` holds "Gestor de Campanha" up between the two first rows of "AcessosFit":
/// "Gestor LP" has moved down to open the gap, and the place it left is closed.
@MainActor
enum SidebarCategorySnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen.hasPrefix("sidebar-categories") else { return nil }
        let loose = Bot(name: "Dr eggbot", role: "Designs high-quality Grok Bots", orb: OrbConfig(color: "cereja", eyes: "pilulas", mouth: "sorriso"))
        let landing = Bot(name: "Gestor LP AcessosFit", role: "Mantém a landing page", orb: WelcomeLooks.lia)
        let support = Bot(name: "Atendente AcessosFit", role: "Atende clientes no WhatsApp", orb: OrbConfig(color: "ceu", eyes: "ovais", mouth: "sorriso"))
        let campaign = Bot(name: "Gestor de Campanha", role: "Revisa a campanha", orb: OrbConfig(color: "lavanda", eyes: "pontos", mouth: "sorriso"))
        let research = Bot(name: "Pesquisador", role: "Pesquisa na web", orb: WelcomeLooks.bento)
        let review = Bot(name: "Revisor", role: "Revisa textos", orb: OrbConfig(color: "grafite", eyes: "pilulas", brows: "retas", accessories: ["fones"]))
        model.bots = [loose, landing, support, campaign, research, review]
        model.categories = [
            SidebarCategory(name: "AcessosFit", botIDs: [support.id, landing.id, campaign.id]),
            SidebarCategory(name: "Pesquisa", botIDs: [research.id, review.id], isCollapsed: true),
        ]
        model.live(review.id).setUnread(2)
        model.selection = .bot(screen == "sidebar-categories-hidden" ? research.id : support.id)
        if screen == "sidebar-categories-naming" {
            model.categories.append(SidebarCategory(name: "Ideias"))
            model.categoryNaming = .new(moving: nil)
        }
        if screen == "sidebar-categories-dragging" { model.draggedBotID = campaign.id }
        return AnyView(SidebarView(previewDropY: screen == "sidebar-categories-dragging" ? 140 : nil).frame(width: 280))
    }
}
