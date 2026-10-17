import SwiftUI

struct AboutSettingsView: View {
    private static let authorWebsiteURL = URL(string: "https://mbogdan0.github.io/")!
    private static let sourceCodeURL = URL(string: "https://github.com/mbogdan0/break-guard-macos")!

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BreakGuard").font(.headline)
                    Text(Self.versionText).foregroundStyle(.secondary)
                }
                Spacer()
            }
            SettingsLinkRow(title: "Website", systemImage: "globe",
                            visibleAddress: "mbogdan0.github.io", destination: Self.authorWebsiteURL)
            SettingsLinkRow(title: "Source code", systemImage: "chevron.left.forwardslash.chevron.right",
                            visibleAddress: "GitHub", destination: Self.sourceCodeURL)
            Text(Self.copyrightText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
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
