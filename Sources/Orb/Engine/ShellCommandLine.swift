import Foundation

/// A shell command line split into the simple commands it runs. Not a shell: it only knows enough (quotes,
/// `; && || | &` and newlines, `$( )`, backticks, redirections) to tell which words are commands and which are
/// arguments, so the permission checks look at what runs instead of at any text that happens to appear.
struct ShellCommandLine: Equatable, Sendable {
    enum Separator: Equatable, Sendable {
        case start, sequence, and, or, pipe, background
    }

    struct Segment: Equatable, Sendable {
        /// Words with quotes and escapes removed. Substitutions stay in the word as written (`$(…)`).
        var words: [String]
        /// What joined this command to the previous one.
        var separator: Separator
        /// A `$( )`, backtick, `<( )` or zsh `=( )` somewhere in this command.
        var hasSubstitution = false
        /// Writes through a redirection (`>`, `>>`) or reads a heredoc; `2>&1` and `>/dev/null` do not count.
        var redirects = false
    }

    var segments: [Segment]
    /// The text inside every `$( )`, backtick pair, `<( )` and `=( )`, each one a command line of its own.
    var substitutions: [String]
    /// False when a quote or substitution was never closed.
    var isComplete: Bool

    /// Every command is a plain list of words: nothing to expand or redirect that the words would not show.
    var isPlain: Bool {
        isComplete && substitutions.isEmpty && !segments.contains { $0.hasSubstitution || $0.redirects }
    }

    static func parse(_ text: String) -> ShellCommandLine {
        var parser = Parser(Array(text))
        parser.run()
        return ShellCommandLine(segments: parser.segments, substitutions: parser.substitutions, isComplete: parser.isComplete)
    }

    // MARK: Parser

    private struct Parser {
        let chars: [Character]
        var index = 0
        var segments: [Segment] = []
        var substitutions: [String] = []
        var isComplete = true

        private var words: [String] = []
        private var word = ""
        private var inWord = false
        private var separator = Separator.start
        private var hasSubstitution = false
        private var redirects = false

        init(_ chars: [Character]) { self.chars = chars }

        private func peek(_ offset: Int = 1) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }

        private mutating func add(_ character: Character) {
            word.append(character)
            inWord = true
        }

        private mutating func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }

        private mutating func endSegment(next: Separator) {
            endWord()
            if !words.isEmpty {
                segments.append(Segment(words: words, separator: separator, hasSubstitution: hasSubstitution, redirects: redirects))
            }
            words = []
            hasSubstitution = false
            redirects = false
            separator = next
        }

        mutating func run() {
            while index < chars.count {
                let c = chars[index]
                if c.isNewline { endSegment(next: .sequence); index += 1; continue }
                switch c {
                case "\\":
                    if let next = peek() {
                        // A backslash before a newline joins the lines.
                        if !next.isNewline { add(next) }
                        index += 2
                    } else {
                        add(c)
                        index += 1
                    }
                case "'":
                    singleQuoted()
                case "\"":
                    doubleQuoted()
                case "$" where peek() == "(" && peek(2) != "(":
                    substitution(opening: 2, closing: ")")
                case "`":
                    backticks()
                case "<" where peek() == "(", ">" where peek() == "(", "=" where peek() == "(" && !inWord:
                    substitution(opening: 2, closing: ")")
                case " ", "\t":
                    endWord()
                    index += 1
                case ";":
                    endSegment(next: .sequence)
                    index += 1
                case "&":
                    if peek() == "&" {
                        endSegment(next: .and)
                        index += 2
                    } else if word.hasSuffix(">") || peek() == ">" {
                        // `2>&1` and `&>file` are redirections, not a background marker.
                        add(c)
                        index += 1
                    } else {
                        endSegment(next: .background)
                        index += 1
                    }
                case "|":
                    if peek() == "|" {
                        endSegment(next: .or)
                        index += 2
                    } else {
                        endSegment(next: .pipe)
                        index += peek() == "&" ? 2 : 1
                    }
                case ">":
                    redirectOutput()
                case "<":
                    if peek() == "<" {
                        redirects = true // a heredoc: its body would read as commands
                        add(c)
                        add(c)
                        index += 2
                    } else {
                        redirectInput()
                    }
                case "#" where !inWord:
                    while index < chars.count, !chars[index].isNewline { index += 1 }
                default:
                    add(c)
                    index += 1
                }
            }
            endSegment(next: .start)
        }

        private mutating func singleQuoted() {
            inWord = true
            index += 1
            while index < chars.count, chars[index] != "'" {
                word.append(chars[index])
                index += 1
            }
            if index < chars.count { index += 1 } else { isComplete = false }
        }

        private mutating func doubleQuoted() {
            inWord = true
            index += 1
            while index < chars.count, chars[index] != "\"" {
                let c = chars[index]
                if c == "\\", let next = peek() {
                    if "$`\"\\".contains(next) { word.append(next) } else if !next.isNewline { word.append(c); word.append(next) }
                    index += 2
                } else if c == "$", peek() == "(", peek(2) != "(" {
                    substitution(opening: 2, closing: ")")
                } else if c == "`" {
                    backticks()
                } else {
                    word.append(c)
                    index += 1
                }
            }
            if index < chars.count { index += 1 } else { isComplete = false }
        }

        /// `$(…)`, `<(…)` or `>(…)` starting at `index`: the whole text stays in the word, the body is recorded.
        private mutating func substitution(opening: Int, closing: Character) {
            hasSubstitution = true
            inWord = true
            let start = index + opening
            var depth = 1
            var cursor = start
            while cursor < chars.count {
                let c = chars[cursor]
                if c == "\\" { cursor += 2; continue }
                if c == "'" || c == "\"" {
                    cursor += 1
                    while cursor < chars.count, chars[cursor] != c {
                        if c == "\"", chars[cursor] == "\\" { cursor += 1 }
                        cursor += 1
                    }
                } else if c == "(" {
                    depth += 1
                } else if c == closing {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor += 1
            }
            let end = min(cursor, chars.count)
            substitutions.append(String(chars[start..<end]))
            if cursor >= chars.count { isComplete = false }
            let stop = min(cursor + 1, chars.count)
            word.append(contentsOf: chars[index..<stop])
            index = stop
        }

        private mutating func backticks() {
            hasSubstitution = true
            inWord = true
            let start = index + 1
            var cursor = start
            while cursor < chars.count, chars[cursor] != "`" {
                cursor += chars[cursor] == "\\" ? 2 : 1
            }
            let end = min(cursor, chars.count)
            substitutions.append(String(chars[start..<end]))
            if cursor >= chars.count { isComplete = false }
            let stop = min(cursor + 1, chars.count)
            word.append(contentsOf: chars[index..<stop])
            index = stop
        }

        /// An unquoted `<` that is not a heredoc or `<( )`: `< file`, `<file`, `0<file`, `3<> file`, `<&3`. The operator becomes a
        /// word of its own (`<`, `<>` or `<&`, the target following as the next word), so a file read this way is judged like
        /// any other path and no word hides it behind a descriptor number (`0<~/.netrc`). A descriptor number stuck to the
        /// operator belongs to it and is dropped from the words.
        private mutating func redirectInput() {
            if inWord, !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isNumber }) {
                word = ""
                inWord = false
            }
            endWord()
            var operatorWord = "<"
            if let next = peek(), next == ">" || next == "&" { operatorWord.append(next) }
            words.append(operatorWord)
            index += operatorWord.count
        }

        /// `>` and `>>`: writing to a file counts as a redirect, duplicating a descriptor (`2>&1`) and
        /// discarding output (`>/dev/null`) do not.
        private mutating func redirectOutput() {
            var cursor = index + 1
            if cursor < chars.count, chars[cursor] == ">" { cursor += 1 }
            var target = cursor
            while target < chars.count, chars[target] == " " || chars[target] == "\t" { target += 1 }
            let rest = String(chars[target...].prefix(10))
            let duplicates = rest.hasPrefix("&") && rest.dropFirst().first.map { $0.isNumber || $0 == "-" } == true
            let discards = rest.hasPrefix("/dev/null") && (rest.count == 9 || " \t;&|\n)".contains(rest[rest.index(rest.startIndex, offsetBy: 9)]))
            if !duplicates && !discards { redirects = true }
            for position in index..<cursor { add(chars[position]) }
            index = cursor
        }
    }
}
