import Foundation
import Testing
@testable import Orb

extension AppModel {
    /// Returns once no routine is being started: its conversation was read and the run began, or it went back to the
    /// queue. `runRoutine` reads that conversation off the main thread, so a test looks at the run after this.
    @MainActor func routineStarted() async {
        // Polled closely: a routine that answers at once must still be seen running by the test that asked for it.
        await waitUntil("the routine to start", poll: .milliseconds(1)) { !self.isStartingRoutine }
    }
}

/// Returns once the Orb has finished its turn: not working, no turn task, and no routine being started for it.
@MainActor func waitUntilIdle(_ model: AppModel, _ botID: UUID) async {
    await waitUntil("the Orb to finish its turn") { !model.isWorking(botID) && model.session(botID).turnTask == nil && !model.isStartingRoutine }
}
