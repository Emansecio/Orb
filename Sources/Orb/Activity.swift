import Foundation

/// What the app asks of macOS so that routines run when nobody is at the Mac: not to put the app to sleep (App Nap
/// stretches its timers once the window is closed) and not to put the Mac to sleep in the middle of a run.
enum ActivityLevel {
    /// A routine is scheduled: the app is not napped, the Mac may still sleep.
    case waiting
    /// A routine is running: the Mac does not go to sleep on its own either.
    case running
}

@MainActor
protocol ActivityAsserting {
    func begin(_ level: ActivityLevel, reason: String) -> any NSObjectProtocol
    func end(_ token: any NSObjectProtocol)
}

/// The real thing (`ProcessInfo` activities). Tests and developer runs use `InertActivity` or a fake.
struct SystemActivity: ActivityAsserting {
    func begin(_ level: ActivityLevel, reason: String) -> any NSObjectProtocol {
        let options: ProcessInfo.ActivityOptions = level == .running ? .userInitiated : .userInitiatedAllowingIdleSystemSleep
        return ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    func end(_ token: any NSObjectProtocol) { ProcessInfo.processInfo.endActivity(token) }
}

struct InertActivity: ActivityAsserting {
    func begin(_ level: ActivityLevel, reason: String) -> any NSObjectProtocol { NSObject() }
    func end(_ token: any NSObjectProtocol) {}
}

extension AppModel {
    /// Takes or lets go of the activities so they match what the app is doing: one while a routine runs, one while
    /// any routine is switched on. Called wherever either changes (`routines`, a session's `routineID`, an approval
    /// card opening or closing). A routine stopped at a card waits for you, not for the Mac: it does not hold it awake.
    func syncActivities() {
        let running = isResetting ? nil : sessions.values.first { $0.routineID != nil && !needsYou($0.id) }?.routineID
        if let running, runningActivity == nil {
            let name = routines.first { $0.id == running }?.name ?? ""
            runningActivity = activity.begin(.running, reason: "Rotina “\(name)” em andamento")
        } else if running == nil, let token = runningActivity {
            runningActivity = nil
            activity.end(token)
        }
        let waiting = keepsAwakeForRoutines && !isResetting && routines.contains { $0.isEnabled }
        if waiting, waitingActivity == nil {
            waitingActivity = activity.begin(.waiting, reason: "Rotinas agendadas")
        } else if !waiting, let token = waitingActivity {
            waitingActivity = nil
            activity.end(token)
        }
    }
}
