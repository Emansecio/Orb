import Foundation
@testable import Orb

/// An in-memory `PreferenceStore`, so a test never touches the real defaults.
final class FakePreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
