import Foundation
import Testing
@testable import Orb

/// A reply that says the work is done is checked against what the turn's calls showed (`CompletionWatch`).
struct CompletionWatchTests {
    private func command(_ text: String) -> ToolCallRequest {
        ToolCallRequest(id: "c", name: "run_command", arguments: JSONValue.object(["command": .string(text)]).jsonString)
    }

    @Test func onlyBuildsAndTestsThatEndedCount() {
        var watch = CompletionWatch()
        watch.record(command("ls -la"), result: "Código de saída: 1\n", failed: true)
        #expect(watch.lastCheck == nil)
        watch.record(command("swift test --filter X"), result: "[O comando continua rodando em segundo plano…", failed: false)
        #expect(watch.lastCheck == nil, "still running: no verdict yet")
        watch.record(command("npm run build"), result: "Código de saída: 2\n", failed: true)
        #expect(watch.lastCheck?.passed == false)
        watch.record(command("pytest -q"), result: "Código de saída: 0\n", failed: false)
        #expect(watch.lastCheck?.command == "pytest -q" && watch.lastCheck?.passed == true)
        watch.record(ToolCallRequest(id: "r", name: "read_file", arguments: #"{"path":"x"}"#), result: "", failed: true)
        #expect(watch.lastCheck?.passed == true)
        watch.record(command("swift test"), result: "Error: Pasta não encontrada: /x.", failed: true)
        #expect(watch.lastCheck?.passed == true, "never started: no verdict")
        watch.record(command("swift test"), result: "(sem saída)\n[tempo esgotado após 120 s; …]", failed: true)
        #expect(watch.lastCheck?.passed == false, "a test that ran out of time did not pass")
    }

    @Test func aClaimOfSuccessAfterAFailedCheckIsQuestioned() {
        var watch = CompletionWatch()
        watch.record(command("swift build"), result: "Código de saída: 1\n", failed: true)
        #expect(watch.reminder(for: "Pronto! Implementei a tela nova.") != nil)
        #expect(watch.reminder(for: "All set, the build works.") != nil)
        #expect(watch.reminder(for: "Implementei a tela, mas o build falhou por causa de X.") == nil)
        #expect(watch.reminder(for: "Ainda não consegui fazer compilar.") == nil)
        #expect(watch.reminder(for: "Rodei: 120 passaram e 5 quebraram.") == nil)
        #expect(watch.reminder(for: "Done with the screen, but the build isn't working yet.") == nil)
        #expect(watch.reminder(for: "Pronto, corrigi os erros que apareceram.") != nil, "fixing errors is no failure")
        #expect(watch.reminder(for: "Qual das duas opções você prefere?") == nil, "no claim of done")
        #expect(CompletionWatch().reminder(for: "Pronto, tudo passando.") == nil, "nothing ran")
    }

    @Test func aFileTheReplySaysItSavedMustBeThere() {
        let exists: (String) -> Bool = { $0.hasSuffix("existe.pdf") }
        let watch = CompletionWatch()
        let home = NSHomeDirectory()
        #expect(watch.reminder(for: "Salvei o relatório em ~/Desktop/relatorio.pdf.", fileExists: exists)?
            .contains("\(home)/Desktop/relatorio.pdf") == true)
        #expect(watch.reminder(for: "Exportei para `/Users/thiago/Meus Docs/plano.xlsx`.", fileExists: exists) != nil)
        #expect(watch.reminder(for: "Salvei em ~/Desktop/existe.pdf.", fileExists: exists) == nil)
        #expect(watch.reminder(for: "Criei o endpoint /api/users.json no servidor.", fileExists: exists) == nil, "a URL path")
        #expect(watch.reminder(for: "Movi ~/Desktop/velho.pdf para a pasta Arquivo.", fileExists: exists) == nil)
        #expect(watch.reminder(for: "O arquivo ~/Desktop/outro.pdf tem 3 páginas.", fileExists: exists) == nil, "not said to be saved")
        #expect(watch.reminder(for: "Criei o script que vai gerar `/tmp/saida.csv`.", fileExists: exists) == nil, "not there yet")
        #expect(watch.reminder(for: "Não salvei em ~/Desktop/nada.pdf.", fileExists: exists) == nil)
    }

    @Test func buildAndTestCommandsAreRecognized() {
        for check in ["swift build -c release", "xcodebuild -scheme App test", "cargo test", "go vet ./...", "make", "npx tsc --noEmit",
                      "yarn lint", "./gradlew assembleDebug build", "cd app && nice -n 15 swift test --filter X",
                      "set -o pipefail; swift build 2>&1 | tail -30", "FOO=1 python3 -m pytest -q"] {
            #expect(CompletionWatch.isCheck(check), "\(check)")
        }
        for other in ["ls", "git status", "cat Makefile", "swift --version", "open relatorio.pdf", #"git commit -m "make it work""#,
                      "pip install pytest", "which jest", "swift build 2>&1 | tail -30"] {
            #expect(!CompletionWatch.isCheck(other), "\(other)")
        }
    }
}
