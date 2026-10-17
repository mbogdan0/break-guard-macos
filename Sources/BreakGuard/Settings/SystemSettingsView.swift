import SwiftUI

struct SystemSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var aboutExpanded = false

    var body: some View {
        Form {
            Section("Notifications") {
                SettingsStatusRow(
                    title: "Permission",
                    systemImage: "bell",
                    status: appState.notificationAccessStatus.description
                )
                Toggle("Play notification sound", isOn: appState.settingBinding(\.notificationSound))
                HStack {
                    if appState.notificationAccessStatus.needsSettingsLink {
                        Button("Open Notification Settings…") {
                            appState.openNotificationSettings()
                        }
                    } else {
                        Button("Send Test Notification") {
                            appState.sendTestNotification()
                        }
                        .disabled(!appState.notificationAccessStatus.canSendTest)
                    }
                    Spacer()
                    if let message = appState.notificationTestMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Show seconds in the menu bar", isOn: appState.settingBinding(\.showSecondsInMenuBar))
                if appState.settings.showSecondsInMenuBar {
                    Toggle("Calmer countdown", isOn: appState.settingBinding(\.coarseSecondsInMenuBar))
                        .help("Update seconds every 10 seconds.")
                }
            } header: {
                Text("Menu Bar")
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: appState.settingBinding(\.launchAtLogin))
                SettingsStatusRow(
                    title: "Status",
                    systemImage: "power",
                    status: appState.loginStatusDescription,
                    showsSettingsButton: appState.loginStatusDescription == "Requires Approval",
                    action: appState.openLoginItemSettings
                )
            }
            Section {
                SettingsDisclosureRow(title: "About BreakGuard", isExpanded: $aboutExpanded)
                if aboutExpanded {
                    AboutSettingsView()
                }
            }
        }
        .formStyle(.grouped)
    }
}
