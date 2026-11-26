import SwiftUI

/// WireGuard peers, interfaces and listening ports.
struct NetworkView: View {
    @Environment(AppStore.self) private var store
    @State private var net: BoxNetwork?
    @State private var error: String?
    @State private var publicOnly = false

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
            }
            if let net {
                Section {
                    if net.peers.isEmpty {
                        Text("No WireGuard peers").font(.footnote).foregroundStyle(HelmColor.textTertiary).helmRow()
                    }
                    ForEach(net.peers) { p in
                        HStack(spacing: HelmSpace.md) {
                            PulseDot(color: p.online ? HelmColor.lime : HelmColor.textTertiary, size: 7, isActive: p.online)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.allowed.components(separatedBy: ",").first ?? p.allowed)
                                    .font(HelmFont.mono(.subheadline, weight: .medium)).foregroundStyle(HelmColor.textPrimary)
                                Text("\(p.iface) · \(p.key)… · \(p.endpoint.isEmpty ? "no endpoint" : p.endpoint)")
                                    .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(p.handshakeAgo.map { "\(Fmt.duration($0)) ago" } ?? "never")
                                    .font(HelmFont.mono(.caption2)).foregroundStyle(p.online ? HelmColor.lime : HelmColor.textTertiary)
                                Text("↓\(Fmt.bytes(p.rx)) ↑\(Fmt.bytes(p.tx))")
                                    .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                            }
                        }
                        .helmRow()
                    }
                } header: {
                    HelmSectionHeader(title: "WireGuard", trailing: "\(net.peers.filter(\.online).count)/\(net.peers.count) online")
                }

                Section {
                    ForEach(net.interfaces) { i in
                        HStack {
                            Text(i.name).font(HelmFont.mono(.subheadline)).foregroundStyle(HelmColor.textPrimary)
                            Spacer()
                            Text(i.addr).font(HelmFont.mono(.caption)).foregroundStyle(HelmColor.textSecondary).textSelection(.enabled)
                        }
                        .helmRow()
                    }
                } header: { HelmSectionHeader(title: "Interfaces") }

                Section {
                    Toggle("Public only (0.0.0.0 / ::)", isOn: $publicOnly)
                        .font(.footnote).tint(HelmColor.lime).helmRow()
                    ForEach(net.ports.filter { !publicOnly || $0.isPublic }) { p in
                        HStack(spacing: HelmSpace.md) {
                            Text(":\(p.port)")
                                .font(HelmFont.mono(.subheadline, weight: .semibold))
                                .foregroundStyle(p.isPublic ? HelmColor.amber : HelmColor.textPrimary)
                                .frame(width: 64, alignment: .leading)
                            Text(p.proc.isEmpty ? "?" : p.proc).font(HelmFont.mono(.caption)).foregroundStyle(HelmColor.textSecondary)
                            Spacer()
                            Text(p.addr).font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                        }
                        .helmRow()
                    }
                } header: {
                    HelmSectionHeader(title: "Listening", trailing: "\(net.ports.filter(\.isPublic).count) public")
                }
            } else {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow().helmRow() }
            }
        }
        .helmScreen()
        .navigationTitle("Network")
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func load() async {
        guard store.config.isConfigured else { return }
        do { net = try await store.api.boxNetwork(); error = nil }
        catch is CancellationError {}
        catch { self.error = APIClient.describe(error) }
    }
}

/// Read-only view of root's crontab, with plain-language schedules.
struct CronView: View {
    @Environment(AppStore.self) private var store
    @State private var jobs: [CronJob]?
    @State private var error: String?
    @State private var showDisabled = false
    @State private var query = ""

    private var shown: [CronJob] {
        (jobs ?? []).filter { (showDisabled || $0.enabled) &&
            (query.isEmpty || $0.command.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(HelmColor.amber).helmRow()
            }
            Section {
                Toggle("Show disabled", isOn: $showDisabled).font(.footnote).tint(HelmColor.lime).helmRow()
            }
            Section {
                if jobs == nil { ForEach(0..<6, id: \.self) { _ in SkeletonRow().helmRow() } }
                ForEach(shown) { j in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(j.schedule).font(HelmFont.mono(.caption, weight: .semibold))
                                .foregroundStyle(j.enabled ? HelmColor.lime : HelmColor.textTertiary)
                            Text(describeSchedule(j.schedule)).font(.caption2).foregroundStyle(HelmColor.textTertiary)
                            Spacer()
                            if !j.enabled { StatusChip(text: "off", tint: HelmColor.textTertiary) }
                        }
                        Text(j.command)
                            .font(HelmFont.mono(.caption2))
                            .foregroundStyle(j.enabled ? HelmColor.textPrimary : HelmColor.textTertiary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .helmRow()
                }
            } header: {
                let on = (jobs ?? []).filter(\.enabled).count
                HelmSectionHeader(title: "crontab -l", trailing: "\(on) active · \((jobs ?? []).count - on) off")
            }
        }
        .helmScreen()
        .navigationTitle("Cron")
        .searchable(text: $query, prompt: "Command")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard store.config.isConfigured else { return }
        do { jobs = try await store.api.boxCron(); error = nil }
        catch is CancellationError {}
        catch { self.error = APIClient.describe(error) }
    }
}

/// Best-effort English for the common cron shapes; falls back to "".
func describeSchedule(_ s: String) -> String {
    if s.hasPrefix("@") { return s.dropFirst().description }
    let f = s.split(separator: " ").map(String.init)
    guard f.count == 5 else { return "" }
    let (m, h, dom, mon, dow) = (f[0], f[1], f[2], f[3], f[4])
    let rest = dom == "*" && mon == "*"
    if m == "*" && h == "*" && rest && dow == "*" { return "every minute" }
    if m.hasPrefix("*/") && h == "*" && rest && dow == "*" { return "every \(m.dropFirst(2)) min" }
    if let mi = Int(m), h == "*" && rest && dow == "*" { return "hourly at :\(String(format: "%02d", mi))" }
    if let mi = Int(m), h.hasPrefix("*/") && rest && dow == "*" { return "every \(h.dropFirst(2))h at :\(String(format: "%02d", mi))" }
    if let mi = Int(m), let hi = Int(h), rest {
        let t = String(format: "%02d:%02d", hi, mi)
        if dow == "*" { return "daily \(t)" }
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        if let d = Int(dow), d < days.count { return "\(days[d]) \(t)" }
        return "\(t) on \(dow)"
    }
    return ""
}
