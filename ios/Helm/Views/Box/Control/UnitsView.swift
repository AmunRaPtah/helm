import SwiftUI

/// All systemd services: failed first, then the watched set, then the rest.
struct UnitsView: View {
    @Environment(AppStore.self) private var store

    enum Scope: String, CaseIterable, Identifiable {
        case watched = "Watched", failed = "Failed", active = "Active", all = "All"
        var id: String { rawValue }
    }

    var initialScope: Scope = .watched
    @State private var scope: Scope = .watched
    @State private var units: [SystemdUnit] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var query = ""
    @State private var didInit = false

    private var shown: [SystemdUnit] {
        units.filter { u in
            switch scope {
            case .watched: return u.watched || u.active == "failed"
            case .failed: return u.active == "failed"
            case .active: return u.active == "active"
            case .all: return true
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            || $0.description.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s == .failed ? "Failed \(failedCount)" : s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .helmRow()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
                }
            }
            Section {
                if !loaded { ForEach(0..<8, id: \.self) { _ in SkeletonRow().helmRow() } }
                if loaded && shown.isEmpty {
                    HelmEmptyState(title: scope == .failed ? "Nothing failed" : "No units",
                                   message: scope == .failed ? "Every service is healthy." : "Nothing matches.",
                                   showMark: false, systemImage: scope == .failed ? "checkmark.seal" : "gearshape.2")
                        .helmRow()
                }
                ForEach(shown) { u in
                    NavigationLink { UnitDetailView(unit: u) } label: { UnitRow(unit: u) }
                        .helmRow()
                }
            } header: {
                HelmSectionHeader(title: "Services", trailing: loaded ? "\(shown.count)" : nil)
            }
        }
        .helmScreen()
        .navigationTitle("Services")
        .searchable(text: $query, prompt: "Unit or description")
        .refreshable { await load() }
        .task {
            if !didInit { scope = initialScope; didInit = true }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private var failedCount: Int { units.filter { $0.active == "failed" }.count }

    private func load() async {
        guard store.config.isConfigured else { return }
        do {
            units = try await store.api.boxUnits()
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }
}

struct UnitRow: View {
    let unit: SystemdUnit

    var body: some View {
        HStack(spacing: HelmSpace.md) {
            PulseDot(color: unitColor(unit.active), size: 7, isActive: unit.active == "failed" || unit.active == "activating")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(unit.name)
                        .font(HelmFont.mono(.subheadline, weight: .medium))
                        .foregroundStyle(HelmColor.textPrimary)
                        .lineLimit(1)
                    if unit.watched {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(HelmColor.textTertiary)
                    }
                }
                Text(unit.description)
                    .font(.caption)
                    .foregroundStyle(HelmColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusChip(text: unit.sub, tint: unitColor(unit.active))
        }
    }
}

func unitColor(_ active: String) -> Color {
    switch active {
    case "active": return HelmColor.lime
    case "failed": return HelmColor.red
    case "activating", "deactivating", "reloading": return HelmColor.amber
    default: return HelmColor.textTertiary
    }
}

struct UnitDetailView: View {
    @Environment(AppStore.self) private var store
    let unit: SystemdUnit
    @State private var current: SystemdUnit?
    @State private var busy: String?
    @State private var message: String?
    @State private var confirmStop = false

    private var u: SystemdUnit { current ?? unit }

    var body: some View {
        List {
            Section {
                HStack(spacing: HelmSpace.md) {
                    PulseDot(color: unitColor(u.active), size: 10, isActive: u.active != "inactive")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(u.active) · \(u.sub)").font(HelmFont.mono(.headline)).foregroundStyle(unitColor(u.active))
                        Text(u.description).font(.footnote).foregroundStyle(HelmColor.textSecondary)
                    }
                }
                .padding(.vertical, HelmSpace.xs)
                .helmRow()
            }
            Section {
                HStack(spacing: HelmSpace.sm) {
                    button("Restart", "arrow.clockwise", "restart", HelmColor.amber)
                    if u.active == "active" {
                        Button { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(HelmSecondaryButtonStyle(tint: HelmColor.red))
                            .disabled(busy != nil)
                    } else {
                        button("Start", "play.fill", "start", HelmColor.lime)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .helmRow()
                if let message {
                    Text(message).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textSecondary).helmRow()
                }
            } header: { HelmSectionHeader(title: "Control") }
            Section {
                NavigationLink {
                    LogView(title: u.name) { try await store.api.boxUnitLogs(u.name, lines: 400) }
                } label: { Label("Journal", systemImage: "text.alignleft").foregroundStyle(HelmColor.textPrimary) }
                    .helmRow()
                NavigationLink {
                    LogView(title: "\(u.name) errors") { try await store.api.boxUnitLogs(u.name, lines: 300, priority: "err") }
                } label: { Label("Errors only", systemImage: "exclamationmark.bubble").foregroundStyle(HelmColor.textPrimary) }
                    .helmRow()
            } header: { HelmSectionHeader(title: "Logs") }
        }
        .helmScreen()
        .navigationTitle(unit.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Stop \(u.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { Task { await act("stop") } }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: String, _ tint: Color) -> some View {
        Button { Task { await act(action) } } label: {
            if busy == action { ProgressView().controlSize(.small) } else { Label(title, systemImage: icon) }
        }
        .buttonStyle(HelmSecondaryButtonStyle(tint: tint))
        .disabled(busy != nil)
    }

    private func act(_ action: String) async {
        busy = action
        Haptics.tap()
        do {
            let v = try await store.api.boxServiceAction(u.name, action: action)
            let ok = v["ok"]?.bool == true
            message = ok ? "\(action): now \(v["active"]?.string ?? "?")" : (v["error"]?.string ?? "\(action) failed")
            ok ? Haptics.success() : Haptics.warning()
            if let fresh = try? await store.api.boxUnits(query: u.name).first(where: { $0.name == u.name }) {
                current = fresh
            }
        } catch {
            message = APIClient.describe(error)
            Haptics.warning()
        }
        busy = nil
    }
}
