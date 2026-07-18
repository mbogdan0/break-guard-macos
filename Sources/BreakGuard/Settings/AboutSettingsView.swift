import SwiftUI

struct AboutSettingsView: View {
    private static let authorWebsiteURL = URL(string: "https://mbogdan0.github.io/")!
    private static let sourceCodeURL = URL(string: "https://github.com/mbogdan0/break-guard-macos")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("BreakGuard")
                        .font(.title2.bold())
                    Text(Self.versionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                HStack(spacing: 10) {
                    Label("Author", systemImage: "person")
                    Spacer()
                    Text("Bohdan Melnichenko")
                        .foregroundStyle(.secondary)
                }
                SettingsLinkRow(
                    title: "Personal Website",
                    systemImage: "globe",
                    visibleAddress: "mbogdan0.github.io",
                    destination: Self.authorWebsiteURL
                )
                SettingsLinkRow(
                    title: "Source Code",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    visibleAddress: "github.com/mbogdan0",
                    destination: Self.sourceCodeURL
                )
            } footer: {
                Text(Self.copyrightText)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // The Info.plist exists only inside the assembled .app bundle, so runs
    // via `swift run` or tests fall back to a placeholder.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else {
            return "Development build"
        }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    private static var copyrightText: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "Copyright © 2026 Bohdan Melnichenko. Personal non-commercial license."
    }
}
