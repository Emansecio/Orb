import Darwin
import Foundation
import Security

// This executable stays signed and unchanged across Orb builds. Only an Orb signed by the same certificate may use it:
// otherwise any local process could use its Keychain authorization to read the person's credentials.
private func signingInformation(_ code: SecCode) -> (identifier: String, certificate: Data)? {
    guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
          let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { return nil }
    return (identifier, SecCertificateCopyData(leaf) as Data)
}

private func isAuthorizedParent() -> Bool {
    var parent: SecCode?, own: SecCode?
    let attributes = [kSecGuestAttributePid as String: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent,
          SecCodeCopySelf([], &own) == errSecSuccess, let own,
          let caller = signingInformation(parent), let helper = signingInformation(own) else { return false }
    return caller.identifier == "app.orb.mac" && caller.certificate == helper.certificate
}

private struct BatchItem: Decodable {
    let service: String
    let account: String
}
private struct Request: Decodable {
    let operation: String
    let service: String?
    let account: String?
    let value: String?
    let items: [BatchItem]?
}
private struct Reply: Encodable {
    let ok: Bool
    var value: String?
    var values: [String: String]?
}

private func readOne(service: String, account: String) -> String? {
    guard ["app.orb.mac", "app.openbot.mac"].contains(service), !account.isEmpty else { return nil }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func perform(_ request: Request) -> Reply {
    if request.operation == "batchRead" {
        guard let items = request.items else { return Reply(ok: false) }
        var found: [String: String] = [:]
        for item in items {
            if let value = readOne(service: item.service, account: item.account) {
                found["\(item.service)\n\(item.account)"] = value
            }
        }
        return Reply(ok: true, values: found)
    }
    guard let service = request.service, let account = request.account,
          ["app.orb.mac", "app.openbot.mac"].contains(service), !account.isEmpty else { return Reply(ok: false) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
    switch request.operation {
    case "read":
        guard let value = readOne(service: service, account: account) else { return Reply(ok: false) }
        return Reply(ok: true, value: value)
    case "replace":
        guard let value = request.value else { return Reply(ok: false) }
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return Reply(ok: status == errSecSuccess || status == errSecItemNotFound)
        }
        let data = Data(value.utf8)
        let update = { SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        var status = update()
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = update() }
        }
        return Reply(ok: status == errSecSuccess)
    default: return Reply(ok: false)
    }
}

guard isAuthorizedParent(), let request = try? JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile()),
      let response = try? JSONEncoder().encode(perform(request)) else { exit(1) }
FileHandle.standardOutput.write(response)
