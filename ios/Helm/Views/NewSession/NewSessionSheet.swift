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

    var body: some View {
        NavigationStack {
            Form {
                Section("Harness") {
                    HarnessGrid(harnesses: store.harnesses, selection: $harnessId)
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    if let h = harness, h.supportsProfiles {
                        Picker("Profile", selection: $profile) {
                            Text("Default").tag("")
                            ForEach(h.profiles, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                Section("Working directory") {
                    NavigationLink {
                        DirectoryPicker(selection: $cwd)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent)
                                Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                        }
                    }
                }

                Section {
                    Picker("Permissions", selection: $permission) {
                        ForEach(PermissionMode.allCases) { m in
                            Label(m.label, systemImage: m.symbol).tag(m.rawValue)
                        }
                    }
                    modelField
                } header: {
                    Text("Options")
                } footer: {
                    Text("Bypass runs every tool without asking, like your terminal sessions on the box.")
                }

                Section("First message") {
                    TextField("What should we work on?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($messageFocused)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await create() } }
                            .fontWeight(.semibold)
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
            }
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
        } else {
            TextField("Model (optional)", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
