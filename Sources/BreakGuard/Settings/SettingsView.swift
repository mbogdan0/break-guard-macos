import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            FocusTagsSettingsView(appState: appState)
                .tabItem {
                    Label("Focus Tags", systemImage: "tag")
                }

            SystemSettingsView(appState: appState)
                .tabItem {
                    Label("System", systemImage: "gearshape.2")
                }

            StatisticsSettingsView(appState: appState)
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }
        }
        .frame(minWidth: 540, minHeight: 560)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Timing") {
                minuteRow("Work interval", keyPath: \.workInterval, range: 1...240)
                minuteRow("Break duration", keyPath: \.breakDuration, range: 1...60)
                minuteRow("Warning lead time", keyPath: \.warningLeadTime, range: 0...30)
            }

            Section("Postponement") {
                minuteRow("First postponement", keyPath: \.firstPostponeDuration, range: 1...120)
                minuteRow("Second postponement", keyPath: \.secondPostponeDuration, range: 1...120)
            }

            Section("Menu Bar") {
                Toggle("Show seconds in the menu bar", isOn: appState.settingBinding(\.showSecondsInMenuBar))
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

// MARK: - Focus Tags

private struct FocusTagsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var newTagName = ""
    @State private var draftNames: [String: String] = [:]
    @State private var validationMessage: String?
    @State private var pendingDeletion: FocusTag?

    var body: some View {
        Form {
            Section {
                Toggle("Ask for a focus tag after each break", isOn: appState.settingBinding(\.focusTagsEnabled))
            } footer: {
                Text("When off, the break screen ends with a single Continue Working button and focus time is not recorded.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if appState.focusTags.isEmpty {
                    Text("No focus tags. Completed breaks can still be skipped.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.focusTags) { tag in
                        HStack(spacing: 8) {
                            TextField("Tag name", text: draftBinding(for: tag))
                                .labelsHidden()
                                .onSubmit { save(tag) }
                            Button("Save") { save(tag) }
                                .disabled(currentDraft(for: tag) == tag.name)
                            Button(role: .destructive) { requestDeletion(of: tag) } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete \(tag.name)")
                        }
                    }
                }
            } header: {
                Text("Focus Tags")
            } footer: {
                Text("Tags categorize where your focus time goes after each break.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField("New tag", text: $newTagName)
                        .labelsHidden()
                        .onSubmit(addTag)
                    Button("Add Tag", action: addTag)
                        .disabled(FocusTag.normalizedName(newTagName).isEmpty)
                }
            } header: {
                Text("Add Tag")
            } footer: {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("Names must be unique and no more than 24 characters.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete focus tag?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { tag in
            Button("Delete \(tag.name)", role: .destructive) {
                appState.deleteFocusTag(id: tag.id)
                draftNames.removeValue(forKey: tag.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { tag in
            Text("This also removes \(formatMinutes(appState.focusMinutes(for: tag.id))) of categorized focus time.")
        }
    }

    private func currentDraft(for tag: FocusTag) -> String {
        draftNames[tag.id] ?? tag.name
    }

    private func draftBinding(for tag: FocusTag) -> Binding<String> {
        Binding(
            get: { currentDraft(for: tag) },
            set: { draftNames[tag.id] = $0 }
        )
    }

    private func addTag() {
        if let error = appState.addFocusTag(named: newTagName) {
            validationMessage = error
        } else {
            newTagName = ""
            validationMessage = nil
        }
    }

    private func save(_ tag: FocusTag) {
        if let error = appState.renameFocusTag(id: tag.id, to: currentDraft(for: tag)) {
            validationMessage = error
        } else {
            draftNames.removeValue(forKey: tag.id)
            validationMessage = nil
        }
    }

    private func requestDeletion(of tag: FocusTag) {
        if appState.focusMinutes(for: tag.id) > 0 {
            pendingDeletion = tag
        } else {
            appState.deleteFocusTag(id: tag.id)
            draftNames.removeValue(forKey: tag.id)
        }
    }
}

// MARK: - System

private struct SystemSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Notifications") {
                statusRow(
                    title: "Permission",
                    systemImage: "bell",
                    status: appState.notificationAccessStatus.description,
                    showsSettingsButton: appState.notificationAccessStatus.needsSettingsLink,
                    action: appState.openNotificationSettings
                )
                Toggle("Play notification sound", isOn: appState.settingBinding(\.notificationSound))
                HStack {
                    if appState.notificationAccessStatus == .disabled {
                        Button("Open Notification Settings…") {
                            appState.openNotificationSettings()
                        }
                    } else {
                        Button("Send Test Notification") {
                            appState.sendTestNotification()
                        }
                        .disabled(appState.notificationAccessStatus == .checking)
                    }
                    Spacer()
                    if let message = appState.notificationTestMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Login") {
                Toggle("Launch at login", isOn: appState.settingBinding(\.launchAtLogin))
                statusRow(
                    title: "Status",
                    systemImage: "power",
                    status: appState.loginStatusDescription,
                    showsSettingsButton: appState.loginStatusDescription == "Requires Approval",
                    action: appState.openLoginItemSettings
                )
            }
        }
        .formStyle(.grouped)
    }

    private func statusRow(
        title: String,
        systemImage: String,
        status: String,
        showsSettingsButton: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
            if showsSettingsButton {
                Button("Open Settings…", action: action)
                    .buttonStyle(.link)
            }
        }
    }
}

// MARK: - Statistics

private struct StatisticsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                if appState.focusTags.isEmpty {
                    Text("No focus tags configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.focusTags) { tag in
                        statisticRow(tag.name, value: formatMinutes(appState.focusMinutes(for: tag.id)))
                    }
                }
                statisticRow("Skipped", value: formatMinutes(appState.statistics.skippedFocusMinutes))
                statisticRow("Total", value: formatMinutes(appState.statistics.totalFocusMinutes))
                    .fontWeight(.semibold)
            } header: {
                Text("Focus Time")
            } footer: {
                Text("Each completed break credits the actual focused time of that cycle.")
                    .foregroundStyle(.secondary)
            }

            Section {
                statisticRow("Current clean streak", value: "\(appState.statistics.currentCleanStreak)")
                statisticRow("Best clean streak", value: "\(appState.statistics.bestCleanStreak)")
                statisticRow("Completed breaks", value: "\(appState.statistics.completedBreaks)")
                statisticRow("Violated cycles", value: "\(appState.statistics.violatedCycles)")
                statisticRow("Total postponements", value: "\(appState.statistics.totalPostponements)")
                statisticRow("Last completed break", value: lastCompletedBreakText)
            } header: {
                Text("Break History")
            } footer: {
                Text("A clean streak grows when a full break is completed without postponing it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Statistics…", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset statistics?", isPresented: $showResetConfirmation) {
            Button("Reset Statistics", role: .destructive) {
                appState.resetStatistics()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears focus time totals, streaks, completed breaks, violations, and postponement counts.")
        }
    }

    private var lastCompletedBreakText: String {
        guard let date = appState.statistics.lastCompletedBreakDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statisticRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
        }
    }
}

// MARK: - Shared bindings

@MainActor
private extension AppState {
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
