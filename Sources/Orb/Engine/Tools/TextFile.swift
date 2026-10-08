import Foundation

/// A text file decoded with the encoding it was saved in, remembering enough to write it back the same way
/// (encoding, byte-order mark, dominant line ending) so editing never rewrites a file's format.
struct TextFile: Sendable {
    enum LineEnding: Sendable { case lf, crlf }

    var text: String
    var encoding: String.Encoding
    var hasBOM: Bool
    var lineEnding: LineEnding
    /// Latin-1 fallback for bytes Windows-1252 leaves undefined.
    var isLatin1Fallback = false

    var encodingName: String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        default: isLatin1Fallback ? "ISO-8859-1" : "Windows-1252"
        }
    }

    // MARK: Decoding

    /// Strict UTF-8 first, then byte-order marks (UTF-16/32), UTF-16 without a mark, and finally Windows-1252
    /// (which is what most non-UTF-8 text on a Mac or Windows machine is). Nil for binary data.
    static func decode(_ data: Data) -> TextFile? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return TextFile(text: text, encoding: .utf8, hasBOM: true, lineEnding: lineEnding(of: text))
        }
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]), let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) {
            return TextFile(text: text, encoding: .utf32LittleEndian, hasBOM: true, lineEnding: lineEnding(of: text))
        }
        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]), let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian) {
            return TextFile(text: text, encoding: .utf32BigEndian, hasBOM: true, lineEnding: lineEnding(of: text))
        }
        if head.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return TextFile(text: text, encoding: .utf16LittleEndian, hasBOM: true, lineEnding: lineEnding(of: text))
        }
        if head.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return TextFile(text: text, encoding: .utf16BigEndian, hasBOM: true, lineEnding: lineEnding(of: text))
        }

        if data.prefix(8192).contains(0) {
            guard let encoding = guessUTF16WithoutMark(data.prefix(8192)),
                  let text = String(data: data, encoding: encoding), looksLikeText(text) else { return nil }
            return TextFile(text: text, encoding: encoding, hasBOM: false, lineEnding: lineEnding(of: text))
        }
        if let text = String(data: data, encoding: .utf8) {
            return TextFile(text: text, encoding: .utf8, hasBOM: false, lineEnding: lineEnding(of: text))
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return TextFile(text: text, encoding: .windowsCP1252, hasBOM: false, lineEnding: lineEnding(of: text))
        }
        // Windows-1252 leaves five bytes undefined; Latin-1 maps every byte.
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        return TextFile(text: text, encoding: .isoLatin1, hasBOM: false, lineEnding: lineEnding(of: text), isLatin1Fallback: true)
    }

    /// ASCII-heavy UTF-16 has a zero in every other byte; which side the zeros fall on gives the byte order.
    private static func guessUTF16WithoutMark(_ head: Data) -> String.Encoding? {
        let bytes = [UInt8](head)
        guard bytes.count >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = bytes.count / 2
        if oddZeros * 10 > pairs * 3, evenZeros * 20 < pairs { return .utf16LittleEndian }
        if evenZeros * 10 > pairs * 3, oddZeros * 20 < pairs { return .utf16BigEndian }
        return nil
    }

    /// Binary data can pass the zero-byte pattern of UTF-16; real text has hardly any control characters.
    private static func looksLikeText(_ text: String) -> Bool {
        var controls = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.value == 0xFFFD || (scalar.value < 0x20 && ![9, 10, 12, 13].contains(scalar.value)) { controls += 1 }
        }
        return total > 0 && controls * 50 <= total
    }

    /// CRLF when it is the majority ending, so a Windows file stays a Windows file.
    private static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 10 {
                if previous == 13 { crlf += 1 } else { lf += 1 }
            }
            previous = byte
        }
        return crlf > lf ? .crlf : .lf
    }

    // MARK: Encoding

    /// Bytes for `newText` in this file's encoding, with the byte-order mark it had.
    func encoded(_ newText: String) throws -> Data {
        var data = Data()
        if hasBOM {
            switch encoding {
            case .utf8: data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: data.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: data.append(contentsOf: [0xFE, 0xFF])
            case .utf32LittleEndian: data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
            case .utf32BigEndian: data.append(contentsOf: [0x00, 0x00, 0xFE, 0xFF])
            default: break
            }
        }
        guard let body = newText.data(using: encoding) else {
            throw ToolError("O arquivo está em \(encodingName) e o novo texto tem caracteres que essa codificação não suporta.")
        }
        data.append(body)
        return data
    }

    // MARK: Lines

    /// Lines split on "\n" only (Unicode line/paragraph separators and form feeds are ordinary characters in
    /// source files), with a trailing "\r" dropped and the final empty piece after a closing newline omitted.
    static func lines(of text: String) -> [String] {
        var lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { slice -> String in
            String(decoding: slice.last == 13 ? slice.dropLast() : slice, as: UTF8.self)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// Writes through symbolic links, keeping the permissions (executable bit) of the file being replaced.
enum FileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingLinkChain
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            // Atomic replacement needs a writable folder; a writable file in a read-only one can still be updated.
            guard manager.isWritableFile(atPath: target.path) else { throw error }
            try data.write(to: target)
        }
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }
}
