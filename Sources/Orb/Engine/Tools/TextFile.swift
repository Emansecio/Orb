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
    /// UTF-8 files with a few stray bytes (a character cut at the end of a log, a pasted fragment) are read as UTF-8
    /// with these bytes shown as U+FFFD; writing `text` back would lose them.
    var invalidUTF8Bytes = 0
    /// `text` holds those stray bytes as private-use stand-ins (`escapeRange`), which `encoded` turns back into the bytes.
    var escapesInvalidBytes = false

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
        // Mostly UTF-8 with a few bad bytes: reading all of it as Windows-1252 would turn every accent into two characters.
        let profile = utf8Profile(data)
        if profile.multibyte >= 3, profile.invalid * 3 <= profile.multibyte, profile.invalid <= 3 || profile.invalid * 10 <= profile.multibyte {
            let text = String(decoding: data, as: UTF8.self)
            return TextFile(text: text, encoding: .utf8, hasBOM: false, lineEnding: lineEnding(of: text), invalidUTF8Bytes: profile.invalid)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return TextFile(text: text, encoding: .windowsCP1252, hasBOM: false, lineEnding: lineEnding(of: text))
        }
        // Windows-1252 leaves five bytes undefined; Latin-1 maps every byte.
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        return TextFile(text: text, encoding: .isoLatin1, hasBOM: false, lineEnding: lineEnding(of: text), isLatin1Fallback: true)
    }

    /// How many valid multi-byte UTF-8 sequences `data` holds, and how many bytes belong to none (a truncated or stray one).
    static func utf8Profile(_ data: Data) -> (multibyte: Int, invalid: Int) {
        var multibyte = 0
        var invalid = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let length = sequenceLength(bytes, at: index)
                if length == 0 { invalid += 1; index += 1 } else { if length > 1 { multibyte += 1 }; index += length }
            }
        }
        return (multibyte, invalid)
    }

    /// Length of the valid UTF-8 sequence that starts at `index` (1 for ASCII), or 0 when the byte belongs to none.
    private static func sequenceLength(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        func isContinuation(_ at: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool { at < bytes.count && range.contains(bytes[at]) }
        switch bytes[index] {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return isContinuation(index + 1) ? 2 : 0
        case 0xE0: return isContinuation(index + 1, 0xA0...0xBF) && isContinuation(index + 2) ? 3 : 0
        case 0xE1...0xEC, 0xEE...0xEF: return isContinuation(index + 1) && isContinuation(index + 2) ? 3 : 0
        case 0xED: return isContinuation(index + 1, 0x80...0x9F) && isContinuation(index + 2) ? 3 : 0
        case 0xF0: return isContinuation(index + 1, 0x90...0xBF) && isContinuation(index + 2) && isContinuation(index + 3) ? 4 : 0
        case 0xF1...0xF3: return isContinuation(index + 1) && isContinuation(index + 2) && isContinuation(index + 3) ? 4 : 0
        case 0xF4: return isContinuation(index + 1, 0x80...0x8F) && isContinuation(index + 2) && isContinuation(index + 3) ? 4 : 0
        default: return 0
        }
    }

    /// Stand-ins for bytes that are not UTF-8 (0x80–0xFF), in the private-use area, like Python's `surrogateescape`.
    static let escapeRange: ClosedRange<UInt32> = 0xF780...0xF7FF

    static func containsEscapes(_ text: String) -> Bool { text.unicodeScalars.contains { escapeRange.contains($0.value) } }

    /// `data` as UTF-8 where every stray byte becomes its stand-in, so that an edit elsewhere writes the file back byte for byte.
    /// Nil if the file already uses those private-use characters (the stand-ins could not be told from them).
    static func decodeEscapingInvalidUTF8(_ data: Data) -> String? {
        var scalars = String.UnicodeScalarView()
        var clash = false
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            var runStart = 0
            func flush(to end: Int) {
                guard end > runStart else { return }
                let run = String(decoding: UnsafeBufferPointer(rebasing: bytes[runStart..<end]), as: UTF8.self)
                if containsEscapes(run) { clash = true }
                scalars.append(contentsOf: run.unicodeScalars)
            }
            while index < bytes.count {
                let length = sequenceLength(bytes, at: index)
                if length > 0 { index += length; continue }
                flush(to: index)
                scalars.append(Unicode.Scalar(0xF700 + UInt32(bytes[index]))!)
                index += 1
                runStart = index
            }
            flush(to: bytes.count)
        }
        return clash ? nil : String(scalars)
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
        if escapesInvalidBytes {
            for scalar in newText.unicodeScalars {
                if scalar.value < 0x80 { data.append(UInt8(scalar.value)) }
                else if Self.escapeRange.contains(scalar.value) { data.append(UInt8(scalar.value - 0xF700)) }
                else { data.append(contentsOf: UTF8.encode(scalar)!) }
            }
            return data
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

/// Turns the errors the file system gives into messages the model can act on: in Portuguese, with the full path, and for
/// a refused access with what to tell the user (the macOS protected folders are the usual cause on a Mac).
enum FileAccess {
    /// Runs `body`; a permission or read-only failure becomes a `ToolError` that names `url`, any other error passes through.
    static func translating<T>(_ url: URL, writing: Bool, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ToolError {
            throw error
        } catch {
            if let denied = denial(error, path: url.path, writing: writing) { throw denied }
            throw error
        }
    }

    static func denial(_ error: Error, path: String, writing: Bool) -> ToolError? {
        guard let kind = refusal(error) else { return nil }
        switch kind {
        case .readOnlyVolume:
            return ToolError("\(path) está num volume somente leitura; não dá para gravar ali.")
        case .noPermission:
            let action = writing ? "gravar em" : "ler"
            return ToolError("Sem permissão para \(action) \(path). Se for Mesa, Documentos, Downloads ou outra pasta protegida, o macOS pode "
                + "estar bloqueando o Orb: peça para a pessoa permitir em Ajustes do Sistema → Privacidade e Segurança → Arquivos e "
                + "Pastas (ou Acesso Total ao Disco). Não tente contornar com sudo ou outro caminho.")
        }
    }

    private enum Refusal { case noPermission, readOnlyVolume }

    private static func refusal(_ error: Error) -> Refusal? {
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let nsError = current else { return nil }
            if nsError.domain == NSCocoaErrorDomain {
                switch nsError.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .noPermission
                case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume
                default: break
                }
            }
            if nsError.domain == NSPOSIXErrorDomain {
                switch Int32(nsError.code) {
                case EACCES, EPERM: return .noPermission
                case EROFS: return .readOnlyVolume
                default: break
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}

/// Writes through symbolic links, keeping the permissions (executable bit) of the file being replaced.
enum FileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingLinkChain
        let manager = FileManager.default
        try FileAccess.translating(target, writing: true) {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Replacing a file atomically swaps it by name and so ignores that it is read-only; the owner set that bit on
            // purpose (or a tool did), so writing over it needs the owner to lift it first.
            if manager.fileExists(atPath: target.path), !manager.isWritableFile(atPath: target.path) {
                throw ToolError("\(target.path) está protegido contra escrita (somente leitura). Se é para mudá-lo mesmo, libere antes "
                    + "(chmod u+w) ou grave em outro arquivo.")
            }
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
}
