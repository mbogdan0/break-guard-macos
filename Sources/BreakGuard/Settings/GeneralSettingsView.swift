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
                if advancedExpanded {
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
                    taperingRows
                    HStack {
                        Spacer()
                        Button("Restore Defaults") {
                            appState.restoreDefaultSettings()
                        }
                    }
                }
            } header: {
                advancedHeader
            } footer: {
                if advancedExpanded {
                    Text("The warning appears this long before a break is due. Postponing an overdue break waits the first duration; postponing again waits the second. Tapering never shortens a session below the floor, and a long enough pause starts the day over. Restore Defaults resets every setting on every tab.")
                        .foregroundStyle(.secondary)
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

    private var advancedHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                advancedExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Text("Advanced")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Only meaningful for the Tapering pace; kept visible but dimmed
    // otherwise so the knobs are discoverable.
    @ViewBuilder private var taperingRows: some View {
        let isTapering = appState.settings.focusPace == .tapering
        LabeledContent("Tapering floor") {
            HStack(spacing: 6) {
                Text("\(appState.settings.taperingFloorPercent)%")
                    .monospacedDigit()
                Stepper(
                    "Tapering floor",
                    value: appState.settingBinding(\.taperingFloorPercent),
                    in: SettingsRange.taperingFloorPercent,
                    step: 5
                )
                .labelsHidden()
            }
        }
        .disabled(!isTapering)
        LabeledContent("Tapering day resets after") {
            HStack(spacing: 6) {
                Text(hoursText(appState.settings.taperingResetGap))
                    .monospacedDigit()
                Stepper(
                    "Tapering day resets after",
                    value: appState.hoursBinding(\.taperingResetGap, range: SettingsRange.taperingResetGapHours),
                    in: SettingsRange.taperingResetGapHours
                )
                .labelsHidden()
            }
        }
        .disabled(!isTapering)
    }

    private func hoursText(_ interval: TimeInterval) -> String {
        let hours = Int((interval / 3600).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
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
                settings.workInterval * FocusPace.taperingMultiplier(
                    sessionsCompleted: 16,
                    floor: settings.taperingFloorFraction
                )
            )
            let floor = formatDurationPhrase(settings.workInterval * settings.taperingFloorFraction)
            let gap = hoursText(settings.taperingResetGap)
            pace = "Each focus gets a little shorter as the day goes on: "
                + "\(effective) shrinks to about \(after8h) after 16 sessions, "
                + "leveling off near \(floor). A \(gap)+ pause starts the day over."
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
