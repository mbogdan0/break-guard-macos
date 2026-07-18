import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var advancedExpanded = false

    var body: some View {
        Form {
            Section {
                durationRow("Work interval", keyPath: \.workInterval, range: SettingsRange.workInterval)
                durationRow("Break duration", keyPath: \.breakDuration, range: SettingsRange.breakDuration)
            } header: {
                Text("Timing")
            } footer: {
                Text("Durations are minutes:seconds — 2:30 is two and a half minutes. A plain number means minutes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Focus pace", selection: appState.settingBinding(\.focusPace)) {
                    ForEach(FocusPace.allCases, id: \.self) { pace in
                        Text(pace.title).tag(pace)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Focus Pace")
            } footer: {
                Text(focusPaceFooter)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    durationRow(
                        "Warning lead time",
                        keyPath: \.warningLeadTime,
                        range: SettingsRange.warningLeadTime
                    )
                    durationRow(
                        "First postponement",
                        keyPath: \.firstPostponeDuration,
                        range: SettingsRange.postponeDuration
                    )
                    durationRow(
                        "Second postponement",
                        keyPath: \.secondPostponeDuration,
                        range: SettingsRange.postponeDuration
                    )
                }
            } footer: {
                if advancedExpanded {
                    Text("The warning appears this long before a break is due. Postponing an overdue break waits the first duration; postponing again waits the second.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        appState.restoreDefaultSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // SwiftUI gives initial key focus to the first text field (work
            // interval), which opens the pane with its value selected for
            // editing. Nothing should be focused until the user clicks.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var focusPaceFooter: String {
        let settings = appState.settings
        let effective = formatDurationPhrase(settings.effectiveWorkInterval)
        let pace: String
        switch settings.focusPace {
        case .normal:
            pace = "Uses the work interval as set."
        case .moreBreaks:
            pace = "Work interval −20%: \(effective)."
        case .deepFocus:
            pace = "Work interval +20%: \(effective)."
        case .tapering:
            let after8h = formatDurationPhrase(
                settings.workInterval * FocusPace.taperingMultiplier(sessionsCompleted: 16)
            )
            let floor = formatDurationPhrase(settings.workInterval * FocusPace.taperingFloor)
            pace = "Each focus gets a little shorter as the day goes on: "
                + "\(effective) shrinks to about \(after8h) after 16 sessions, "
                + "leveling off near \(floor). A 6+ hour pause starts the day over."
        }
        return pace + " Takes effect from the next cycle."
    }

    // The stepper nudges by a minute and leaves the seconds component alone;
    // the field is where an exact value gets typed.
    private func durationRow(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> some View {
        let binding = appState.secondsBinding(keyPath, range: range)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: binding, format: DurationFieldStyle())
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper(title, value: binding, in: range, step: 60)
                    .labelsHidden()
            }
        }
    }
}
