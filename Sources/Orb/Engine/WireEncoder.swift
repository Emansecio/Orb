import Foundation

/// Encodes the body of a model request. The bytes depend only on the content: a Swift dictionary has a different key
/// order in every instance, and providers cache a prompt by its rendered prefix (Anthropic's `cache_control`,
/// OpenAI's automatic cache, gateways in between), so one reordered key in a tool schema or in the `input` of an old
/// `tool_use` makes the whole prefix after it a miss. Sorting the keys makes two requests that say the same thing
/// byte-identical.
///
/// `trailing` names top-level keys that go last, in that order: the conversation (which grows by appending) after
/// everything that stays the same from one step to the next, so that a request is, byte for byte, the start of the
/// request one step later. Providers render their prompts in their own order whatever the JSON order is; this serves
/// the gateways and caches that hash the body as it comes.
enum WireEncoder {
    static func encode(_ value: JSONValue, trailing: [String] = []) throws -> Data {
        guard !trailing.isEmpty, case .object(let object) = value else { return try plain(value) }
        let tail = trailing.filter { object[$0] != nil }
        let lead = object.keys.filter { !tail.contains($0) }.sorted()
        var data = Data("{".utf8)
        for (index, key) in (lead + tail).enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(try plain(.string(key)))
            data.append(UInt8(ascii: ":"))
            data.append(try plain(object[key] ?? .null))
        }
        data.append(UInt8(ascii: "}"))
        return data
    }

    private static func plain(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
