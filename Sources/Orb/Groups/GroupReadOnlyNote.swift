import Foundation

/// What a group says about its members in Só leitura (`PermissionMode.readOnly`): such an Orb cannot use `orbs` ask or tell, so
/// as orchestrator it hands out nothing, and as a member it asks no one and changes no file. The group's panel and "Novo grupo"
/// show these lines; nothing is blocked (the person may want a reader in the group).
enum GroupReadOnlyNote {
    struct Line: Equatable, Sendable {
        var text: String
        /// The orchestrator is the one in Só leitura: the panel offers to choose another.
        var isOrchestrator: Bool
    }

    /// The orchestrator's line first, then one line for the members.
    static func lines(members: [UUID], orchestrator: UUID?, name: (UUID) -> String, isReadOnly: (UUID) -> Bool) -> [Line] {
        var lines: [Line] = []
        if let orchestrator, members.contains(orchestrator), isReadOnly(orchestrator) {
            lines.append(Line(text: "\(name(orchestrator)) está em Só leitura: como orquestrador, não consegue distribuir o trabalho.",
                              isOrchestrator: true))
        }
        let readers = members.filter { $0 != orchestrator && isReadOnly($0) }.map(name)
        if !readers.isEmpty {
            let one = readers.count == 1
            lines.append(Line(text: "\(PortugueseList.join(readers)) \(one ? "está" : "estão") em Só leitura: não \(one ? "pede" : "pedem") "
                                  + "nada aos colegas nem \(one ? "altera" : "alteram") arquivos.",
                              isOrchestrator: false))
        }
        return lines
    }
}

extension AppModel {
    /// The Só leitura lines of a group (or of the Orbs chosen for a new one).
    func readOnlyNotes(members: [UUID], orchestrator: UUID?) -> [GroupReadOnlyNote.Line] {
        GroupReadOnlyNote.lines(members: members, orchestrator: orchestrator, name: { self.bot($0)?.name ?? "Orb" },
                                isReadOnly: { self.bot($0)?.permissionMode == .readOnly })
    }
}
