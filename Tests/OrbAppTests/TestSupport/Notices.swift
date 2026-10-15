import Foundation
@testable import Orb

/// The notices (the grey lines a turn tells the user) in a turn's events, a transcript, or an Orb's chat.
extension Sequence where Element == TurnEvent {
    var notices: [String] {
        compactMap { if case .notice(let text) = $0 { text } else { nil } }
    }
}

extension Sequence where Element == TranscriptItem {
    var notices: [String] {
        compactMap { if case .notice(let text) = $0.kind { text } else { nil } }
    }
}

extension AppModel {
    func notices(_ botID: UUID) -> [String] { transcript(botID).notices }
}
