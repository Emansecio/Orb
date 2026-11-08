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
        // Any other turn (a chat, a delegated request, a group's round: all run as a turn of some Orb) holds the Mac awake
        // the same way, so a long task left running while you step away is not cut short by idle sleep.
        let working = !isResetting && workingIDs.contains { !needsYou($0) }
        if running != nil || working, runningActivity == nil {
            let name = running.flatMap { id in routines.first { $0.id == id }?.name }
            runningActivity = activity.begin(.running, reason: name.map { "Rotina “\($0)” em andamento" } ?? "Orb trabalhando")
        } else if running == nil, !working, let token = runningActivity {
            runningActivity = nil
            activity.end(token)
        }
        // The pulse wakes an Orb on a timer, so with it on the app is not napped either, as with a routine scheduled.
        let waiting = keepsAwakeForRoutines && !isResetting && (routines.contains { $0.isEnabled } || (pulseIsOn && bots.count > 1))
        if waiting, waitingActivity == nil {
            waitingActivity = activity.begin(.waiting, reason: "Rotinas agendadas")
        } else if !waiting, let token = waitingActivity {
            waitingActivity = nil
            activity.end(token)
        }
    }
}
