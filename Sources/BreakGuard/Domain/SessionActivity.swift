import Foundation

enum InactiveReason: Hashable {
    case sleep, session, screenLock, screenSaver
}

// Independent system signals overlap. Waking the system alone does not mean
// the locked screen or the screen saver has become available to the user.
struct SessionActivity {
    private var inactiveReasons: Set<InactiveReason> = []
    private var sleepStartedAt: Date?
    private(set) var longestSleepDuration: TimeInterval = 0

    var isInactive: Bool { !inactiveReasons.isEmpty }

    // Returns true only on an active/inactive edge.
    mutating func set(_ reason: InactiveReason, inactive: Bool, at now: Date = Date()) -> Bool {
        let wasInactive = isInactive
        if inactive, !wasInactive { longestSleepDuration = 0 }
        if reason == .sleep {
            if inactive, sleepStartedAt == nil {
                sleepStartedAt = now
            } else if !inactive, let start = sleepStartedAt {
                longestSleepDuration = max(longestSleepDuration, now.timeIntervalSince(start))
                sleepStartedAt = nil
            }
        }
        if inactive {
            inactiveReasons.insert(reason)
        } else {
            inactiveReasons.remove(reason)
        }
        return wasInactive != isInactive
    }
}
