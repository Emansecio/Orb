import AppKit

/// Ends the app after a reset and, when it is an installed app (a bundle), opens it again so that it starts as a
/// first use: new state, no caches of the old one. A build run straight from SwiftPM has no bundle to open: it only
/// quits and the person opens it again.
enum AppRelaunch {
    /// The bundle to open again; nil when this process is not an app (SwiftPM, tests).
    static func bundleURL(of bundle: Bundle = .main) -> URL? {
        bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil
    }

    /// Waits (at most 20 s) for the process `$1` to end and then opens the bundle `$2`. If the process is still there
    /// after the 20 s it opens nothing: a second instance over the same data folder is worse than a closed app. No
    /// `-n`: the old process is gone, and an app the person already opened by hand is brought forward, not doubled.
    /// The paths travel as arguments, not inside the script, so nothing needs quoting.
    static let script = """
        n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.2; n=$((n+1)); done
        kill -0 "$1" 2>/dev/null && exit 0
        /usr/bin/open "$2"
        """

    /// The command that opens the app again once this process is gone.
    static func command(pid: Int32, bundle: URL) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", String(pid), bundle.path])
    }

    /// Starts the helper that reopens the app (when it can) and quits.
    @MainActor
    static func finish() {
        if let bundle = bundleURL() {
            let (executable, arguments) = command(pid: ProcessInfo.processInfo.processIdentifier, bundle: bundle)
            let helper = Process()
            helper.executableURL = executable
            helper.arguments = arguments
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try? helper.run()
        }
        AppTermination.quit()
    }
}

/// Quitting the app. AppKit ignores `terminate` while any window has a sheet attached (it does not even ask the
/// delegate), so a quit with the "Redefinindo…" or "Novo Orb" sheet open did nothing: the sheets close first.
enum AppTermination {
    @MainActor
    static func quit() {
        closeSheets()
        NSApp.terminate(nil)
    }

    /// Ends every sheet, innermost first (a sheet can carry a sheet of its own).
    @MainActor
    static func closeSheets(in windows: [NSWindow] = NSApp.windows) {
        for window in windows {
            while let sheet = innermostSheet(of: window) {
                (sheet.sheetParent ?? window).endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
    }

    @MainActor
    private static func innermostSheet(of window: NSWindow) -> NSWindow? {
        var sheet = window.attachedSheet
        while let inner = sheet?.attachedSheet { sheet = inner }
        return sheet
    }
}
