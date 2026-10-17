import SwiftUI

struct WorkingHoursSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Set working hours", isOn: appState.settingBinding(\.workingHoursEnabled))
            } footer: {
                Text(appState.settings.harderToSkipBreaks
                     ? "Outside these hours, a reminder helps you wind down."
                     : "Outside these hours, the menu bar timer turns yellow.")
            }
            if appState.settings.workingHoursEnabled {
                categorySection("Weekdays", keyPath: \.weekdayWorkingHours)
                categorySection("Weekends", keyPath: \.weekendWorkingHours)
            }
        }
        .formStyle(.grouped)
    }

    private func categorySection(_ title: String, keyPath: WritableKeyPath<AppSettings, WorkingHoursRange>) -> some View {
        let range = appState.settings[keyPath: keyPath]
        return Section(title) {
            Toggle("Track these days", isOn: appState.settingBinding(keyPath.appending(path: \.enabled)))
            if range.enabled {
                DatePicker("From", selection: appState.timeOfDayBinding(keyPath.appending(path: \.startMinutes)),
                           displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: appState.timeOfDayBinding(keyPath.appending(path: \.endMinutes)),
                           displayedComponents: .hourAndMinute)
            }
        }
    }
}
