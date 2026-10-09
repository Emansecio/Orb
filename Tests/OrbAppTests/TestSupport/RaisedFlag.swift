import Foundation
import Observation

/// A flag a callback raises (from any thread) and the test reads afterwards.
final class RaisedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// Whether `change` notifies a view that reads `reads` (what `withObservationTracking` reports).
@MainActor
func notifies(reading reads: @MainActor () -> Void, whenYouDo change: @MainActor () -> Void) -> Bool {
    let flag = RaisedFlag()
    withObservationTracking { reads() } onChange: { flag.raise() }
    change()
    return flag.isRaised
}
