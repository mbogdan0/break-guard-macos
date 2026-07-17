import SwiftUI

struct WorkingHoursSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Highlight time outside working hours",
                    isOn: appState.settingBinding(\.workingHoursEnabled)
                )
            } footer: {
                Text("Outside your working hours the menu bar counter turns yellow as a reminder to wind down. The red pre-break warning always takes priority.")
                    .foregroundStyle(.secondary)
            }

            categorySection("Weekdays", keyPath: \.weekdayWorkingHours)
            categorySection("Weekends", keyPath: \.weekendWorkingHours)
        }
        .formStyle(.grouped)
    }

    private func categorySection(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, WorkingHoursRange>
    ) -> some View {
        let range = appState.settings[keyPath: keyPath]
        return Section {
            Toggle("Enabled", isOn: appState.settingBinding(keyPath.appending(path: \.enabled)))
            DatePicker(
                "Start",
                selection: appState.timeOfDayBinding(keyPath.appending(path: \.startMinutes)),
                displayedComponents: .hourAndMinute
            )
            .disabled(!range.enabled)
            DatePicker(
                "End",
                selection: appState.timeOfDayBinding(keyPath.appending(path: \.endMinutes)),
                displayedComponents: .hourAndMinute
            )
            .disabled(!range.enabled)
        } header: {
            Text(title)
        } footer: {
            if title == "Weekends" {
                Text("Hours are same-day ranges; an end time at or before the start is moved after it. Weekend days follow the system calendar.")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.settings.workingHoursEnabled)
    }
}
