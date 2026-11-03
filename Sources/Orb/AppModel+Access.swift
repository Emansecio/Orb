import Foundation

/// `request_access`: what the app knows for the Orb's request, what "Liberar" turns on, and the turn that follows it.
extension AppModel {
    /// What `request_access` needs for `bot`, and how to apply what the person allows.
    func accessSupport(for bot: Bot) -> AccessSupport {
        let botID = bot.id
        return AccessSupport(capabilities: bot.capabilities, mode: bot.permissionMode, folder: bot.workingDirectory, home: homeFolder,
                             grant: { [weak self] request in
                                 guard let self else { return .failed("O app está fechando.") }
                                 return await self.grantAccess(request, to: botID)
                             })
    }

    /// "Liberar": the switches, the mode and the folder go through `update`, as they do from the panel (a change of mode also reaches
    /// the turn that is running). "Automático" never lowers a mode that asks for less care, and nothing here reaches "Sem pedir
    /// permissão". The turn that asked cannot see the new tools, so when it ends the Orb is asked to go on (`resumeAfterAccess`).
    func grantAccess(_ request: AccessRequest, to botID: UUID) -> AccessOutcome {
        guard bot(botID) != nil else { return .failed("The Orb that asked no longer exists.") }
        // The card may have waited long: the folder is checked again, as it was when the tool accepted it.
        if !request.folder.isEmpty {
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: request.folder)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  PermissionPolicy.ownFolder(url, home: homeFolder) != nil else {
                return .failed("The user accepted, but \(request.folder) is not a usable folder anymore. Nothing was changed.")
            }
        }
        update(botID) { bot in
            bot.capabilities.formUnion(request.capabilities)
            if request.autoMode, bot.permissionMode == .ask || bot.permissionMode == .readOnly { bot.permissionMode = .auto }
            if !request.folder.isEmpty { bot.workingDirectory = request.folder }
        }
        sessions[botID]?.accessGranted = true
        return .granted(summary: request.items.joined(separator: ", "))
    }

    /// The turn that asked for access ended after it was granted: the Orb goes on by itself, once per accepted card, unless the
    /// person is writing to it. Same road as a finished background process (`showJobs`). `chat` is the conversation of the turn.
    func resumeAfterAccess(of botID: UUID, in chat: UUID) {
        guard let session = sessions[botID], session.turnTask == nil, isOwnChat(botID), drafts[botID, default: ""].isEmpty else { return }
        Task {
            guard await prepareTurn(in: chat, of: botID) else { return }
            if !send(NoticeAction.continueMessage(after: ""), to: botID), session.turnTask == nil {
                session.endWorkElsewhere() // nothing began: the one on show takes the turn machinery back
            }
        }
    }
}
