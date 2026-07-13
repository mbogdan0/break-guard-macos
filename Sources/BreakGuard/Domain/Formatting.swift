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
