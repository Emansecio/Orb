import AppKit
import Foundation
import UserNotifications

/// Approval cards that reach the user where they are: a banner with "Permitir" and "Não permitir" when the Orb
/// asks while the user is elsewhere, and the routing of what they tap. What to say and what a tap means are pure
/// functions (tested without a notification center); the rest talks to `UNUserNotificationCenter`, which only
/// exists in a bundled app.
enum ApprovalNotifications {
    static let category = "orb.approval"
    /// The same actions, but "Permitir" asks for the Mac to be unlocked: for destructive requests.
    static let dangerousCategory = "orb.approval.dangerous"
    /// The Orb opened its browser for the person to finish something (`browse_show`): the same two actions, as "Pronto"
    /// and "Cancelar".
    static let handoffCategory = "orb.approval.handoff"
    static let allowAction = "orb.approval.allow"
    static let denyAction = "orb.approval.deny"
    /// A banner about a turn that may be going wrong by itself (in circles, on for hours): its one button stops the turn.
    static let stopCategory = "orb.turn.stop"
    static let stopAction = "orb.turn.stop.action"
    static let stopTitle = "Parar"
    static let botKey = "botID"
    static let approvalKey = "approvalID"
    /// A banner shows a few lines; the full command is on the card.
    static let bodyLimit = 160

    /// `UNUserNotificationCenter` needs a real app bundle; `swift run` and tests have none and would crash.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    // MARK: What to say

    struct Payload: Equatable, Sendable {
        /// The approval's id, so the banner can be taken down when the card is answered in the app.
        var identifier: String
        var title: String
        var body: String
        /// Banners of one Orb stack together.
        var threadID: String
        var category: String
        var userInfo: [String: String]
    }

    /// The buttons of a hand-off banner.
    static let handoffDoneTitle = "Pronto"
    static let handoffCancelTitle = "Cancelar"

    static func payload(botName: String, botID: UUID, request: ApprovalRequest) -> Payload {
        Payload(identifier: request.id.uuidString, title: botName, body: body(for: request), threadID: botID.uuidString,
                category: request.isProposal || request.isQuestion ? "" : request.isHandoff ? handoffCategory : request.isDangerous ? dangerousCategory : category, // a creation card or a question has no quick answer: a tap opens the card
                userInfo: [botKey: botID.uuidString, approvalKey: request.id.uuidString])
    }

    /// The card's title and what it would do, on one line and cut to `bodyLimit`.
    static func body(for request: ApprovalRequest) -> String {
        let detail = request.isBatch
            ? request.items.map { $0.command.isEmpty ? $0.title : "\($0.title) \($0.command)" }.joined(separator: "; ")
            : request.command
        let text = oneLine(detail.isEmpty ? request.title : "\(request.title): \(detail)")
        guard text.count > bodyLimit else { return text }
        return text.prefix(bodyLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Only when the user is not already looking at the card: the app is in the background, or another Orb is open.
    static func shouldPost(appIsActive: Bool, selectedBotID: UUID?, botID: UUID, enabled: Bool) -> Bool {
        enabled && (!appIsActive || selectedBotID != botID)
    }

    // MARK: What a tap means

    enum Route: Equatable, Sendable {
        case decide(ApprovalDecision, botID: UUID, approvalID: UUID)
        /// A plain click: show the Orb it came from (nil: any other banner of the app, just bring the app forward).
        case open(botID: UUID?)
        /// A group's banner (its pause, its end): show the group.
        case openGroup(UUID)
        /// "Parar" on a banner about a turn (`stopCategory`): stop the Orb's turn, as ⌘. would.
        case stop(botID: UUID)
        case ignore
    }

    /// The key a group's banner carries its group under.
    static let groupKey = "groupID"

    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Route {
        let botID = (userInfo[botKey] as? String).flatMap(UUID.init(uuidString:))
        let approvalID = (userInfo[approvalKey] as? String).flatMap(UUID.init(uuidString:))
        let groupID = (userInfo[groupKey] as? String).flatMap(UUID.init(uuidString:))
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            if let groupID { return .openGroup(groupID) }
            return .open(botID: botID)
        case allowAction, denyAction:
            guard let botID, let approvalID else { return .ignore }
            return .decide(actionIdentifier == allowAction ? .once : .deny, botID: botID, approvalID: approvalID)
        case stopAction:
            guard let botID else { return .ignore }
            return .stop(botID: botID)
        default:
            return .ignore
        }
    }

    // MARK: Notification center

    static func categories() -> Set<UNNotificationCategory> {
        func make(_ identifier: String, requiresUnlock: Bool, allowTitle: String = "Permitir", denyTitle: String = "Não permitir") -> UNNotificationCategory {
            let allow = UNNotificationAction(identifier: allowAction, title: allowTitle,
                                             options: requiresUnlock ? [.authenticationRequired] : [])
            let deny = UNNotificationAction(identifier: denyAction, title: denyTitle, options: [])
            return UNNotificationCategory(identifier: identifier, actions: [allow, deny], intentIdentifiers: [], options: [])
        }
        let stop = UNNotificationCategory(identifier: stopCategory,
                                          actions: [UNNotificationAction(identifier: stopAction, title: stopTitle, options: [])],
                                          intentIdentifiers: [], options: [])
        return [make(category, requiresUnlock: false), make(dangerousCategory, requiresUnlock: true),
                make(handoffCategory, requiresUnlock: false, allowTitle: handoffDoneTitle, denyTitle: handoffCancelTitle), stop]
    }

    static func content(for payload: Payload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.threadIdentifier = payload.threadID
        content.categoryIdentifier = payload.category
        content.userInfo = payload.userInfo
        content.sound = .default
        return content
    }

    /// The one delegate (it also presents the `notify` tool's banners) and the approval categories.
    @MainActor static func prepare(_ center: UNUserNotificationCenter) {
        center.delegate = NotificationPresenter.shared
        center.setNotificationCategories(categories())
    }

    /// At launch: registers the delegate so a tap on a banner reaches the app even when that tap launched it.
    @MainActor static func prepareAtLaunch() {
        guard isAvailable else { return }
        prepare(UNUserNotificationCenter.current())
    }

    /// Posts the banner. `stillPending` is asked once more right before, after the permission check that may have
    /// waited for the user, so a card answered in the meantime leaves no banner behind.
    @MainActor static func post(_ payload: Payload, stillPending: @MainActor () -> Bool) async {
        _ = await send(content(for: payload), identifier: payload.identifier, stillWanted: stillPending)
    }

    /// The one way the app posts a banner: asks for the permission when it was never asked, and adds the banner only
    /// if it is allowed and still `stillWanted`. Returns whether it was allowed (the `notify` tool tells the Orb when not).
    @MainActor @discardableResult
    static func send(_ content: UNNotificationContent, identifier: String = UUID().uuidString,
                     stillWanted: @MainActor () -> Bool = { true }) async -> Bool {
        guard isAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        prepare(center)
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return false }
        if stillWanted() { try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
        return true
    }

    /// A plain banner (title and body).
    static func plainContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return content
    }

    /// Takes down every approval banner still in the Notification Center: the ones left by a run that closed or
    /// crashed, whose buttons would answer nothing. Called when the app starts.
    static func clearStale() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.filter { staleCategories.contains($0.request.content.categoryIdentifier) }
                .map(\.request.identifier)
            if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// The banners whose buttons mean nothing once the run that posted them is gone: an approval card's, a handoff's and the
    /// "Parar" of a turn that went in circles.
    static let staleCategories = [category, dangerousCategory, handoffCategory, stopCategory]

    /// The one "Parar" banner an Orb has: a new one takes the place of the old.
    static func stopBannerID(_ botID: UUID) -> String { "stop-\(botID.uuidString)" }

    /// Takes down the "Parar" banner of an Orb whose turn is over (or never will be again): tapping it later would
    /// stop whatever turn the Orb is running by then.
    static func clearStopBanner(of botID: UUID) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [stopBannerID(botID)])
        center.removePendingNotificationRequests(withIdentifiers: [stopBannerID(botID)])
    }

    /// Takes down the banners of cards that were answered (in the app, by a mode change or by stopping the Orb).
    static func clear(_ approvalIDs: [UUID]) {
        guard isAvailable, !approvalIDs.isEmpty else { return }
        let identifiers = approvalIDs.map(\.uuidString)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: Delivering taps

    /// Taps that arrive before the app model has registered (a tap that launched the app) wait here.
    @MainActor private static var waiting: [Route] = []
    @MainActor private static var handler: (@MainActor (Route) -> Void)?

    @MainActor static func install(handler: @escaping @MainActor (Route) -> Void) {
        self.handler = handler
        let early = waiting
        waiting = []
        early.forEach(handler)
    }

    @MainActor static func deliver(_ route: Route) {
        if let handler { handler(route) } else { waiting.append(route) }
    }

    @MainActor static func bringAppToFront() {
        guard let app = NSApp else { return }
        app.activate()
        guard let window = app.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

extension NotificationPresenter {
    /// A tap on a banner or one of its buttons.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let route = ApprovalNotifications.route(actionIdentifier: response.actionIdentifier,
                                                userInfo: response.notification.request.content.userInfo)
        await MainActor.run { ApprovalNotifications.deliver(route) }
    }
}
