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
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1_024)
        try append(value, to: &bytes, trailing: trailing)
        return Data(bytes)
    }

    /// Encodes a Responses API request body and builds its `CacheProbe` fingerprint from the exact encoded bytes in one pass.
    static func encodeWithResponsesFingerprint(_ body: JSONValue, trailing: [String] = []) throws -> (data: Data, fingerprint: JSONValue) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4_096)
        guard case .object(let object) = body else {
            try append(body, to: &bytes)
            return (Data(bytes), CacheProbe.fingerprint(of: body))
        }
        let tail = trailing.filter { object[$0] != nil }
        let lead = object.keys.filter { !tail.contains($0) }.sorted()
        var instrSeg: [JSONValue] = [.number(0), .string(CacheProbe.hashBytes([]))]
        var toolsSeg: [JSONValue]?
        var toolsCount = 0
        var itemSegs: [JSONValue] = []

        bytes.append(0x7B) // {
        for (index, key) in (lead + tail).enumerated() {
            if index > 0 { bytes.append(0x2C) } // ,
            appendString(key, to: &bytes)
            bytes.append(0x3A) // :
            let value = object[key] ?? .null
            if key == "instructions" {
                let start = bytes.count
                try append(value, to: &bytes)
                let slice = bytes[start..<bytes.count]
                instrSeg = [.number(Double(slice.count)), .string(CacheProbe.hashBytes(slice))]
            } else if key == "tools" {
                let start = bytes.count
                try append(value, to: &bytes)
                let slice = bytes[start..<bytes.count]
                toolsCount = value.array?.count ?? 0
                toolsSeg = [.number(Double(toolsCount)), .number(Double(slice.count)), .string(CacheProbe.hashBytes(slice))]
            } else if key == "input", case .array(let items) = value {
                itemSegs.reserveCapacity(items.count)
                bytes.append(0x5B) // [
                for (i, item) in items.enumerated() {
                    if i > 0 { bytes.append(0x2C) }
                    let start = bytes.count
                    try append(item, to: &bytes)
                    let slice = bytes[start..<bytes.count]
                    let tag = item["type"]?.string ?? item["role"]?.string ?? "?"
                    itemSegs.append(.array([.string(tag), .number(Double(slice.count)), .string(CacheProbe.hashBytes(slice))]))
                    if toolsSeg == nil, item["type"]?.string == "additional_tools", let extraTools = item["tools"] {
                        let encodedTools = try encode(extraTools)
                        toolsCount = extraTools.array?.count ?? 0
                        toolsSeg = [.number(Double(toolsCount)), .number(Double(encodedTools.count)),
                                    .string(CacheProbe.hashBytes(encodedTools))]
                    }
                }
                bytes.append(0x5D) // ]
            } else {
                try append(value, to: &bytes)
            }
        }
        bytes.append(0x7D) // }
        let finalTools = toolsSeg ?? [.number(0), .number(0), .string(CacheProbe.hashBytes([]))]
        let fp = JSONValue.object([
            "instr": .array(instrSeg),
            "tools": .array(finalTools),
            "items": .array(itemSegs),
        ])
        return (Data(bytes), fp)
    }

    private static func append(_ value: JSONValue, to out: inout [UInt8], trailing: [String] = []) throws {
        switch value {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C]) // null
        case .bool(let b):
            out.append(contentsOf: b ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .number(let n):
            guard n.isFinite else {
                throw EncodingError.invalidValue(n, .init(codingPath: [], debugDescription: "Non-finite number in JSON"))
            }
            if n == 0 {
                out.append(0x30) // 0 (avoid "-0")
            } else if n.rounded(.towardZero) == n, n >= -9_007_199_254_740_992, n <= 9_007_199_254_740_992 {
                out.append(contentsOf: String(Int64(n)).utf8)
            } else {
                out.append(contentsOf: String(n).utf8)
            }
        case .string(let s):
            appendString(s, to: &out)
        case .array(let items):
            out.append(0x5B) // [
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x2C) }
                try append(item, to: &out)
            }
            out.append(0x5D) // ]
        case .object(let dict):
            out.append(0x7B) // {
            let keys: [String]
            if trailing.isEmpty {
                keys = dict.keys.sorted()
            } else {
                let tail = trailing.filter { dict[$0] != nil }
                keys = dict.keys.filter { !tail.contains($0) }.sorted() + tail
            }
            for (i, key) in keys.enumerated() {
                if i > 0 { out.append(0x2C) }
                appendString(key, to: &out)
                out.append(0x3A) // :
                try append(dict[key] ?? .null, to: &out)
            }
            out.append(0x7D) // }
        }
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    private static func appendString(_ string: String, to out: inout [UInt8]) {
        out.append(0x22) // "
        var copy = string
        copy.withUTF8 { buffer in
            var runStart = 0
            for index in 0..<buffer.count {
                let b = buffer[index]
                if b >= 0x20 && b != 0x22 && b != 0x5C { continue }
                if index > runStart {
                    out.append(contentsOf: buffer[runStart..<index])
                }
                switch b {
                case 0x22: out.append(contentsOf: [0x5C, 0x22]) // \"
                case 0x5C: out.append(contentsOf: [0x5C, 0x5C]) // \\
                case 0x08: out.append(contentsOf: [0x5C, 0x62]) // \b
                case 0x0C: out.append(contentsOf: [0x5C, 0x66]) // \f
                case 0x0A: out.append(contentsOf: [0x5C, 0x6E]) // \n
                case 0x0D: out.append(contentsOf: [0x5C, 0x72]) // \r
                case 0x09: out.append(contentsOf: [0x5C, 0x74]) // \t
                default:
                    out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0x0F)]])
                }
                runStart = index + 1
            }
            if runStart < buffer.count {
                out.append(contentsOf: buffer[runStart..<buffer.count])
            }
        }
        out.append(0x22) // "
    }
}
