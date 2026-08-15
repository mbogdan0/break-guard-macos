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
                taperingStatusRow
            } header: {
                Text("Focus Pace")
            } footer: {
                Text(focusPaceFooter)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Harder to skip breaks", isOn: harderToSkipBreaksBinding)
                SettingsStatusRow(
                    title: "Emergency override",
                    systemImage: "exclamationmark.shield",
                    status: emergencyOverrideStatusText
                )
            } header: {
                Text("Skipping Breaks")
            } footer: {
                Text("Every skip sits through a confirmation whose button stays disabled for a moment first — \(Int(SkipConfirmGate.extendShortSeconds / 2))–\(Int(SkipConfirmGate.extendLongSeconds / 2)) seconds for Extend Focus, \(formatDurationPhrase(SkipConfirmGate.pauseUntilMorningSeconds / 2)) for Pause Until 9 AM and for quitting. Harder mode doubles every one of those, allows only one Extend Focus or postponement per cycle, and turns on the scheduled break and after-hours dimming set up on the Schedule tab. It also asks before it can be switched back off (\(formatDurationPhrase(SkipConfirmGate.disableHarderModeSeconds))), and once when you close this window having given yourself more room than you arrived with (\(formatDurationPhrase(SkipConfirmGate.loosenSettingsSeconds))). The override, at the foot of a break overlay or on a dimming reminder, buys \(formatDurationPhrase(EmergencyOverride.focusGrant)) once every 7 days.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hold breaks during camera calls", isOn: appState.settingBinding(\.holdBreaksWhileOnCamera))
            } header: {
                Text("Calls")
            } footer: {
                Text("While any app uses the camera, the countdown freezes just above the warning window so a break never interrupts a call. The held time still counts as focus, and the full warning lead runs after the call ends.")
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
                    taperingResetRow
                }
            } header: {
                advancedHeader
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

    // Not settingBinding: switching harder mode off asks first, behind a
    // countdown. The alert is dispatched rather than run inline because
    // runModal() spins a nested run loop, and doing that from inside a binding
    // setter re-enters the SwiftUI update that is still in progress.
    private var harderToSkipBreaksBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.harderToSkipBreaks },
            set: { newValue in
                DispatchQueue.main.async {
                    appState.setHarderToSkipBreaks(newValue)
                }
            }
        )
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

    // Sits with the pace picker rather than in Advanced: it is the number you
    // glance at, not a knob. Nothing to say when the pace is off, so it is
    // hidden outright rather than dimmed.
    @ViewBuilder private var taperingStatusRow: some View {
        if appState.settings.focusPace == .tapering {
            LabeledContent("Tapering now") {
                Text(taperingStatusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // Only meaningful for the Tapering pace, but the knob stays visible and
    // dimmed so it is discoverable.
    private var taperingResetRow: some View {
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
        .disabled(appState.settings.focusPace != .tapering)
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
        return "Used · back in \(formatTimeUntilPhrase(availableAt.timeIntervalSinceNow))"
    }

    // One line per pace. Tapering's live penalty is the row right above and
    // its reset knob lives in Advanced, so this only has to convey the shape
    // of the rule.
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
            // Rounded to the minute: the sentence says "about", and the exact
            // figure is one row up in "Tapering now".
            let tapered = settings.effectiveWorkInterval(taperedFocus: 8 * 3600)
            let after8h = formatDurationPhrase((tapered / 60).rounded() * 60)
            pace = "Every focused minute trims "
                + "\(FocusPace.taperingSecondsPerFocusMinute) seconds off the next window — "
                + "\(effective) becomes about \(after8h) after an 8-hour day. "
                + "Never more than \(formatDurationPhrase(FocusPace.taperingMaximumPenalty)) in total."
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
