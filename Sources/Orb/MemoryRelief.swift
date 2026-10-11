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
}
