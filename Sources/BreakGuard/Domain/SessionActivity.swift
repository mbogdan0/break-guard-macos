import Foundation

enum InactiveReason: Hashable {
    case sleep, session, screenLock, screenSaver
}

// Independent system signals overlap. Waking the system alone does not mean
// the locked screen or the screen saver has become available to the user.
struct SessionActivity {
    private var inactiveReasons: Set<InactiveReason> = []
    var isInactive: Bool { !inactiveReasons.isEmpty }

    // Returns true only on an active/inactive edge.
    mutating func set(_ reason: InactiveReason, inactive: Bool) -> Bool {
        let wasInactive = isInactive
        if inactive {
            inactiveReasons.insert(reason)
        } else {
            inactiveReasons.remove(reason)
        }
        return wasInactive != isInactive
    }
}
