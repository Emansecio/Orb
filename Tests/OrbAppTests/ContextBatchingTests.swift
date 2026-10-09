import Foundation
import Testing
@testable import Orb

// Context fitting that changes in batches (low-water mark, remembered cut), fresh outputs, steps set aside as
// digest lines, condensed old stretches, and the pure parts around them (digests, reasoning size, saved notes).

// MARK: - Helpers

private func call(_ id: String, _ name: String = "read_file", _ arguments: String = "{}") -> ToolCallRequest {
    ToolCallRequest(id: id, name: name, arguments: arguments)
}

/// An assistant step with one call and its result.
private func step(_ id: String, output: Int, path: String? = nil, name: String = "read_file", isError: Bool = false,
                  filler: Character = "o") -> [ChatMessage] {
    let arguments = path.map { #"{"path":"\#($0)"}"# } ?? "{}"
    return [ChatMessage(role: .assistant, content: "", toolCalls: [call(id, name, arguments)]),
            .tool(id, String(repeating: filler, count: output), isError: isError)]
}

/// One finished turn: the request, `steps` tool rounds and a final answer.
private func turn(_ request: String, steps: Int = 1, output: Int = 100, tag: String = "t") -> [ChatMessage] {
    var messages: [ChatMessage] = [.user(request)]
    for index in 0..<steps { messages += step("\(tag)-\(index)", output: output, path: "/tmp/\(tag).txt") }
    messages.append(ChatMessage(role: .assistant, content: "Resposta de \(request)"))
    return messages
}

private func toolSizes(_ messages: [ChatMessage]) -> [Int] { messages.filter { $0.role == .tool }.map(\.content.count) }

private func prefaced(_ prompt: String, snapshot: Bool = false, notes: String = "") -> ChatMessage {
    let snap = snapshot ? WorkspaceSnapshot(path: "/Users/maria/app", entries: ["Package.swift"]) : nil
    return .user(TurnPreface.prepend(TurnPreface.make(now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: "UTC", snapshot: snap, notes: notes), to: prompt))
}

// MARK: - Low-water mark

struct LowWaterTests {
    @Test func aHistoryUnderTheBudgetIsNeverTouched() {
        let history = (0..<5).flatMap { turn("pedido \($0)", steps: 1, output: 300, tag: "u\($0)") }
        var cut = ContextCut()
        let window = ContextWindow.fit(history, budget: ContextBudget(tokens: 20_000), cut: &cut)
        #expect(window.messages == history)
        #expect(window.droppedCount == 0 && window.summary == nil)
        #expect(cut.covered == 0 && cut.summary == nil && cut.skipped == 0)
    }

    @Test func overTheBudgetTheHistoryIsBroughtDownToTheLowWaterMarkNotJustUnderTheLimit() {
        let budget = ContextBudget(tokens: 20_000)   // 70,000 characters
        let big = (0..<80).flatMap { turn("pedido \($0)", steps: 1, output: 1_500, tag: "w\($0)") }
        #expect(characters(big) > budget.characters)
        let window = ContextWindow.fit(big, budget: budget)
        #expect(window.droppedCount > 0)
        let kept = characters(window.messages)
        #expect(kept <= Int(Double(budget.characters) * budget.lowWater))
        // ...and not much lower: whole turns are folded only as far as needed to get there.
        #expect(kept > Int(Double(budget.characters) * budget.lowWater) - 2 * characters(turn("pedido 1", output: 1_500)) - ContextSummary.reserve)
        #expect(isValidConversation(window.messages))
    }

    @Test func theFitIsStableUntilTheHistoryIsOverTheBudgetAgain() throws {
        var conversation = Conversation()
        let budget = ContextBudget(tokens: 6_000)   // 21,000 characters
        var previous: [ChatMessage] = []
        var compactions = 0
        var summaries = Set<String>()
        for index in 0..<120 {
            conversation.messages += turn("pedido \(index)", steps: 1, output: 300, tag: "s\(index)")
            let history = conversation.prepareHistory(budget: budget).history
            if !extends(previous, history) { compactions += 1 }
            if let summary = conversation.summary { summaries.insert(summary) }
            previous = history
            #expect(isValidConversation(history))
        }
        // Every turn alone would have been a compaction (a rewrite of the provider's cache) with a minimal cut; the
        // low-water mark makes them rare.
        #expect(compactions <= 12, "compactions: \(compactions)")
        #expect(compactions == summaries.count)
        #expect(compactions >= 2)
    }

    @Test func betweenCompactionsTheNextRequestStartsWithTheLastOne() {
        var conversation = Conversation()
        let budget = ContextBudget(tokens: 6_000)
        var previous: [ChatMessage] = []
        var appended = 0
        for index in 0..<60 {
            conversation.messages += turn("pedido \(index)", steps: 1, output: 300, tag: "p\(index)")
            let covered = conversation.summaryCoveredCount
            let history = conversation.prepareHistory(budget: budget).history
            if conversation.summaryCoveredCount == covered, !previous.isEmpty {
                #expect(extends(previous, history), "turn \(index) changed the start of the request")
                appended += 1
            }
            previous = history
        }
        #expect(appended > 40)
    }

    @Test func aTurnThatGrowsStepByStepMovesTheCutInBatches() {
        var messages = [ChatMessage.user("pedido original")]
        let budget = ContextBudget(tokens: 6_000)   // 21,000 characters
        var cut = ContextCut()
        var previous: [ChatMessage] = []
        var changes = 0
        for index in 0..<40 {
            messages += step("g\(index)", output: 1_500, path: "/tmp/f\(index).txt")
            let window = ContextWindow.fit(messages, budget: budget, cut: &cut)
            if !extends(previous, window.messages) { changes += 1 }
            previous = window.messages
            #expect(window.messages.contains { $0.content == "pedido original" })
            #expect(isValidConversation(window.messages))
        }
        // Without memory of the cut, every step past the budget would change the start of the request.
        #expect(changes < 20, "changes: \(changes)")
        #expect(changes >= 1)
    }

    @Test func fittingWithTheSameCutTwiceGivesTheSameWindow() {
        var messages = [ChatMessage.user("pedido")]
        for index in 0..<25 { messages += step("d\(index)", output: 2_000, path: "/tmp/f\(index).txt") }
        let budget = ContextBudget(tokens: 3_000)
        var cut = ContextCut()
        let first = ContextWindow.fit(messages, budget: budget, cut: &cut)
        let snapshot = cut
        let second = ContextWindow.fit(messages, budget: budget, cut: &cut)
        #expect(first.messages == second.messages)
        #expect(cut == snapshot)
    }

    @Test func aTurnPickedUpWithAnEarlierCutCarriesItsSummaryForward() throws {
        var messages: [ChatMessage] = (0..<12).flatMap { turn("pedido \($0)", steps: 1, output: 3_000, tag: "c\($0)") }
        messages.append(.user("agora"))
        let budget = ContextBudget(tokens: 4_000)
        var cut = ContextCut()
        let first = ContextWindow.fit(messages, budget: budget, cut: &cut)
        #expect(cut.covered > 0)
        let summary = try #require(cut.summary)
        #expect(first.summary == summary)
        messages += step("n0", output: 100, path: "/tmp/n.txt")
        let second = ContextWindow.fit(messages, budget: budget, cut: &cut)
        // Nothing new was folded: the summary pair is the same, and the rest only grew.
        #expect(Array(second.messages.prefix(2)) == Array(first.messages.prefix(2)))
        #expect(extends(first.messages, second.messages))
    }
}

// MARK: - Fresh outputs

struct FreshOutputsTests {
    @Test func outputsOfATaskInProgressAreNotChangedStepAfterStep() {
        var messages = [ChatMessage.user("pedido")]
        var cut = ContextCut()
        var previous: [ChatMessage] = []
        for index in 0..<10 {
            messages += step("a\(index)", output: 10_000, path: "/tmp/f\(index).txt")
            let window = ContextWindow.fit(messages, budget: .fallback, cut: &cut)
            #expect(extends(previous, window.messages))
            #expect(toolSizes(window.messages).allSatisfy { $0 == 10_000 })
            previous = window.messages
        }
    }

    @Test func theOldestOutputsBecomePreviewsInOneGoAndThenHold() {
        var messages = [ChatMessage.user("pedido")]
        let budget = ContextBudget(tokens: 17_000)   // 59,500 characters: whole outputs may take 23,800
        var cut = ContextCut()
        var windows: [[ChatMessage]] = []
        for index in 0..<14 {
            messages += step("b\(index)", output: 10_000, path: "/tmp/f\(index).txt")
            windows.append(ContextWindow.fit(messages, budget: budget, cut: &cut).messages)
        }
        // Count the steps where an earlier message changed (the cache would start over).
        let breaks = zip(windows, windows.dropFirst()).filter { !extends($0, $1) }.count
        #expect(breaks >= 1)
        #expect(breaks <= 6, "breaks: \(breaks)")
        // Always at least the newest three whole.
        for window in windows.dropFirst(2) { #expect(toolSizes(window).suffix(3).allSatisfy { $0 == 10_000 }) }
    }

    @Test func aTaskThatCrowdsTheWindowShortensOldPreviewsBeforeTheWholeOutputs() {
        var messages = [ChatMessage.user("pedido")]
        for index in 0..<30 { messages += step("e\(index)", output: 3_900, path: "/tmp/f\(index).txt") }
        for index in 0..<3 { messages += step("w\(index)", output: 10_000, path: "/tmp/w\(index).txt") }
        // The 30 old outputs (3,900 each) plus the 3 whole ones do not fit; shortening the old ones is enough.
        let budget = ContextBudget(tokens: 30_000)   // 105,000 characters
        let window = ContextWindow.fit(messages, budget: budget)
        #expect(window.summary == nil && window.skippedSteps == 0)
        #expect(toolSizes(window.messages).suffix(3).allSatisfy { $0 == 10_000 })
        #expect(toolSizes(window.messages).dropLast(3).allSatisfy { $0 < 3_900 })
        #expect(characters(window.messages) <= budget.characters)
    }

    @Test func theNewestOutputIsNeverEmptiedWhateverTheTask() {
        var messages = [ChatMessage.user("pedido original")]
        for index in 0..<20 { messages += step("h\(index)", output: 30_000, path: "/tmp/f\(index).txt") }
        for tokens in [500, 1_500, 3_000, 10_000] {
            let window = ContextWindow.fit(messages, budget: ContextBudget(tokens: tokens))
            let newest = window.messages.last { $0.role == .tool }
            #expect((newest?.content.count ?? 0) >= 8_000, "tokens \(tokens)")
            #expect(newest?.toolCallID == "h19")
            #expect(window.messages.contains { $0.content == "pedido original" })
            #expect(isValidConversation(window.messages))
        }
    }

    @Test func aTaskThatStoppedAtTheStepLimitStaysFreshWhenPickedUp() {
        var stored = [ChatMessage.user("migre tudo")]
        for index in 0..<6 { stored += step("m\(index)", output: 8_000, path: "/tmp/f\(index).txt") }
        stored.append(ChatMessage(role: .assistant, content: "parei\n\n" + ProgressRecord.marker + "\n- ..."))
        // Without knowing the task was paused, its outputs are old at the next message.
        var asked = stored
        asked.append(.user("continua"))
        let forgotten = ContextWindow.fit(asked, budget: .fallback)
        #expect(toolSizes(forgotten.messages).allSatisfy { $0 < 5_000 })
        // Picked up: the same outputs the model just read stay whole.
        var cut = ContextCut()
        let picked = ContextWindow.fit(asked, budget: .fallback, cut: &cut, continuing: true)
        #expect(toolSizes(picked.messages).allSatisfy { $0 == 8_000 })
        // ...also in the history prepared before the new message exists.
        var conversation = Conversation()
        conversation.messages = stored
        #expect(conversation.isTaskPaused)
        let prepared = conversation.prepareHistory(budget: .fallback).history
        #expect(toolSizes(prepared).allSatisfy { $0 == 8_000 })
    }

    @Test func aPickedUpTaskIsOneTurnWithItsPredecessor() {
        // Dropping "turns" must not cut the paused task off from the message that continues it.
        var messages: [ChatMessage] = (0..<6).flatMap { turn("antigo \($0)", steps: 1, output: 2_000, tag: "o\($0)") }
        messages.append(.user("tarefa grande"))
        for index in 0..<4 { messages += step("t\(index)", output: 6_000, path: "/tmp/f\(index).txt") }
        messages.append(ChatMessage(role: .assistant, content: ProgressRecord.marker + "\n- ..."))
        messages.append(.user("continua"))
        var cut = ContextCut()
        let window = ContextWindow.fit(messages, budget: ContextBudget(tokens: 6_000), cut: &cut, continuing: true)
        #expect(window.messages.contains { $0.content == "tarefa grande" })
        #expect(window.messages.contains { $0.content == "continua" })
        #expect(isValidConversation(window.messages))
        #expect(window.droppedCount > 0)
    }
}

// MARK: - Steps set aside

struct SetAsideStepsTests {
    private func hugeTask(steps: Int, output: Int = 3_000) -> [ChatMessage] {
        var messages = [ChatMessage.user("pedido original")]
        for index in 0..<steps { messages += step("c\(index)", output: output, path: "/Users/ana/src/mod\(index).swift") }
        return messages
    }

    @Test func eachStepSetAsideLeavesOneLineWithWhatItDid() throws {
        let window = ContextWindow.fit(hugeTask(steps: 30), budget: ContextBudget(tokens: 6_000))
        #expect(window.skippedSteps > 0)
        #expect(window.summary == nil)
        let note = try #require(window.messages.first)
        #expect(note.content.hasPrefix(ContextSummary.marker))
        // One line per step set aside (the oldest ones counted when there are more than the window can spare).
        let skippedSteps = window.skippedSteps
        #expect(note.content.contains("[passo \(skippedSteps)] read_file /Users/ana/src/mod\(skippedSteps - 1).swift -> ok, 3.000 car."))
        #expect(note.content.contains("começa com «ooo"))
        #expect(!note.content.contains("[passo \(skippedSteps + 1)]"))
        #expect(window.messages.last?.toolCallID == "c29")
        #expect(window.messages.contains { $0.content == "pedido original" })
    }

    @Test func theDigestIsBoundedWhateverTheNumberOfSteps() throws {
        let budget = ContextBudget(tokens: 20_000)
        let window = ContextWindow.fit(hugeTask(steps: 400, output: 2_000), budget: budget)
        let note = try #require(window.messages.first)
        let lines = note.content.split(separator: "\n").filter { $0.hasPrefix("[passo") || $0.hasPrefix("(+") }
        #expect(lines.count == ToolDigest.maxLines)
        #expect(note.content.contains("linhas anteriores"))
        #expect(note.content.count < ToolDigest.maxCharacters + 400)
        // A small window spares fewer lines.
        let small = ContextWindow.fit(hugeTask(steps: 400, output: 2_000), budget: ContextBudget(tokens: 3_000))
        let smallLines = try #require(small.messages.first).content.split(separator: "\n").filter { $0.hasPrefix("[passo") || $0.hasPrefix("(+") }
        #expect(smallLines.count == ToolDigest.lines(forLimit: ContextBudget(tokens: 3_000).characters))
        #expect(smallLines.count < ToolDigest.maxLines)
    }

    @Test func stepsAreSetAsideInABatchDownToTheLowWaterMark() {
        let budget = ContextBudget(tokens: 3_000)
        let window = ContextWindow.fit(hugeTask(steps: 30), budget: budget)
        #expect(characters(window.messages) <= Int(Double(budget.characters) * budget.stepsLowWater) + 200)
        // Nearly everything went at once (a step at a time would have stopped just under the limit).
        #expect(window.skippedSteps >= 28)
    }

    @Test func theCutHoldsBetweenBatches() {
        var messages = [ChatMessage.user("pedido original")]
        var cut = ContextCut()
        var previous: [ChatMessage] = []
        var changes = 0
        for index in 0..<60 {
            messages += step("k\(index)", output: 2_500, path: "/tmp/f\(index).txt")
            let window = ContextWindow.fit(messages, budget: ContextBudget(tokens: 6_000), cut: &cut)
            if !extends(previous, window.messages) { changes += 1 }
            previous = window.messages
        }
        #expect(changes < 32, "changes: \(changes)")
    }

    @Test func errorsAndAUserNoteInsideSetAsideStepsAreNotLost() throws {
        var messages = [ChatMessage.user("pedido original")]
        for index in 0..<20 { messages += step("z\(index)", output: 3_000, path: "/tmp/f\(index).txt") }
        messages += step("e0", output: 40, path: "/tmp/a.txt", name: "run_command", isError: true, filler: "E")
        messages.append(ChatMessage(role: .assistant, content: ProgressRecord.marker + "\n- ..."))
        messages.append(.user("continua, mas use a porta 4711"))
        for index in 0..<20 { messages += step("y\(index)", output: 3_000, path: "/tmp/g\(index).txt") }
        var cut = ContextCut()
        let window = ContextWindow.fit(messages, budget: ContextBudget(tokens: 6_000), cut: &cut, continuing: true)
        let note = try #require(window.messages.first)
        #expect(note.content.contains("ERRO: EEEE"))
        #expect(note.content.contains("[usuário] «continua, mas use a porta 4711»"))
        #expect(window.messages.contains { $0.content == "pedido original" })
        #expect(isValidConversation(window.messages))
    }

    @Test func aTaskThatFitsAfterShorteningSetsNothingAside() {
        let window = ContextWindow.fit(hugeTask(steps: 12, output: 3_000), budget: ContextBudget(tokens: 20_000))
        #expect(window.skippedSteps == 0)
        #expect(window.messages.first?.content == "pedido original")
    }
}

// MARK: - Digest lines

struct ToolDigestTests {
    @Test func aSuccessfulCallShowsItsTargetSizeAndStart() {
        let line = ToolDigest.line(call: call("a", "read_file", #"{"path":"/Users/x/src/mod3.swift"}"#),
                                   result: .tool("a", "func exemplo() {\nreturn 1\n}" + String(repeating: " ", count: 20_000)), step: 7)
        #expect(line == "[passo 7] read_file /Users/x/src/mod3.swift -> ok, 20.027 car.; começa com «func exemplo() {»")
    }

    @Test func aConnectorCallKeepsOnlyItsNameAndWhetherItWorked() {
        let arguments = #"{"connector":"Gmail","tool":"search_threads","arguments":{"query":"proposta Acme"}}"#
        #expect(ToolDigest.line(call: call("a", "connector_call", arguments), result: .tool("a", "Assunto: Proposta da Acme, R$ 480 mil"), step: 4)
                == "[passo 4] connector_call Gmail -> ok")
        #expect(ToolDigest.line(call: call("a", "connector_call", arguments), result: .tool("a", "Acme recusou", isError: true), step: 5)
                == "[passo 5] connector_call Gmail -> ERRO")
        // Before the gateway the call carried the tool's own name and arguments.
        let line = ToolDigest.line(call: call("a", "Gmail__search_threads", #"{"query":"proposta Acme"}"#), result: .tool("a", "Acme 480 mil"), step: 6)
        #expect(line == "[passo 6] Gmail__search_threads -> ok")
        #expect(ToolDigest.line(call: call("a", "connector_tools", #"{"connector":"Slack"}"#), result: nil, step: 7) == "[passo 7] connector_tools Slack -> sem resposta")
    }

    @Test func anErrorShowsItsFirstLine() {
        let line = ToolDigest.line(call: call("a", "run_command", #"{"command":"swift test"}"#),
                                   result: .tool("a", "Error: 3 tests failed\nmore", isError: true), step: 9)
        #expect(line == "[passo 9] run_command swift test -> ERRO: Error: 3 tests failed")
    }

    @Test func aCallWithoutAnAnswerAndAnEmptyAnswerAreSaid() {
        #expect(ToolDigest.line(call: call("a", "grep", #"{"pattern":"TODO"}"#), result: nil, step: 1) == "[passo 1] grep TODO -> sem resposta")
        #expect(ToolDigest.line(call: call("a", "list_directory"), result: .tool("a", ""), step: 2) == "[passo 2] list_directory -> ok, vazio")
        let picture = ChatMessage.tool("a", "", images: [ImageAttachment(path: "/tmp/p.jpg", mediaType: "image/jpeg", width: 1, height: 1)])
        #expect(ToolDigest.line(call: call("a", "screenshot"), result: picture, step: 3) == "[passo 3] screenshot -> ok, 1 imagem(ns)")
    }

    @Test func theTargetIsThePathCommandOrFirstTextArgument() {
        func target(_ arguments: String) -> String {
            let line = ToolDigest.line(call: call("a", "t", arguments), result: .tool("a", ""), step: 1)
            return String(line.dropFirst("[passo 1] t".count).dropLast(" -> ok, vazio".count))
        }
        #expect(target(#"{"path":"/a/b","command":"ls"}"#) == " /a/b")
        #expect(target(#"{"command":"ls -la"}"#) == " ls -la")
        #expect(target(#"{"url":"https://example.com"}"#) == " https://example.com")
        #expect(target(#"{"zeta":"z","alfa":"primeiro"}"#) == " primeiro")
        #expect(target(#"{"n":3}"#) == "")
        #expect(target("not json") == "")
        // Long and multi-line values are flattened and cut.
        #expect(target(#"{"command":"a\nb \#(String(repeating: "x", count: 200))"}"#).count <= 61)
    }

    @Test func aLineNeverPassesItsLimit() {
        let line = ToolDigest.line(call: call("a", "run_command", #"{"command":"\#(String(repeating: "c", count: 500))"}"#),
                                   result: .tool("a", String(repeating: "r", count: 500), isError: true), step: 1)
        #expect(line.count <= ToolDigest.maxLineLength)
    }

    @Test func linesFollowTheStepsAndKeepWhatTheUserAndTheModelSaid() {
        let messages: [ChatMessage] = [
            .user("<orb_context>\nNow: x\n</orb_context>\n\nfaça o X"),
            ChatMessage(role: .assistant, content: "Vou ler o arquivo.", toolCalls: [call("a", "read_file", #"{"path":"/a.txt"}"#)]),
            .tool("a", "conteúdo"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call("b", "grep", #"{"pattern":"x"}"#), call("c", "read_file", #"{"path":"/c.txt"}"#)]),
            .tool("b", "achou"), .tool("c", "outro")]
        let lines = ToolDigest.lines(for: messages)
        #expect(lines == ["[usuário] «faça o X»",
                          "[passo 1] disse: «Vou ler o arquivo.»",
                          "[passo 1] read_file /a.txt -> ok, 8 car.; começa com «conteúdo»",
                          "[passo 2] grep x -> ok, 5 car.; começa com «achou»",
                          "[passo 2] read_file /c.txt -> ok, 5 car.; começa com «outro»"])
        #expect(ToolDigest.lines(for: messages, firstStep: 5).contains { $0.hasPrefix("[passo 6] grep") })
    }

    @Test func manyLinesKeepTheNewestAndCountTheRest() {
        var messages: [ChatMessage] = []
        for index in 0..<60 { messages += step("s\(index)", output: 10, path: "/tmp/f\(index).txt") }
        let lines = ToolDigest.lines(for: messages)
        #expect(lines.count == ToolDigest.maxLines)
        #expect(lines.first == "(+37 linhas anteriores)")
        #expect(lines.last?.contains("/tmp/f59.txt") == true)
    }

    @Test func numbersAreGroupedByThousands() {
        #expect(ToolDigest.grouped(0) == "0")
        #expect(ToolDigest.grouped(999) == "999")
        #expect(ToolDigest.grouped(1_000) == "1.000")
        #expect(ToolDigest.grouped(1_234_567) == "1.234.567")
    }
}

// MARK: - Progress record

struct ProgressRecordTests {
    @Test func aRecordListsTheStepsOfTheTask() throws {
        let task: [ChatMessage] = [.user("faça")] + step("a", output: 20, path: "/a.txt")
        let text = try #require(ProgressRecord.text(task: task))
        #expect(text.hasPrefix(ProgressRecord.marker + "\n"))
        #expect(text.contains("[passo 1] read_file /a.txt"))
        #expect(ProgressRecord.text(task: [.user("oi"), ChatMessage(role: .assistant, content: "oi")]) == "[Orb] Progresso até aqui:\n[usuário] «oi»\n[passo 1] disse: «oi»")
        #expect(ProgressRecord.text(task: []) == nil)
    }

    @Test func aPausedConversationIsOneWhoseLastMessageIsTheRecord() {
        var conversation = Conversation()
        #expect(!conversation.isTaskPaused)
        conversation.messages = [.user("oi"), ChatMessage(role: .assistant, content: "pronto")]
        #expect(!conversation.isTaskPaused)
        conversation.messages.append(ChatMessage(role: .assistant, content: "texto\n\n" + ProgressRecord.marker + "\n- x"))
        #expect(conversation.isTaskPaused)
        conversation.messages.append(.user("continua"))
        #expect(!conversation.isTaskPaused)
        #expect(!ProgressRecord.endsHistory([]))
        #expect(!ProgressRecord.endsHistory([ChatMessage(role: .user, content: ProgressRecord.marker)]))
    }
}

// MARK: - Old outputs

struct OldOutputsTests {
    @Test func aSavedOutputsNoteSurvivesEveryPreview() {
        let note = "\n[full output saved at /Users/x/Library/Application Support/Orb/saidas/AAAA/call_1-ABCD1234.txt; read it with read_file (offset/limit page by lines) or grep; for very long lines use run_command with head -c, cut or grep -o]"
        let capped = String(repeating: "h", count: 10_000) + ContextText.marker(50_000) + String(repeating: "t", count: 5_000) + note
        for limit in [4_000, 1_500, 800] {
            let short = ContextText.preview(capped, limit: limit)
            #expect(short.hasSuffix(note))
            #expect(short.count < limit + note.count + 120)
            #expect(ContextText.preview(short, limit: limit) == short)
        }
    }

    @Test func anOutputWithoutANoteIsCutAsBefore() {
        let text = String(repeating: "a", count: 10_000)
        let short = ContextText.preview(text, limit: 800)
        #expect(short.hasPrefix(String(repeating: "a", count: 500)) && short.hasSuffix(String(repeating: "a", count: 300)))
        #expect(short.contains("9200 characters omitted from the middle"))
    }

    @Test func anErrorKeepsItsEndWhenOldOutputsAreCondensed() {
        var conversation = Conversation()
        let failure = String(repeating: "log ", count: 3_000) + "CAUSA: arquivo não encontrado"
        conversation.messages = [.user("rode")]
        conversation.messages += [ChatMessage(role: .assistant, content: "", toolCalls: [call("e")]), .tool("e", failure, isError: true),
                                  ChatMessage(role: .assistant, content: "falhou")]
        conversation.messages += [ChatMessage(role: .assistant, content: "", toolCalls: [call("p")]), .tool("p", failure),
                                  ChatMessage(role: .assistant, content: "ok")]
        for index in 0..<3 { conversation.messages += turn("depois \(index)", output: 50, tag: "d\(index)") }
        let window = ContextWindow.fit(conversation.messages, budget: .fallback, condensing: 6)
        let outputs = window.messages.filter { $0.role == .tool }
        let error = outputs[0], plain = outputs[1]
        #expect(error.content.hasSuffix("CAUSA: arquivo não encontrado"))
        #expect(error.content.count > plain.content.count)
        #expect(plain.content.count < 1_000)
        // At least 400 characters of the end of an error.
        #expect(error.content.hasSuffix(String(failure.suffix(400))))
    }
}

// MARK: - Condensing

struct CondensingTests {
    @Test func anOldPrefaceKeepsOnlyItsTime() {
        let message = prefaced("faça X", snapshot: true, notes: "From your memory, related to this message:\n<memory_notes>\nalgo\n</memory_notes>")
        let text = message.content
        let condensed = TurnPreface.condensed(text, keepingSnapshot: false)
        #expect(condensed.hasPrefix("<orb_context>\nNow: "))
        #expect(condensed.hasSuffix("</orb_context>\n\nfaça X"))
        #expect(!condensed.contains("workspace_snapshot") && !condensed.contains("memory_notes"))
        #expect(condensed.count < text.count / 2)
        #expect(TurnPreface.condensed(condensed, keepingSnapshot: false) == condensed)
        #expect(TurnPreface.condensed(text, keepingSnapshot: true) == text)
        #expect(TurnPreface.condensed("sem prefácio", keepingSnapshot: false) == "sem prefácio")
        #expect(TurnPreface.stripped(condensed) == "faça X")
    }

    @Test func aPrefaceWithoutATimeGoesAway() {
        let text = "<orb_context>\nalgo estranho\n</orb_context>\n\npedido"
        #expect(TurnPreface.condensed(text, keepingSnapshot: false) == "pedido")
    }

    @Test func theNewestSnapshotAndTheLastTwoTurnsStayWhileOlderOnesAreCondensed() {
        var messages: [ChatMessage] = []
        for index in 0..<6 { messages += [prefaced("pedido \(index)", snapshot: index == 0 || index == 3), ChatMessage(role: .assistant, content: "ok \(index)")] }
        let frontier = ContextCondensing.frontier(in: messages)
        #expect(frontier == 8)   // the start of the second-to-last turn
        let window = ContextWindow.fit(messages, budget: .fallback, condensing: frontier)
        let sent = window.messages.filter { $0.role == .user }.map(\.content)
        // 0 and 1, 2: condensed (0 had a snapshot, but a newer one exists); 3: the newest snapshot, whole; 4, 5: recent.
        #expect(!sent[0].contains("workspace_snapshot") && !sent[1].contains("workspace_snapshot") && !sent[2].contains("workspace_snapshot"))
        #expect(sent[3].contains("workspace_snapshot"))
        #expect(sent[4] == messages[8].content && sent[5] == messages[10].content)
        #expect(TurnPreface.hasSnapshot(in: window.messages))
        // The stored messages are untouched.
        #expect(messages[0].content.contains("workspace_snapshot"))
    }

    @Test func oldOutputsReasoningAndNothingElseOfAMessageAreCut() {
        let trace = ReasoningTrace(format: .responses, provider: "api.openai.com", model: "m",
                                   parts: [ReasoningPart(kind: .encrypted, text: "resumo", data: String(repeating: "Z", count: 4_000), id: "rs_1")])
        var old = ChatMessage(role: .assistant, content: "resposta", toolCalls: [call("r")])
        old.reasoning = trace
        var messages: [ChatMessage] = [.user("um"), old, .tool("r", String(repeating: "q", count: 5_000)), ChatMessage(role: .assistant, content: "fim")]
        var recent = ChatMessage(role: .assistant, content: "recente")
        recent.reasoning = trace
        messages += [.user("dois"), recent, .user("três"), ChatMessage(role: .assistant, content: "x")]
        let window = ContextWindow.fit(messages, budget: .fallback, condensing: 4)
        #expect(window.messages[1].reasoning == nil)
        #expect(window.messages[1].content == "resposta" && window.messages[1].toolCalls == old.toolCalls)
        #expect(window.messages.first { $0.content == "recente" }?.reasoning == trace)
        #expect(window.messages[2].content.count < 1_000)
    }

    @Test func reasoningCountsInTheSizeOfAMessage() {
        var message = ChatMessage(role: .assistant, content: "oi")
        let base = message.contextCharacters
        message.reasoning = ReasoningTrace(format: .messages, provider: "p", model: "m", parts: [
            ReasoningPart(kind: .thinking, text: String(repeating: "t", count: 100), signature: String(repeating: "s", count: 50)),
            ReasoningPart(kind: .encrypted, text: "abc", data: String(repeating: "d", count: 1_000))])
        #expect(message.contextCharacters == base + 100 + 50 + 3 + 1_000)
    }

    @Test func aConversationIsCondensedInOneBatchAndThenLeftAlone() {
        var conversation = Conversation()
        let budget = ContextBudget(tokens: 40_000)
        var batches = 0
        var previous: [ChatMessage] = []
        for index in 0..<30 {
            var next = [prefaced("pedido \(index)", snapshot: index == 0, notes: "<memory_notes>\n\(String(repeating: "n", count: 600))\n</memory_notes>")]
            next += step("q\(index)", output: 3_000, path: "/tmp/f\(index).txt")
            next.append(ChatMessage(role: .assistant, content: "ok \(index)"))
            conversation.messages += next
            let before = conversation.condensedCount
            let history = conversation.prepareHistory(budget: budget).history
            if conversation.condensedCount != before { batches += 1 }
            if conversation.condensedCount == before, !previous.isEmpty { #expect(extends(previous, history)) }
            previous = history
            #expect(isValidConversation(history))
        }
        // Condensing waited until it saved enough, then moved in jumps: a few times in 30 turns, not 28.
        #expect(batches >= 3 && batches <= 8, "batches: \(batches)")
        // What is stored still has everything.
        #expect(conversation.messages.first?.content.contains("workspace_snapshot") == true)
        #expect(conversation.messages.filter { $0.role == .tool }.allSatisfy { $0.content.count == 3_000 })
    }

    @Test func aLongConversationFromBeforeCondensingExistedIsCondensedAtTheFirstTurn() {
        var conversation = Conversation()
        for index in 0..<12 {
            conversation.messages.append(prefaced("pedido \(index)", snapshot: index == 0, notes: "<memory_notes>\n\(String(repeating: "n", count: 800))\n</memory_notes>"))
            conversation.messages += step("v\(index)", output: 4_000, path: "/tmp/f\(index).txt")
            conversation.messages.append(ChatMessage(role: .assistant, content: "ok"))
        }
        #expect(conversation.condensedCount == nil)
        let history = conversation.prepareHistory(budget: ContextBudget(tokens: 60_000)).history
        let frontier = ContextCondensing.frontier(in: conversation.messages)
        #expect(conversation.condensedCount == frontier)
        #expect(history.count == conversation.messages.count)
        #expect(characters(history) < characters(conversation.messages) * 6 / 10)
        // The last two turns are as they were.
        #expect(Array(history.suffix(conversation.messages.count - frontier)) == Array(conversation.messages[frontier...]))
    }

    @Test func aSmallSavingIsNotWorthRewritingTheCache() {
        var conversation = Conversation()
        for index in 0..<6 { conversation.messages += turn("pedido \(index)", steps: 1, output: 200, tag: "m\(index)") }
        let before = conversation.messages
        let history = conversation.prepareHistory(budget: ContextBudget(tokens: 40_000)).history
        #expect(history == before)
        #expect(conversation.condensedCount == nil)
    }

    @Test func savingsCountOnlyWhatCondensingWouldCut() {
        let messages: [ChatMessage] = [prefaced("a", snapshot: true, notes: "<memory_notes>\n\(String(repeating: "n", count: 500))\n</memory_notes>"),
                                       ChatMessage(role: .assistant, content: "", toolCalls: [call("x")]), .tool("x", String(repeating: "o", count: 3_000)),
                                       ChatMessage(role: .assistant, content: "ok"), prefaced("b"), ChatMessage(role: .assistant, content: "ok")]
        #expect(ContextCondensing.savings(in: messages, from: 0, to: 0) == 0)
        // The newest snapshot message is `a`, kept whole: only the output (3,000 -> 800) counts.
        let saved = ContextCondensing.savings(in: messages, from: 0, to: 4)
        #expect(saved > 2_100 && saved < 2_400)
        #expect(ContextCondensing.savings(in: messages, from: 4, to: 9) == 0)
    }

    @Test func theFrontierNeedsTwoTurnsToLeaveAlone() {
        #expect(ContextCondensing.frontier(in: []) == 0)
        #expect(ContextCondensing.frontier(in: turn("a")) == 0)
        #expect(ContextCondensing.frontier(in: turn("a") + turn("b")) == 0)
        #expect(ContextCondensing.frontier(in: turn("a") + turn("b") + turn("c")) == 4)
    }

    @Test func conversationsFromBeforeCondensingStillDecodeAndTheCountRoundTrips() throws {
        let old = #"{"items":[],"messages":[{"role":"user","content":"oi","toolCalls":[]}],"summary":"x","summaryCoveredCount":2}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
        #expect(decoded.condensedCount == nil)
        var conversation = Conversation()
        conversation.condensedCount = 14
        let again = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(again.condensedCount == 14)
    }

    @Test func aNewRoutineRunStartsWithoutACondensedCount() {
        var conversation = Conversation()
        conversation.messages = turn("a")
        conversation.condensedCount = 3
        #expect(conversation.startingRoutineRun(at: .now).condensedCount == nil)
    }
}

// MARK: - Meter

struct ContextMeterTests {
    @Test func anEmptyConversationOnlyCarriesTheFixedPart() {
        let fill = Conversation().contextFill(budget: ContextBudget(modelWindow: 128_000))
        #expect(fill.historyTokens == 0)
        #expect(fill.usedTokens == ContextBudget.typicalOverheadTokens)
        #expect(fill.windowTokens == 128_000)
        #expect(fill.fraction > 0.06 && fill.fraction < 0.07)
        #expect(fill.compaction == nil && fill.budgetFraction <= 1)
        #expect(fill.foldedMessages == 0)
    }

    @Test func theHistoryIsMeasuredAsTheNextRequestWouldCarryIt() {
        var conversation = Conversation()
        conversation.messages = (0..<6).flatMap { turn("pedido \($0)", steps: 1, output: 2_000, tag: "f\($0)") }
        let budget = ContextBudget(modelWindow: 128_000)
        let fill = conversation.contextFill(budget: budget)
        let expected = ContextBudget.tokens(forCharacters: characters(conversation.messages))
        #expect(fill.historyTokens == expected)
        #expect(fill.usedTokens == expected + budget.overheadTokens)
        #expect(fill.budgetTokens == budget.tokens)
        #expect(fill.budgetFraction == Double(expected) / Double(budget.tokens))
        // Nothing was changed by looking.
        #expect(conversation.summary == nil && conversation.summaryCoveredCount == nil && conversation.condensedCount == nil)
    }

    @Test func compactionShowsWhatItWouldFold() throws {
        var conversation = Conversation()
        conversation.messages = (0..<20).flatMap { turn("pedido \($0)", steps: 1, output: 3_000, tag: "g\($0)") }
        let fill = conversation.contextFill(budget: ContextBudget(tokens: 30_000))
        let compaction = try #require(fill.compaction)
        #expect(compaction.turns > 0 && compaction.turns < 20)
        #expect(compaction.messages > 0)
        #expect(compaction.tokensFreed > 0 && compaction.tokensFreed < fill.historyTokens)
        // A manual compaction goes lower than the automatic one: it frees more than reaching the budget would.
        let automatic = ContextWindow.fit(conversation.messages, budget: ContextBudget(tokens: 30_000))
        #expect(compaction.messages >= automatic.droppedCount)
    }

    @Test func aSummaryAlreadyKeptCountsAndAFullHistoryIsFlagged() {
        var conversation = Conversation()
        conversation.messages = (0..<30).flatMap { turn("pedido \($0)", steps: 1, output: 3_000, tag: "h\($0)") }
        let budget = ContextBudget(tokens: 8_000)
        _ = conversation.prepareHistory(budget: budget)
        let fill = conversation.contextFill(budget: budget)
        #expect(fill.foldedMessages == conversation.summaryCoveredCount)
        #expect(fill.foldedMessages > 0 && conversation.summary != nil)
        // Too small a budget for what is left: the next message starts a compaction.
        let tight = conversation.contextFill(budget: ContextBudget(tokens: 600))
        #expect(tight.budgetFraction > 1)
    }

    @Test func aBudgetWithoutAWindowEstimatesOne() {
        let budget = ContextBudget(tokens: 10_000)
        let fill = Conversation().contextFill(budget: budget)
        #expect(fill.windowTokens == 10_000)
    }
}
