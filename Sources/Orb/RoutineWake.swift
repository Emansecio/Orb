import Foundation

/// An outside process wakes a routine by dropping `<routine>.wake` into the app's `wake/` folder — a connector's
/// watcher, a launchd job, a shortcut, a script that saw new messages. The file's stem names the routine by its id
/// or its name (trimmed, case-insensitive); its text, when present, lands in the run it woke as why it ran
/// off-schedule. The app consumes the file and starts the run on the spot: the folder is a doorbell — the routine
/// still runs once at a time (rings while it runs queue once, as any run does) and its `precheck`, if it has one,
/// still gates. A routine switched off ignores its bell.
extension AppModel {
    /// `<data>/wake/`: where wake files land. Beside the data, not in it — its contents are never read as state.
    static let wakeFolder = "wake"
    static let wakeSuffix = ".wake"

    var wakeFolderURL: URL { store.directory.appendingPathComponent(Self.wakeFolder, isDirectory: true) }

    /// Watches `wake/` for arrivals: one folder descriptor, no polling. Re-created whenever it runs — a reset that
    /// remade the data folder cost the old watch its descriptor.
    func startWakeWatch() {
        wakeWatch?.cancel()
        try? FileManager.default.createDirectory(at: wakeFolderURL, withIntermediateDirectories: true)
        let descriptor = open(wakeFolderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .global(qos: .utility))
        // `@Sendable`, so the handler is not MainActor-isolated (a plain closure would inherit it from here, and
        // the source runs it on its own queue, where that isolation does not hold).
        source.setEventHandler { @Sendable [weak self] in Task { @MainActor in self?.scanWakeFolder() } }
        source.setCancelHandler { @Sendable in close(descriptor) }
        source.resume()
        wakeWatch = source
    }

    /// Files waiting in `wake/`: each is consumed (a bad name is dropped once, not on every pass) and rings its
    /// routine. The watch calls this on arrivals; a test calls it by hand after dropping its file.
    func scanWakeFolder() {
        guard !isResetting else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: wakeFolderURL.path) else {
            startWakeWatch() // the folder went away (the data folder was remade): make it and re-arm the watch
            return
        }
        for name in names.sorted() where name.hasSuffix(Self.wakeSuffix) {
            let file = wakeFolderURL.appendingPathComponent(name)
            let note = (try? String(contentsOf: file, encoding: .utf8))
                .map { MemoryText.flatten($0) }
                .flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            try? FileManager.default.removeItem(at: file)
            wakeRoutine(named: String(name.dropLast(Self.wakeSuffix.count)), note: note)
        }
    }

    /// The wake file's stem: a routine's id, or its name (trimmed, case-insensitive). Anything else is dropped, and
    /// a routine switched off does not run — "off" means off, however it was asked.
    private func wakeRoutine(named key: String, note: String?) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let routine = UUID(uuidString: key).flatMap { id in routines.first { $0.id == id } }
            ?? routines.first { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }
        guard let routine, routine.isEnabled else { return }
        runRoutine(routine.id, wakeNote: note)
    }
}
