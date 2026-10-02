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
                Text("Outside your working hours the menu bar counter turns yellow as a reminder to wind down. The red pre-break warning always takes priority.\n\n\(pressureFootnote(subject: "outside these hours"))")
                    .foregroundStyle(.secondary)
            }

            categorySection("Weekdays", keyPath: \.weekdayWorkingHours)
            categorySection("Weekends", keyPath: \.weekendWorkingHours)

            scheduledBreakSection
        }
        .formStyle(.grouped)
    }

    // The one section on this tab that does nothing without harder mode, so it
    // says so where it can be read rather than only in the footer.
    private var scheduledBreakSection: some View {
        let range = appState.settings.scheduledBreak
        return Section {
            Toggle("Enabled", isOn: appState.settingBinding(\.scheduledBreak.enabled))
            DatePicker(
                "Start",
                selection: appState.timeOfDayBinding(\.scheduledBreak.startMinutes),
                displayedComponents: .hourAndMinute
            )
            .disabled(!range.enabled)
            DatePicker(
                "End",
                selection: appState.timeOfDayBinding(\.scheduledBreak.endMinutes),
                displayedComponents: .hourAndMinute
            )
            .disabled(!range.enabled)
        } header: {
            Text("Scheduled Break")
        } footer: {
            Text("A daily rest window on weekdays only. \(pressureFootnote(subject: "inside this window"))")
                .foregroundStyle(.secondary)
        }
    }

    private func pressureFootnote(subject: String) -> String {
        appState.settings.harderToSkipBreaks
            ? "With Harder to skip breaks on, a reminder appears \(subject). Hold its dismiss button for \(formatDurationPhrase(BreakPressure.dismissHoldDuration)) to hide it for \(formatDurationPhrase(BreakPressure.cardReturnInterval))."
            : "Turn on Harder to skip breaks (General) to show a recurring reminder \(subject)."
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
