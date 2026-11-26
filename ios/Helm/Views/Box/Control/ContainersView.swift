import SwiftUI

/// Docker containers grouped by compose project, with live stats and actions.
struct ContainersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", stopped = "Stopped", trouble = "Trouble"
        var id: String { rawValue }
    }

    @State private var listing: DockerListing?
    @State private var error: String?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var busy: String?
    @State private var result: ShellResult?
    @State private var resultTitle = ""
    @State private var showResult = false
    @State private var pendingKill: DockerContainer?

    private var filtered: [DockerContainer] {
        (listing?.containers ?? []).filter { c in
            switch filter {
            case .all: break
            case .running: if !c.isRunning { return false }
            case .stopped: if c.isRunning { return false }
            case .trouble: if !c.isTrouble { return false }
            }
            guard !query.isEmpty else { return true }
            return c.name.localizedCaseInsensitiveContains(query)
                || c.image.localizedCaseInsensitiveContains(query)
                || c.project.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(String, [DockerContainer])] {
        let d = Dictionary(grouping: filtered) { $0.project.isEmpty ? "standalone" : $0.project }
        return d.keys.sorted { a, b in
            if a == "standalone" { return false }
            if b == "standalone" { return true }
            return a < b
        }.map { k in
            (k, d[k]!.sorted { ($0.isTrouble ? 0 : $0.isRunning ? 1 : 2, $0.name) < ($1.isTrouble ? 0 : $1.isRunning ? 1 : 2, $1.name) })
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .helmRow()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
                }
            } footer: {
                if let l = listing {
                    Text(footer(l)).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                }
            }

            if listing == nil {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow().helmRow() }
            } else if filtered.isEmpty {
                HelmEmptyState(title: "No containers", message: query.isEmpty ? "Nothing matches this filter." : "Nothing matches “\(query)”.",
                               showMark: false, systemImage: "shippingbox")
                    .helmRow()
            }

            ForEach(groups, id: \.0) { project, items in
                Section {
                    ForEach(items) { c in
                        NavigationLink { ContainerDetailView(container: c) } label: { row(c) }
                            .helmRow()
                            .contextMenu { actionButtons(c) }
                            .swipeActions(edge: .trailing) {
                                if c.isRunning {
                                    Button { Task { await act(c, "restart") } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                                        .tint(HelmColor.amber)
                                } else {
                                    Button { Task { await act(c, "start") } } label: { Label("Start", systemImage: "play.fill") }
                                        .tint(.green)
                                }
                            }
                    }
                } header: {
                    HelmSectionHeader(title: project, trailing: "\(items.filter(\.isRunning).count)/\(items.count)")
                }
            }
        }
        .helmScreen()
        .navigationTitle("Containers")
        .searchable(text: $query, prompt: "Name, image, project")
        .refreshable { await load(wait: true) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load(wait: listing == nil)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        .sheet(isPresented: $showResult) {
            CommandOutputSheet(title: resultTitle, result: result, running: busy != nil)
        }
        .confirmationDialog("Kill \(pendingKill?.name ?? "")?", isPresented: Binding(
            get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }), titleVisibility: .visible) {
            Button("Kill", role: .destructive) {
                if let c = pendingKill { Task { await act(c, "kill") } }
            }
        } message: { Text("Sends SIGKILL. The container stops immediately without cleanup.") }
    }

    private func row(_ c: DockerContainer) -> some View {
        HStack(spacing: HelmSpace.md) {
            PulseDot(color: dotColor(c), size: 7, isActive: c.isTrouble)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name)
                    .font(HelmFont.mono(.subheadline, weight: .medium))
                    .foregroundStyle(HelmColor.textPrimary)
                    .lineLimit(1)
                Text(c.status)
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(c.isTrouble ? HelmColor.red : HelmColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if busy == c.name {
                ProgressView().controlSize(.small)
            } else if let cpu = c.cpu {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", cpu))
                        .font(HelmFont.mono(.caption, weight: .medium))
                        .foregroundStyle(cpu > 80 ? HelmColor.amber : HelmColor.textSecondary)
                    if let m = c.mem {
                        Text(m.components(separatedBy: " /").first ?? m)
                            .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func actionButtons(_ c: DockerContainer) -> some View {
        if c.isRunning {
            Button { Task { await act(c, "restart") } } label: { Label("Restart", systemImage: "arrow.clockwise") }
            Button { Task { await act(c, "stop") } } label: { Label("Stop", systemImage: "stop.fill") }
            Button { Task { await act(c, "pause") } } label: { Label("Pause", systemImage: "pause.fill") }
            Button(role: .destructive) { pendingKill = c } label: { Label("Kill", systemImage: "xmark.octagon") }
        } else if c.state == "paused" {
            Button { Task { await act(c, "unpause") } } label: { Label("Resume", systemImage: "play.fill") }
        } else {
            Button { Task { await act(c, "start") } } label: { Label("Start", systemImage: "play.fill") }
        }
    }

    private func dotColor(_ c: DockerContainer) -> Color {
        if c.isTrouble { return HelmColor.red }
        if c.state == "paused" { return HelmColor.amber }
        return c.isRunning ? HelmColor.lime : HelmColor.textTertiary
    }

    private func footer(_ l: DockerListing) -> String {
        let run = l.containers.filter(\.isRunning).count
        var s = "\(run) running · \(l.containers.count) total"
        if let a = l.ageSeconds { s += " · updated \(Int(a))s ago" }
        if l.refreshing { s += " · refreshing" }
        return s
    }

    private func load(wait: Bool) async {
        guard store.config.isConfigured else { return }
        do {
            listing = try await store.api.boxDocker(stats: true)
            error = listing?.error
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func act(_ c: DockerContainer, _ action: String) async {
        busy = c.name
        Haptics.tap()
        resultTitle = "\(action) \(c.name)"
        do {
            let v = try await store.api.boxDockerAction(c.name, action: action)
            let r = ShellResult(json: v)
            if r.ok { Haptics.success() } else { result = r; showResult = true; Haptics.warning() }
        } catch {
            self.error = APIClient.describe(error)
            Haptics.warning()
        }
        busy = nil
        await load(wait: true)
    }
}

/// One container: facts, actions and its log tail.
struct ContainerDetailView: View {
    @Environment(AppStore.self) private var store
    let container: DockerContainer
    @State private var busy: String?
    @State private var message: String?
    @State private var confirmKill = false

    var body: some View {
        List {
            Section {
                fact("State", container.state + (container.health.isEmpty ? "" : " · \(container.health)"))
                fact("Status", container.status)
                fact("Image", container.image)
                if !container.project.isEmpty { fact("Project", container.project) }
                if !container.ports.isEmpty { fact("Ports", container.ports) }
                if let cpu = container.cpu { fact("CPU", String(format: "%.1f%%", cpu)) }
                if let mem = container.mem { fact("Memory", mem) }
                fact("ID", container.id)
            } header: { HelmSectionHeader(title: "Container") }

            Section {
                HStack(spacing: HelmSpace.sm) {
                    actionButton("Restart", "arrow.clockwise", "restart", HelmColor.amber)
                    if container.isRunning {
                        actionButton("Stop", "stop.fill", "stop", HelmColor.red)
                    } else {
                        actionButton("Start", "play.fill", "start", HelmColor.lime)
                    }
                    Button { confirmKill = true } label: { Label("Kill", systemImage: "xmark.octagon") }
                        .buttonStyle(HelmSecondaryButtonStyle(tint: HelmColor.red))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .helmRow()
                if let message {
                    Text(message).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textSecondary).helmRow()
                }
            } header: { HelmSectionHeader(title: "Actions") }

            Section {
                NavigationLink {
                    LogView(title: container.name) { try await store.api.boxDockerLogs(container.name, lines: 400) }
                } label: {
                    Label("Logs", systemImage: "text.alignleft").foregroundStyle(HelmColor.textPrimary)
                }
                .helmRow()
            }
        }
        .helmScreen()
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Kill \(container.name)?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill", role: .destructive) { Task { await act("kill") } }
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.footnote).foregroundStyle(HelmColor.textTertiary).frame(width: 70, alignment: .leading)
            Text(v).font(HelmFont.mono(.caption)).foregroundStyle(HelmColor.textPrimary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .helmRow()
    }

    private func actionButton(_ title: String, _ icon: String, _ action: String, _ tint: Color) -> some View {
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
            let r = ShellResult(json: try await store.api.boxDockerAction(container.name, action: action))
            message = r.ok ? "\(action): done" : "\(action) failed: \(r.output)"
            r.ok ? Haptics.success() : Haptics.warning()
        } catch {
            message = APIClient.describe(error)
            Haptics.warning()
        }
        busy = nil
    }
}
