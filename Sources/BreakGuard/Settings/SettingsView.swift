import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView(appState: appState)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            StatisticsSettingsView(appState: appState)
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }
        }
        .frame(minWidth: 560, minHeight: 600)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsGroup("Timing") {
                    minuteRow("Work interval", keyPath: \AppSettings.workInterval, range: 1...240)
                    minuteRow("Break duration", keyPath: \AppSettings.breakDuration, range: 1...60)
                    minuteRow("Warning lead time", keyPath: \AppSettings.warningLeadTime, range: 0...30)
                }

                settingsGroup("Postponement") {
                    minuteRow("First postponement", keyPath: \AppSettings.firstPostponeDuration, range: 1...120)
                    minuteRow("Second postponement", keyPath: \AppSettings.secondPostponeDuration, range: 1...120)
                }

                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Play notification sound", isOn: settingBinding(\AppSettings.notificationSound))
                        Toggle("Launch at login", isOn: settingBinding(\AppSettings.launchAtLogin))
                        Toggle("Show seconds in the menu bar", isOn: settingBinding(\AppSettings.showSecondsInMenuBar))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                FocusTagsEditor(appState: appState)

                GroupBox("System Access") {
                    VStack(spacing: 0) {
                        systemStatusRow(
                            title: "Notifications",
                            systemImage: "bell",
                            status: appState.notificationAccessStatus.description,
                            showsSettingsButton: appState.notificationAccessStatus.needsSettingsLink,
                            action: appState.openNotificationSettings
                        )
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
                        .padding(.top, 8)
                        Divider().padding(.vertical, 10)
                        systemStatusRow(
                            title: "Launch at login",
                            systemImage: "power",
                            status: appState.loginStatusDescription,
                            showsSettingsButton: appState.loginStatusDescription == "Requires Approval",
                            action: appState.openLoginItemSettings
                        )
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        appState.restoreDefaultSettings()
                    }
                }
            }
            .padding(20)
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox(title) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func minuteRow(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> some View {
        let binding = minuteBinding(keyPath, range: range)
        return GridRow {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                TextField(title, value: binding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                Text("min")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                Stepper("", value: binding, in: range)
                    .labelsHidden()
            }
        }
    }

    private func systemStatusRow(
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

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = appState.settings
                updated[keyPath: keyPath] = newValue
                appState.updateSettings(updated)
            }
        )
    }

    private func minuteBinding(
        _ keyPath: WritableKeyPath<AppSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { Int(appState.settings[keyPath: keyPath] / 60) },
            set: { newValue in
                var updated = appState.settings
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                updated[keyPath: keyPath] = TimeInterval(clamped * 60)
                appState.updateSettings(updated)
            }
        )
    }
}

private struct FocusTagsEditor: View {
    @ObservedObject var appState: AppState
    @State private var newTagName = ""
    @State private var draftNames: [String: String] = [:]
    @State private var validationMessage: String?
    @State private var pendingDeletion: FocusTag?

    var body: some View {
        GroupBox("Focus Tags") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.focusTags.isEmpty {
                    Text("No focus tags. Completed breaks can still be skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.focusTags) { tag in
                        HStack(spacing: 8) {
                            TextField("Tag name", text: draftBinding(for: tag))
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

                Divider()

                HStack(spacing: 8) {
                    TextField("New tag", text: $newTagName)
                        .onSubmit(addTag)
                    Button("Add Tag", action: addTag)
                        .disabled(FocusTag.normalizedName(newTagName).isEmpty)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Names must be unique and no more than 24 characters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
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
            Text("This also removes \(appState.focusSessionCount(for: tag.id)) categorized focus sessions.")
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
        if appState.focusSessionCount(for: tag.id) > 0 {
            pendingDeletion = tag
        } else {
            appState.deleteFocusTag(id: tag.id)
            draftNames.removeValue(forKey: tag.id)
        }
    }
}

private struct StatisticsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Focus Categories") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        if appState.focusTags.isEmpty {
                            GridRow {
                                Text("No focus tags configured")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(appState.focusTags) { tag in
                                statisticRow(tag.name, value: "\(appState.focusSessionCount(for: tag.id))")
                            }
                        }
                        statisticRow("Skipped", value: "\(appState.statistics.skippedFocusSessions)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                GroupBox("Break History") {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        statisticRow("Current clean streak", value: "\(appState.statistics.currentCleanStreak)")
                        statisticRow("Best clean streak", value: "\(appState.statistics.bestCleanStreak)")
                        statisticRow("Completed breaks", value: "\(appState.statistics.completedBreaks)")
                        statisticRow("Violated cycles", value: "\(appState.statistics.violatedCycles)")
                        statisticRow("Total postponements", value: "\(appState.statistics.totalPostponements)")
                        statisticRow("Last completed break", value: lastCompletedBreakText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                Text("A clean streak grows when a full break is completed without postponing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Reset Statistics…", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .padding(20)
        }
        .confirmationDialog("Reset statistics?", isPresented: $showResetConfirmation) {
            Button("Reset Statistics", role: .destructive) {
                appState.resetStatistics()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears focus-category totals, skipped sessions, streaks, completed breaks, violations, and postponement counts.")
        }
    }

    private var lastCompletedBreakText: String {
        guard let date = appState.statistics.lastCompletedBreakDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statisticRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .monospacedDigit()
        }
    }
}
