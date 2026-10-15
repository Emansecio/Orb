import Foundation

/// A value shared between a test and the closures it hands to code that runs elsewhere.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Reads and changes the value under one hold of the lock.
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}

extension LockedBox where Value: RangeReplaceableCollection, Value.Element: Sendable {
    func append(_ element: Value.Element) { withLock { $0.append(element) } }
}
