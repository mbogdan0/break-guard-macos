import SwiftUI

// Bindings shared by the settings tabs: every write routes through
// updateSettings so clamping and persistence stay in one place.
@MainActor
extension AppState {
    func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                self.updateSettings(updated)
            }
        )
    }

    func secondsBinding(
        _ keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { Int(self.settings[keyPath: keyPath].rounded()) },
            set: { newValue in
                var updated = self.settings
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                updated[keyPath: keyPath] = TimeInterval(clamped)
                self.updateSettings(updated)
            }
        )
    }

    // Bridges a minutes-from-midnight setting to the Date that DatePicker
    // needs, anchored to today. Only the hour and minute survive the write.
    func timeOfDayBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let startOfDay = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(
                    byAdding: .minute,
                    value: self.settings[keyPath: keyPath],
                    to: startOfDay
                ) ?? startOfDay
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var updated = self.settings
                updated[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                self.updateSettings(updated)
            }
        )
    }
}
