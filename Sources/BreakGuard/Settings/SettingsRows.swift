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

// Keep expandable sections as normal Form rows so fields retain their spacing.
struct SettingsDisclosureRow: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

struct SettingsDurationRow: View {
    let title: String
    @Binding var seconds: Int
    let range: ClosedRange<Int>
    @State private var draft = ""
    @State private var hasEdits = false
    @FocusState private var isEditing: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: Binding(
                    get: { draft },
                    set: { draft = $0; hasEdits = true }
                ))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                    .focused($isEditing)
                    .onSubmit { commitDraft() }
                    .onExitCommand {
                        refreshDraft()
                        isEditing = false
                    }
                    .help("Enter minutes or mm:ss. Press Return or leave the field to apply. Escape cancels.")
                Stepper(title, onIncrement: { step(by: 60) }, onDecrement: { step(by: -60) })
                    .labelsHidden()
                    .fixedSize()
            }
            .controlSize(.regular)
        }
        .frame(minHeight: 32)
        .onAppear { refreshDraft() }
        .onChange(of: isEditing) { focused in
            if !focused { commitDraft() }
        }
        .onChange(of: seconds) { _ in
            if !hasEdits { refreshDraft() }
        }
        .onDisappear { commitDraft() }
    }

    private func refreshDraft() {
        draft = DurationFieldStyle().format(seconds)
        hasEdits = false
    }

    private func commitDraft() {
        guard hasEdits else { return }
        if let parsed = parseDurationField(draft) {
            seconds = min(max(parsed, range.lowerBound), range.upperBound)
        }
        refreshDraft()
    }

    private func step(by delta: Int) {
        commitDraft()
        seconds = min(max(seconds + delta, range.lowerBound), range.upperBound)
        refreshDraft()
        isEditing = false
    }
}
