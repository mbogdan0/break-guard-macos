import SwiftUI

struct FocusTagsSettingsView: View {
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
