import SwiftUI

struct SystemSettingsView: View {
    private static let authorWebsiteURL = URL(string: "https://mbogdan0.github.io/")!
    private static let sourceCodeURL = URL(string: "https://github.com/mbogdan0/break-guard-macos")!

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

            Section("About") {
                HStack(spacing: 10) {
                    Label("Author", systemImage: "person")
                    Spacer()
                    Text("Bohdan Melnichenko")
                        .foregroundStyle(.secondary)
                }
                linkRow(
                    title: "Personal Website",
                    systemImage: "globe",
                    visibleAddress: "mbogdan0.github.io",
                    destination: Self.authorWebsiteURL
                )
                linkRow(
                    title: "Source Code",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    visibleAddress: "github.com/mbogdan0",
                    destination: Self.sourceCodeURL
                )
            }
        }
        .formStyle(.grouped)
    }

    private func linkRow(
        title: String,
        systemImage: String,
        visibleAddress: String,
        destination: URL
    ) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
            Spacer()
            Link(visibleAddress, destination: destination)
                .buttonStyle(.link)
        }
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
