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

    func minuteBinding(
        _ keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { Int(self.settings[keyPath: keyPath] / 60) },
            set: { newValue in
                var updated = self.settings
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                updated[keyPath: keyPath] = TimeInterval(clamped * 60)
                self.updateSettings(updated)
            }
        )
    }
}
