import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var advancedExpanded = false
    @State private var showsSkipHelp = false

    var body: some View {
        Form {
            Section("Your rhythm") {
                durationRow("Work for", keyPath: \.workInterval, range: SettingsRange.workInterval)
                durationRow("Rest for", keyPath: \.breakDuration, range: SettingsRange.breakDuration)
                Picker("Pace", selection: appState.settingBinding(\.focusPace)) {
                    ForEach(FocusPace.allCases, id: \.self) { pace in
                        Text(pace.title).tag(pace)
                    }
                }
                Text(paceHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("During breaks") {
                Toggle("Encourage a little more rest", isOn: appState.settingBinding(\.encourageLongBreaks))
                    .help("Gentle messages and rewards appear after the required rest is done.")
            }

            Section {
                Toggle("Harder to skip breaks", isOn: harderToSkipBreaksBinding)
                if appState.settings.harderToSkipBreaks {
                    Stepper("Daily skips: \(appState.settings.dailySkipLimit)",
                            value: appState.settingBinding(\.dailySkipLimit),
                            in: SettingsRange.dailySkipLimit)
                    LabeledContent("Left today", value: "\(appState.dailySkipsRemaining)")
                }
            } header: {
                HStack {
                    Text("Skipping")
                    Spacer()
                    Button { showsSkipHelp.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How skipping works")
                    .popover(isPresented: $showsSkipHelp) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("How skipping works").font(.headline)
                            Text("Harder mode allows one extension or postponement per cycle, within your daily limit. Zero disables regular skips. Skips made before enabling this mode count too.")
                            Text("The limit resets at midnight. Confirmation waits are longer, and reminders appear outside working hours.")
                            Text("Turning this mode off or keeping weaker settings requires a timed confirmation. Emergency override remains available once every 7 days.")
                        }
                        .font(.callout)
                        .padding(20)
                        .frame(width: 340)
                    }
                }
            } footer: {
                if appState.settings.harderToSkipBreaks {
                    Text("One skip per cycle. Your daily limit resets at midnight.")
                }
            }

            Section("During calls") {
                Toggle("Wait while the camera is in use", isOn: appState.settingBinding(\.holdBreaksWhileOnCamera))
                Toggle("Wait while the microphone is in use", isOn: appState.settingBinding(\.holdBreaksWhileMicrophoneInUse))
                    .disabled(!MicrophoneUsageReader.isSupported)
                    .help("Requires macOS 14.2. Includes recording and dictation. No audio is recorded.")
            }

            Section {
                DisclosureGroup("More options", isExpanded: $advancedExpanded) {
                    durationRow("Warn before", keyPath: \.warningLeadTime, range: SettingsRange.warningLeadTime)
                    durationRow("Short postponement", keyPath: \.firstPostponeDuration, range: SettingsRange.postponeDuration)
                    durationRow("Long postponement", keyPath: \.secondPostponeDuration, range: SettingsRange.postponeDuration)
                    if appState.settings.focusPace == .tapering {
                        Stepper("Reset tapering after \(Int(appState.settings.taperingResetGap / 3600)) hours",
                                value: appState.hoursBinding(\.taperingResetGap, range: SettingsRange.taperingResetGapHours),
                                in: SettingsRange.taperingResetGapHours)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private var harderToSkipBreaksBinding: Binding<Bool> {
        Binding(get: { appState.settings.harderToSkipBreaks }, set: { value in
            DispatchQueue.main.async { appState.setHarderToSkipBreaks(value) }
        })
    }

    private var paceHint: String {
        switch appState.settings.focusPace {
        case .normal:
            return "Your chosen work interval, every cycle."
        case .moreBreaks, .deepFocus:
            return "Next cycle: \(formatDurationPhrase(appState.settings.effectiveWorkInterval)) of focus."
        case .tapering:
            let interval = appState.settings.effectiveWorkInterval(taperedFocus: appState.taperedFocusSeconds)
            return "Shorter work intervals as the day goes on. Next cycle: \(formatDurationPhrase(interval))."
        }
    }

    private func durationRow(_ title: String, keyPath: WritableKeyPath<AppSettings, TimeInterval>,
                             range: ClosedRange<Int>) -> some View {
        let binding = appState.secondsBinding(keyPath, range: range)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: binding, format: DurationFieldStyle())
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .help("Minutes and seconds (mm:ss). A plain number means minutes.")
                Stepper(title, value: binding, in: range, step: 60).labelsHidden()
            }
        }
    }
}
