import Foundation

extension TimeInterval {
    var wholeSeconds: Int { max(0, Int(ceil(self))) }
}

func formatClock(_ interval: TimeInterval, includeHours: Bool = false) -> String {
    let seconds = interval.wholeSeconds
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if includeHours || hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

func formatMinutes(_ minutes: Int) -> String {
    let clamped = max(0, minutes)
    let hours = clamped / 60
    let mins = clamped % 60
    if hours > 0 {
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }
    return "\(clamped) min"
}

// Spoken duration for overlay buttons and settings footers. Hours matter here:
// the deep-focus pace scales a 240-minute interval up to 288.
func formatDurationPhrase(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let units: [(count: Int, name: String)] = [
        (total / 3600, "hour"),
        (total % 3600 / 60, "minute"),
        (total % 60, "second")
    ]
    let parts = units
        .filter { $0.count > 0 }
        .map { "\($0.count) \($0.name)\($0.count == 1 ? "" : "s")" }
    return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
}

// How long until something comes back, for the emergency override's cooldown:
// "3 days 5 hours", "5 hours 12 minutes", "12 minutes". Days matter here where
// they do not in formatDurationPhrase — the quota runs a week — and the two
// largest units are the whole answer, because nobody waiting three days needs
// the seconds. Anything already elapsed reads as the arrival it is.
func formatTimeUntilPhrase(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    guard total >= 60 else { return "less than a minute" }
    let units: [(count: Int, name: String)] = [
        (total / 86400, "day"),
        (total % 86400 / 3600, "hour"),
        (total % 3600 / 60, "minute")
    ]
    // Skip past the empty leading units, keep the two that follow, and drop a
    // zero if one landed in second place — "3 days" rather than "3 days 0
    // hours". Never reorders: a smaller unit can only ever be dropped, so the
    // result stays an underestimate of the wait, never an overestimate.
    let parts = units
        .drop { $0.count == 0 }
        .prefix(2)
        .filter { $0.count > 0 }
        .map { "\($0.count) \($0.name)\($0.count == 1 ? "" : "s")" }
    return parts.joined(separator: " ")
}

// Compact duration for space-constrained controls like the overlay's
// postpone buttons: "2m 20s", "15m", "1h 30m".
func formatDurationCompact(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let units: [(count: Int, suffix: String)] = [
        (total / 3600, "h"),
        (total % 3600 / 60, "m"),
        (total % 60, "s")
    ]
    let parts = units
        .filter { $0.count > 0 }
        .map { "\($0.count)\($0.suffix)" }
    return parts.isEmpty ? "0s" : parts.joined(separator: " ")
}

// mm:ss entry for the settings timing fields. A bare number keeps the old
// minutes-only habit working: "30" is 30 minutes, "0:30" is 30 seconds.
struct DurationFieldStyle: ParseableFormatStyle {
    var parseStrategy: DurationFieldStrategy { DurationFieldStrategy() }

    func format(_ value: Int) -> String {
        let seconds = max(0, value)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct DurationFieldStrategy: ParseStrategy {
    func parse(_ value: String) throws -> Int {
        guard let seconds = parseDurationField(value) else {
            throw DurationFieldError.invalid
        }
        return seconds
    }
}

enum DurationFieldError: Error {
    case invalid
}

func parseDurationField(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    switch parts.count {
    case 1:
        guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        return minutes * 60
    case 2:
        guard let minutes = Int(parts[0]), minutes >= 0,
              parts[1].count <= 2, let seconds = Int(parts[1]),
              (0...59).contains(seconds)
        else { return nil }
        return minutes * 60 + seconds
    default:
        return nil
    }
}
