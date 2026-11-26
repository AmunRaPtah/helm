import SwiftUI

/// Runs a quick action with an optional confirm and shows its output.
@Observable
final class ActionRunner {
    var running: QuickAction?
    var result: ShellResult?
    var duration: Double?
    var presented = false
    var pendingConfirm: QuickAction?

    func trigger(_ a: QuickAction, api: APIClient) {
        if a.confirm { pendingConfirm = a } else { Task { await run(a, api: api) } }
    }

    @MainActor
    func run(_ a: QuickAction, api: APIClient) async {
        Haptics.tap()
        running = a
        result = nil
        duration = nil
        presented = true
        let start = Date()
        do {
            let r = try await api.boxRunAction(a)
            result = r
            r.ok ? Haptics.success() : Haptics.warning()
        } catch {
            result = ShellResult(json: .object(["ok": .bool(false), "exit": .number(-1),
                                                "output": .string(APIClient.describe(error))]))
            Haptics.warning()
        }
        duration = Date().timeIntervalSince(start)
        running = nil
    }
}

/// Modifier that attaches the confirm dialog and output sheet for an ActionRunner.
struct ActionRunnerHost: ViewModifier {
    @Bindable var runner: ActionRunner
    let api: APIClient
    @State private var lastTitle = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Run “\(runner.pendingConfirm?.title ?? "")”?",
                                isPresented: Binding(get: { runner.pendingConfirm != nil },
                                                     set: { if !$0 { runner.pendingConfirm = nil } }),
                                titleVisibility: .visible) {
                Button("Run", role: .destructive) {
                    if let a = runner.pendingConfirm { Task { await runner.run(a, api: api) } }
                }
            } message: {
                Text(runner.pendingConfirm?.cmd ?? "").font(.caption.monospaced())
            }
            .sheet(isPresented: $runner.presented) {
                CommandOutputSheet(title: runner.running?.title ?? lastTitle, result: runner.result,
                                   running: runner.running != nil, duration: runner.duration)
            }
            .onChange(of: runner.running) { _, a in if let a { lastTitle = a.title } }
    }
}

extension View {
    func actionRunner(_ runner: ActionRunner, api: APIClient) -> some View {
        modifier(ActionRunnerHost(runner: runner, api: api))
    }
}

/// Manage the quick-action list (stored server-side in ~/.helm/actions.json).
struct ActionsView: View {
    @Environment(AppStore.self) private var store
    @State private var actions: [QuickAction] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var editing: QuickAction?
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
            }
            Section {
                if !loaded { ForEach(0..<4, id: \.self) { _ in SkeletonRow().helmRow() } }
                ForEach(actions) { a in
                    HStack(spacing: HelmSpace.md) {
                        Image(systemName: a.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(a.confirm ? HelmColor.amber : HelmColor.lime)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(HelmColor.raisedHigh))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(HelmFont.rowTitle).foregroundStyle(HelmColor.textPrimary)
                            Text(a.cmd).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary).lineLimit(1)
                        }
                        Spacer()
                        Button { runner.trigger(a, api: store.api) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(HelmSecondaryButtonStyle(tint: HelmColor.lime))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = a }
                    .helmRow()
                }
                .onDelete { idx in
                    actions.remove(atOffsets: idx)
                    Task { await save() }
                }
                .onMove { from, to in
                    actions.move(fromOffsets: from, toOffset: to)
                    Task { await save() }
                }
            } header: {
                HelmSectionHeader(title: "Quick actions", trailing: "\(actions.count)")
            } footer: {
                Text("Tap to edit, ▶ to run. Commands run as root through bash on the box.")
                    .font(.caption2).foregroundStyle(HelmColor.textTertiary)
            }
        }
        .helmScreen()
        .navigationTitle("Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = QuickAction() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New action")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { a in
            ActionEditor(action: a, isNew: !actions.contains { $0.id == a.id }) { updated in
                if let i = actions.firstIndex(where: { $0.id == updated.id }) { actions[i] = updated }
                else { actions.append(updated) }
                Task { await save() }
            }
        }
        .actionRunner(runner, api: store.api)
    }

    private func load() async {
        guard store.config.isConfigured else { return }
        do { actions = try await store.api.boxActions(); loaded = true; error = nil }
        catch is CancellationError {}
        catch { self.error = APIClient.describe(error) }
    }

    private func save() async {
        do { actions = try await store.api.boxSaveActions(actions); Haptics.success(); error = nil }
        catch { self.error = APIClient.describe(error) }
    }
}

private struct ActionEditor: View {
    @State var action: QuickAction
    let isNew: Bool
    let onSave: (QuickAction) -> Void
    @Environment(\.dismiss) private var dismiss

    private let icons = ["bolt", "heart.text.square", "exclamationmark.triangle", "internaldrive", "memorychip",
                         "shippingbox", "trash", "arrow.clockwise", "network", "lock.shield", "chart.bar", "terminal"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Disk report", text: $action.title)
                }
                Section("Command") {
                    TextEditor(text: $action.cmd)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(icons, id: \.self) { i in
                            Image(systemName: i)
                                .frame(width: 36, height: 36)
                                .foregroundStyle(action.icon == i ? HelmColor.onLime : HelmColor.textSecondary)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(action.icon == i ? HelmColor.lime : HelmColor.raisedHigh))
                                .onTapGesture { action.icon = i; Haptics.tap() }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("Ask before running", isOn: $action.confirm)
                    Stepper("Timeout \(action.timeout)s", value: $action.timeout, in: 10...900, step: 10)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HelmColor.obsidian)
            .navigationTitle(isNew ? "New action" : "Edit action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(action); dismiss() }
                        .disabled(action.title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || action.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
