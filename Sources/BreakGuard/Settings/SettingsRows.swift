import SwiftUI

// Labeled row that opens a URL, e.g. "Source Code — github.com/mbogdan0".
struct SettingsLinkRow: View {
    let title: String
    let systemImage: String
    let visibleAddress: String
    let destination: URL

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
            Spacer()
            Link(visibleAddress, destination: destination)
                .buttonStyle(.link)
        }
    }
}

// Labeled read-only status row with an optional "Open Settings…" escape hatch
// for states the app cannot fix itself (permissions, login approval).
struct SettingsStatusRow: View {
    let title: String
    let systemImage: String
    let status: String
    var showsSettingsButton = false
    var action: () -> Void = {}

    var body: some View {
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
