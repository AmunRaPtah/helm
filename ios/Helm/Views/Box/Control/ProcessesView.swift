import SwiftUI

/// Live process table (top-style) with search, sort and signals.
struct ProcessesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var procs: [BoxProcess] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var query = ""
    @State private var sort = "cpu"
    @State private var paused = false
    @State private var target: BoxProcess?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                Picker("Sort", selection: $sort) {
                    Text("CPU").tag("cpu")
                    Text("Memory").tag("mem")
                    Text("Age").tag("time")
                }
                .pickerStyle(.segmented)
                .helmRow()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
                }
                if let toast {
                    Label(toast, systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(HelmColor.lime).helmRow()
                }
            }

            Section {
                if !loaded {
                    ForEach(0..<8, id: \.self) { _ in SkeletonRow().helmRow() }
                }
                ForEach(procs) { p in
                    Button { target = p } label: { row(p) }
                        .buttonStyle(.plain)
                        .helmRow()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await signal(p, "KILL") } } label: {
                                Label("Kill", systemImage: "xmark.octagon")
                            }
                            Button { Task { await signal(p, "TERM") } } label: {
                                Label("Term", systemImage: "stop.circle")
                            }
                            .tint(HelmColor.amber)
                        }
                }
            } header: {
                HelmSectionHeader(title: "Processes", trailing: paused ? "paused" : "live · \(procs.count)")
            }
        }
        .helmScreen()
        .navigationTitle("Processes")
        .searchable(text: $query, prompt: "Command or args")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: sort) { _, _ in Task { await load() } }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { paused.toggle(); Haptics.tap() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                .accessibilityLabel(paused ? "Resume live updates" : "Pause live updates")
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !paused { await load() }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .sheet(item: $target) { p in
            ProcessSheet(process: p) { sig in
                target = nil
                Task { await signal(p, sig) }
            }
        }
    }

    private func row(_ p: BoxProcess) -> some View {
        HStack(alignment: .center, spacing: HelmSpace.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.comm)
                        .font(HelmFont.mono(.subheadline, weight: .medium))
                        .foregroundStyle(HelmColor.textPrimary)
                        .lineLimit(1)
                    Text("\(p.pid)").font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                    if p.stat.hasPrefix("D") { StatusChip(text: "D-state", tint: HelmColor.red) }
                    if p.stat.hasPrefix("Z") { StatusChip(text: "zombie", tint: HelmColor.amber) }
                }
                Text(p.args)
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", p.cpu))
                    .font(HelmFont.mono(.caption, weight: .semibold))
                    .foregroundStyle(p.cpu >= 90 ? HelmColor.amber : HelmColor.textPrimary)
                Text(p.rssMB >= 1024 ? String(format: "%.1f GB", p.rssMB / 1024) : String(format: "%.0f MB", p.rssMB))
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
            .frame(minWidth: 56, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        guard store.config.isConfigured else { return }
        do {
            let p = try await store.api.boxProcs(sort: sort, limit: 80, query: query)
            withAnimation(HelmMotion.snappy) { procs = p }
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func signal(_ p: BoxProcess, _ sig: String) async {
        Haptics.tap()
        do {
            let v = try await store.api.boxSignal(pid: p.pid, signal: sig)
            if v["ok"]?.bool == true {
                toast = "SIG\(sig) → \(p.comm) (\(p.pid))"
                Haptics.success()
            } else {
                error = v["error"]?.string ?? "signal failed"
                Haptics.warning()
            }
        } catch {
            self.error = APIClient.describe(error)
        }
        await load()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        toast = nil
    }
}

private struct ProcessSheet: View {
    let process: BoxProcess
    let onSignal: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    fact("PID", "\(process.pid)")
                    fact("Parent", "\(process.ppid)")
                    fact("User", process.user)
                    fact("CPU", String(format: "%.1f%%", process.cpu))
                    fact("Memory", String(format: "%.1f%% · %.0f MB", process.mem, process.rssMB))
                    fact("Running", Fmt.duration(process.elapsed))
                    fact("State", process.stat)
                }
                Section {
                    Text(process.args)
                        .font(HelmFont.mono(.caption))
                        .foregroundStyle(HelmColor.textPrimary)
                        .textSelection(.enabled)
                        .helmRow()
                } header: { HelmSectionHeader(title: "Command") }
                Section {
                    signalRow("Terminate", "TERM", "stop.circle", HelmColor.amber)
                    signalRow("Kill", "KILL", "xmark.octagon", HelmColor.red)
                    signalRow("Hang up (reload)", "HUP", "arrow.triangle.2.circlepath", HelmColor.textPrimary)
                    signalRow("Interrupt", "INT", "hand.raised", HelmColor.textPrimary)
                    if process.stat.hasPrefix("T") {
                        signalRow("Continue", "CONT", "play.fill", HelmColor.lime)
                    } else {
                        signalRow("Suspend", "STOP", "pause.fill", HelmColor.textPrimary)
                    }
                } header: { HelmSectionHeader(title: "Send signal") }
            }
            .helmScreen()
            .navigationTitle(process.comm)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Send SIG\(confirm ?? "") to \(process.comm) (\(process.pid))?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button("Send SIG\(confirm ?? "")", role: .destructive) {
                    if let c = confirm { onSignal(c) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.footnote).foregroundStyle(HelmColor.textTertiary)
            Spacer()
            Text(v).font(HelmFont.mono(.caption)).foregroundStyle(HelmColor.textPrimary)
        }
        .helmRow()
    }

    private func signalRow(_ title: String, _ sig: String, _ icon: String, _ tint: Color) -> some View {
        Button { confirm = sig } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(tint)
                Spacer()
                Text("SIG\(sig)").font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
            }
        }
        .helmRow()
    }
}
