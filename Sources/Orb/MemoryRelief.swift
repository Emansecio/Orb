import Darwin.malloc
import Foundation

/// Gives the system back the memory the allocator still holds after big frees (a long conversation decoded and let go,
/// the editor's bitmaps): without it the process keeps those pages and its footprint never comes down.
enum MemoryRelief {
    /// Right here, on the calling thread (a store's queue).
    static func now() { malloc_zone_pressure_relief(nil, 0) }

    /// A screen full of Orbs closed (the editor, Novo Orb, Novo grupo): the bitmaps it decoded go (the Orbs still on
    /// screen keep their own), then the memory they held.
    static func orbsClosed() {
        OrbImages.trim()
        soon()
    }

    /// Off the main thread: walking the zones takes a few milliseconds.
    static func soon() {
        DispatchQueue.global(qos: .utility).async { now() }
    }

    /// Drops transient caches when the app sits in the background (`aggressive: false`) or when macOS signals memory
    /// pressure (`aggressive: true`), then returns freed pages to the OS.
    @MainActor
    static func trimCaches(aggressive: Bool, memory: MemoryLibrary? = nil) {
        OrbImages.trim()
        DocumentTextCache.shared.clear()
        ImageWire.clearCache()
        UILiveElements.shared.pruneExpired()
        if aggressive {
            Thumbnails.clear()
            RichPictures.clear()
            ProseText.clearCache()
            MarkdownCache.removeAll()
            ClaudePipeIdlePool.shared.stopAll()
        }
        Task.detached(priority: .utility) {
            if aggressive {
                await WebPageCache.shared.clear()
            } else {
                await WebPageCache.shared.pruneExpired()
            }
            await SCKSession.shared.clear()
            if aggressive, let memory { await memory.shrinkAll() }
            now()
        }
    }
}

/// Observes macOS memory-pressure events (`.warning` / `.critical`) and runs a handler on the main actor.
@MainActor
final class MemoryPressureMonitor {
    private let source: DispatchSourceMemoryPressure

    init(onPressure: @escaping @MainActor (_ critical: Bool) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let critical = source.data.contains(.critical)
            MainActor.assumeIsolated { onPressure(critical) }
        }
        source.resume()
        self.source = source
    }

    deinit { source.cancel() }
}
