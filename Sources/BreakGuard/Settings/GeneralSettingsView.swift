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
                Text("Durations are mm:ss. A plain number means minutes.")
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
                Toggle("Harder to skip breaks", isOn: appState.settingBinding(\.harderToSkipBreaks))
                SettingsStatusRow(
                    title: "Emergency override",
                    systemImage: "exclamationmark.shield",
                    status: emergencyOverrideStatusText
                )
            } header: {
                Text("Skipping Breaks")
            } footer: {
                Text("One extension per cycle, then a doubled hold to postpone. The override, at the foot of a break overlay, buys \(formatDurationPhrase(EmergencyOverride.focusGrant)) once every 7 days.")
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
                    Text("Restore Defaults resets every setting on every tab.")
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

    // Only meaningful for the Tapering pace. The knob stays visible but dimmed
    // so it is discoverable; the live status has nothing to say when the pace
    // is off, so it is hidden outright.
    @ViewBuilder private var taperingRows: some View {
        let isTapering = appState.settings.focusPace == .tapering
        if isTapering {
            LabeledContent("Tapering now") {
                Text(taperingStatusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        LabeledContent("Tapering resets after") {
            HStack(spacing: 6) {
                Text(hoursText(appState.settings.taperingResetGap))
                    .monospacedDigit()
                Stepper(
                    "Tapering resets after",
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

    // The penalty in force right now, plus the reset. While focus is running
    // there is no gap yet, so no reset moment exists to report — the honest
    // always-computable answer is when it would land if you stopped now.
    private var taperingStatusText: String {
        let penalty = FocusPace.taperingPenalty(forFocus: appState.taperedFocusSeconds)
        let resetsAt = Date().addingTimeInterval(appState.settings.taperingResetGap)
        let amount = penalty < 1 ? "None yet" : "−\(formatDurationCompact(penalty))"
        return "\(amount) · resets \(DateFormatter.breakGuardTime.string(from: resetsAt)) if you stop"
    }

    private var emergencyOverrideStatusText: String {
        guard let availableAt = appState.emergencyOverrideAvailableAt,
              Date() < availableAt else { return "Available" }
        return "Used · back on \(DateFormatter.breakGuardDateTime.string(from: availableAt))"
    }

    // One line per pace. The Tapering knobs and its live penalty live in
    // Advanced, so this only has to convey the shape of the rule.
    private var focusPaceFooter: String {
        let settings = appState.settings
        let effective = formatDurationPhrase(settings.effectiveWorkInterval)
        let pace: String
        switch settings.focusPace {
        case .normal:
            pace = "Work interval as set."
        case .moreBreaks:
            pace = "Work interval −20%: \(effective)."
        case .deepFocus:
            pace = "Work interval +20%: \(effective)."
        case .tapering:
            let after8h = formatDurationPhrase(
                settings.effectiveWorkInterval(taperedFocus: 8 * 3600)
            )
            pace = "Every focused minute trims a second off the next window — "
                + "\(effective) becomes about \(after8h) after an 8-hour day."
        }
        return pace + " Applies from the next cycle."
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
