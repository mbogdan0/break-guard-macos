import SwiftUI

struct SystemSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Notifications") {
                SettingsStatusRow(
                    title: "Permission",
                    systemImage: "bell",
                    status: appState.notificationAccessStatus.description,
                    showsSettingsButton: appState.notificationAccessStatus.needsSettingsLink,
                    action: appState.openNotificationSettings
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
                Toggle("Update seconds every 10 seconds", isOn: appState.settingBinding(\.coarseSecondsInMenuBar))
                    .disabled(!appState.settings.showSecondsInMenuBar)
                    .padding(.leading, 20)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("A calmer countdown: seconds stay visible but tick only once every 10 seconds.")
                    .foregroundStyle(.secondary)
            }

            Section("Login") {
                Toggle("Launch at login", isOn: appState.settingBinding(\.launchAtLogin))
                SettingsStatusRow(
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
}
