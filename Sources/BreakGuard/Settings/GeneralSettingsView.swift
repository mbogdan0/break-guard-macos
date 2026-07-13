import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Timing") {
                minuteRow("Work interval", keyPath: \.workInterval, range: 1...240)
                minuteRow("Break duration", keyPath: \.breakDuration, range: 1...60)
                minuteRow("Warning lead time", keyPath: \.warningLeadTime, range: 0...30)
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

            Section("Postponement") {
                minuteRow("First postponement", keyPath: \.firstPostponeDuration, range: 1...120)
                minuteRow("Second postponement", keyPath: \.secondPostponeDuration, range: 1...120)
            }

            Section {
                Toggle("Show seconds in the menu bar", isOn: appState.settingBinding(\.showSecondsInMenuBar))
                Toggle("Update seconds every 10 seconds", isOn: appState.settingBinding(\.coarseSecondsInMenuBar))
                    .disabled(!appState.settings.showSecondsInMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("A calmer countdown: seconds stay visible but tick only once every 10 seconds.")
                    .foregroundStyle(.secondary)
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
    }

    private var focusPaceFooter: String {
        let settings = appState.settings
        let effective = formatMinutes(Int(settings.effectiveWorkInterval / 60))
        let pace: String
        switch settings.focusPace {
        case .normal:
            pace = "Uses the work interval as set."
        case .moreBreaks:
            pace = "Work interval −20%: \(effective)."
        case .deepFocus:
            pace = "Work interval +20%: \(effective)."
        }
        return pace + " Takes effect from the next cycle."
    }

    private func minuteRow(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> some View {
        let binding = appState.minuteBinding(keyPath, range: range)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: binding, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("min")
                    .foregroundStyle(.secondary)
                Stepper(title, value: binding, in: range)
                    .labelsHidden()
            }
        }
    }
}
