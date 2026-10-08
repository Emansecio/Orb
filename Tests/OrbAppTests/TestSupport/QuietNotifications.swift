import Foundation
import os

/// Keeps the test process from posting banners (`notifyWhenDone` off) while any test holds it.
///
/// The setting lives in `UserDefaults.standard`, which every test shares. Tests that each saved the old value and
/// put it back would overwrite one another when they overlap and leave the wrong value behind; here the first
/// holder saves it and the last one to let go restores it.
enum QuietNotifications {
    private static let key = "notifyWhenDone"
    private static let state = OSAllocatedUnfairLock(initialState: (holders: 0, saved: Bool?.none))

    static func hold() {
        state.withLock { state in
            if state.holders == 0 {
                state.saved = UserDefaults.standard.object(forKey: key) as? Bool
                UserDefaults.standard.set(false, forKey: key)
            }
            state.holders += 1
        }
    }

    static func release() {
        state.withLock { state in
            state.holders -= 1
            guard state.holders == 0 else { return }
            if let saved = state.saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            state.saved = nil
        }
    }
}
