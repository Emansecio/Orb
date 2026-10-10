import Foundation

/// The @mentions in a message to a group: "@Pesquisador", "@pesquisador" or "@pesq" (a start that fits one member only) call
/// that member directly, without passing through the orchestrator; "@todos" calls every member. Accents and case do not matter.
/// A start that fits two members, a name nobody has and an "@" inside a word (an e-mail) call no one.
enum Mentions {
    /// Words that call every member (unless a member is named so).
    static let everyone: Set<String> = ["todos", "todas", "todo", "all", "everyone", "grupo"]

    /// The members the text calls, in the order they are first mentioned ("@todos": the group's order). Empty when no one is.
    static func parse(_ text: String, members: [OrbRef]) -> [UUID] {
        let chars = Array(text).map(fold)
        let keys = members.map { (id: $0.id, key: Array($0.name.trimmingCharacters(in: .whitespaces)).map(fold)) }
        var called: [UUID] = []
        var index = 0
        func add(_ id: UUID) { if !called.contains(id) { called.append(id) } }
        while index < chars.count {
            guard chars[index] == "@", index == 0 || !isWordCharacter(chars[index - 1]) else { index += 1; continue }
            let start = index + 1
            // The longest full name that fits ("@Maria Clara"), ending where a word ends.
            var best: (id: UUID, length: Int)?
            for member in keys where !member.key.isEmpty {
                let end = start + member.key.count
                guard end <= chars.count, Array(chars[start..<end]) == member.key,
                      end == chars.count || !isWordCharacter(chars[end]) else { continue }
                if best == nil || member.key.count > best!.length { best = (member.id, member.key.count) }
            }
            if let best {
                add(best.id)
                index = start + best.length
                continue
            }
            var end = start
            while end < chars.count, isWordCharacter(chars[end]) { end += 1 }
            let word = String(chars[start..<end])
            index = max(end, start)
            guard !word.isEmpty else { continue }
            if everyone.contains(word) {
                members.forEach { add($0.id) }
                continue
            }
            // A first name ("@Maria" for "Maria Clara") or the start of a name, when exactly one member fits.
            let fits = keys.filter { String($0.key).hasPrefix(word) }
            if fits.count == 1 { add(fits[0].id) }
        }
        return called
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }

    /// One character, lower case and without accent ("é" is "e"); anything that folds to more than one keeps its first.
    private static func fold(_ c: Character) -> Character {
        String(c).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().first ?? c
    }
}
