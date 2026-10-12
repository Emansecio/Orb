import Foundation
import Security

/// Whether the app that runs is still the one on disk. A build or update that replaces the bundle while the app is open
/// leaves it running code macOS can no longer check, and the Keychain then refuses it the items it keeps.
enum RunningCode {
    static var wasReplaced: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) != errSecSuccess
    }
}
