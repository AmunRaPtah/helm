import SwiftUI

struct NewSessionSheet: View {
    var onCreated: (Session) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("helm.lastHarness") private var harnessId = "claude"
    @AppStorage("helm.lastProfile") private var profile = ""
    @AppStorage("helm.lastPermission") private var permission = PermissionMode.bypass.rawValue
    @AppStorage("helm.lastCwd") private var cwd = "/root/projects"
    @State private var model = ""
    @State private var text = ""
    @State private var creating = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var harness: Harness? { store.harnesses.first { $0.id == harnessId } }

    private var cwdName: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HarnessGrid(harnesses: store.harnesses, selection: $harnessId)
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    if let h = harness, h.supportsProfiles {
                        Picker("Profile", selection: $profile) {
                            Text("Default").tag("")
                            ForEach(h.profiles, id: \.self) { Text($0).tag($0) }
                        }
                        .foregroundStyle(HelmColor.textPrimary)
                    }
                } header: {
                    HelmSectionHeader(title: "Harness")
                }
                .helmRow()

                Section {
                    NavigationLink {
                        DirectoryPicker(selection: $cwd)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(cwdName)
                                    .font(HelmFont.rowTitle)
                                    .foregroundStyle(HelmColor.textPrimary)
                                Text(cwd)
                                    .font(HelmFont.mono(.caption))
                                    .foregroundStyle(HelmColor.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(HelmColor.lime.opacity(0.85))
                        }
                    }
                } header: {
                    HelmSectionHeader(title: "Working directory")
                }
                .helmRow()

                Section {
                    Picker("Permissions", selection: $permission) {
                        ForEach(PermissionMode.allCases) { m in
                            Label(m.label, systemImage: m.symbol).tag(m.rawValue)
                        }
                    }
                    .foregroundStyle(HelmColor.textPrimary)
                    modelField
                } header: {
                    HelmSectionHeader(title: "Options")
                } footer: {
                    Text("Bypass runs every tool without asking, like your terminal sessions on the box.")
                        .foregroundStyle(HelmColor.textTertiary)
                }
                .helmRow()

                Section {
                    TextField("What should we work on?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($messageFocused)
                        .foregroundStyle(HelmColor.textPrimary)
                } header: {
                    HelmSectionHeader(title: "First message")
                }
                .helmRow()

                if let error {
                    Section {
                        Label {
                            Text(error).font(HelmFont.mono(.caption))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(HelmColor.red)
                        .font(.footnote)
                    }
                    .listRowBackground(HelmColor.red.opacity(0.08))
                    .transition(.opacity)
                }
            }
            .helmScreen()
            .tint(HelmColor.lime)
            .helmAnimation(HelmMotion.spring, value: error)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(HelmColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView().tint(HelmColor.lime)
                    } else {
                        Button("Start") { Task { await create() } }
                            .fontWeight(.bold)
                            .tint(HelmColor.lime)
                            .disabled(harness?.available == false || store.harnesses.isEmpty && harnessId.isEmpty)
                    }
                }
            }
            .task {
                await store.refreshHarnesses()
                if harness == nil || harness?.available == false,
                   let first = store.harnesses.first(where: { $0.available }) {
                    harnessId = first.id
                }
                resetModel()
            }
            .onChange(of: harnessId) { _, _ in resetModel() }
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var modelField: some View {
        if let h = harness, !h.models.isEmpty {
            Picker("Model", selection: $model) {
                Text(h.defaultModel.map { "Default (\($0))" } ?? "Default").tag("")
                ForEach(h.models, id: \.self) { Text($0).tag($0) }
            }
            .foregroundStyle(HelmColor.textPrimary)
        } else {
            TextField("Model (optional)", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(HelmFont.mono(.body))
                .foregroundStyle(HelmColor.textPrimary)
        }
    }

    /// A model chosen for one harness is meaningless for another, so switching
    /// harness drops it and preselects the new harness's default_model (when it
    /// is one of the picker's entries), else the "Default" row.
    private func resetModel() {
        if let h = harness, let d = h.defaultModel, h.models.contains(d) {
            model = d
        } else {
            model = ""
        }
    }

    private func create() async {
        creating = true
        error = nil
        defer { creating = false }
        let h = harness
        let req = APIClient.NewSession(
            harness: harnessId,
            profile: (h?.supportsProfiles ?? false) && !profile.isEmpty ? profile : nil,
            model: model.trimmingCharacters(in: .whitespaces),
            cwd: cwd,
            permission: permission,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            let s = try await store.create(req)
            Haptics.send()
            onCreated(s)
        } catch {
            self.error = APIClient.describe(error)
            Haptics.warning()
        }
    }
}
