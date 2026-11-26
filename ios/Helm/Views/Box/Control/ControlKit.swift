import SwiftUI
import Charts

// Shared building blocks for the box controller screens.

/// Threshold tint used across gauges, meters and tiles.
func levelTint(_ pct: Double, warn: Double = 75, crit: Double = 90) -> Color {
    if pct >= crit { return HelmColor.red }
    if pct >= warn { return HelmColor.amber }
    return HelmColor.lime
}

/// Circular instrument gauge: a hairline track, a tinted arc, value in the middle.
struct RingGauge: View {
    let label: String
    let value: Double       // 0...100
    var display: String? = nil
    var tint: Color? = nil

    private var fraction: Double { min(1, max(0, value / 100)) }

    var body: some View {
        let color = tint ?? levelTint(value)
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.004, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.5), radius: 4)
                    .helmAnimation(HelmMotion.gentle, value: fraction)
                Text(display ?? "\(Int(value.rounded()))")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(HelmColor.textPrimary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: 58, height: 58)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(HelmColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(display ?? "\(Int(value)) percent")")
    }
}

/// Live area chart over the sampler history. `series` picks the field.
struct MetricChart: View {
    enum Series: String, CaseIterable, Identifiable {
        case cpu = "CPU", mem = "Memory", swap = "Swap", load = "Load", net = "Network", disk = "Disk I/O"
        var id: String { rawValue }
    }

    let points: [MetricPoint]
    let series: Series
    var cpus: Int = 1

    var body: some View {
        Chart {
            switch series {
            case .net:
                ForEach(points) { p in
                    LineMark(x: .value("t", p.date), y: .value("rate", p.rx), series: .value("dir", "in"))
                        .foregroundStyle(HelmColor.lime)
                    LineMark(x: .value("t", p.date), y: .value("rate", p.tx), series: .value("dir", "out"))
                        .foregroundStyle(HelmColor.amber)
                }
            case .disk:
                ForEach(points) { p in
                    LineMark(x: .value("t", p.date), y: .value("rate", p.rd), series: .value("dir", "read"))
                        .foregroundStyle(HelmColor.lime)
                    LineMark(x: .value("t", p.date), y: .value("rate", p.wr), series: .value("dir", "write"))
                        .foregroundStyle(HelmColor.amber)
                }
            default:
                ForEach(points) { p in
                    AreaMark(x: .value("t", p.date), y: .value("v", value(p)))
                        .foregroundStyle(LinearGradient(colors: [HelmColor.lime.opacity(0.35), HelmColor.lime.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", p.date), y: .value("v", value(p)))
                        .foregroundStyle(HelmColor.lime)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                if series == .load {
                    RuleMark(y: .value("cpus", Double(cpus)))
                        .foregroundStyle(HelmColor.amber.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(HelmColor.hairline)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(HelmColor.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(HelmColor.hairline)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(axisLabel(d)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(HelmColor.textTertiary)
                    }
                }
            }
        }
        .animation(nil, value: points.count)
    }

    private func value(_ p: MetricPoint) -> Double {
        switch series {
        case .cpu: return p.cpu
        case .mem: return p.mem
        case .swap: return p.swap
        case .load: return p.load
        case .net: return p.rx
        case .disk: return p.rd
        }
    }

    private var yDomain: ClosedRange<Double> {
        switch series {
        case .cpu, .mem, .swap: return 0...100
        case .load:
            let m = max(Double(cpus), points.map(\.load).max() ?? 1)
            return 0...(m * 1.1)
        case .net:
            return 0...max(1024, (points.map { max($0.rx, $0.tx) }.max() ?? 1) * 1.1)
        case .disk:
            return 0...max(1024, (points.map { max($0.rd, $0.wr) }.max() ?? 1) * 1.1)
        }
    }

    private func axisLabel(_ d: Double) -> String {
        switch series {
        case .cpu, .mem, .swap: return "\(Int(d))%"
        case .load: return String(format: "%.0f", d)
        case .net, .disk: return Fmt.bytes(d)
        }
    }
}

/// A compact dashboard tile: icon, big number, caption; tinted when in trouble.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String = ""
    var systemImage: String
    var tint: Color = HelmColor.textSecondary
    var alert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(alert ? HelmColor.red : tint)
                Spacer()
                if alert { PulseDot(color: HelmColor.red, size: 6) }
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HelmColor.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(HelmColor.textPrimary)
                if !caption.isEmpty {
                    Text(caption)
                        .font(HelmFont.mono(.caption2))
                        .foregroundStyle(alert ? HelmColor.red.opacity(0.9) : HelmColor.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(HelmSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .helmCard(stroke: alert ? HelmColor.red.opacity(0.35) : nil)
        .accessibilityElement(children: .combine)
    }
}

/// Small coloured status capsule ("running", "failed"...).
struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(HelmFont.mono(.caption2, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .lineLimit(1)
    }
}

/// Generic, searchable, auto-refreshing log/output viewer.
struct LogView: View {
    let title: String
    let load: () async throws -> String
    var autoRefresh: Bool = true

    @State private var text = ""
    @State private var error: String?
    @State private var loading = false
    @State private var follow = true
    @State private var filter = ""
    @State private var wrap = true

    private var lines: [Substring] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(HelmColor.amber)
                            .padding(.bottom, 8)
                    }
                    if text.isEmpty && loading {
                        ForEach(0..<10, id: \.self) { _ in SkeletonBlock(height: 10).padding(.vertical, 3) }
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tint(for: line))
                            .lineLimit(wrap ? nil : 1)
                            .fixedSize(horizontal: !wrap, vertical: false)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(HelmSpace.md)
            }
            .onChange(of: text) { _, _ in
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(HelmColor.obsidian)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter lines")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if loading { ProgressView().controlSize(.small) }
                Menu {
                    Toggle("Follow tail", isOn: $follow)
                    Toggle("Wrap lines", isOn: $wrap)
                    Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = text; Haptics.success() } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task {
            await reload()
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if follow { await reload() }
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let t = try await load()
            if t != text { text = t }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = APIClient.describe(error)
        }
    }

    private func tint(for line: Substring) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("fatal") || l.contains("panic") || l.contains("traceback") {
            return HelmColor.red
        }
        if l.contains("warn") { return HelmColor.amber }
        return HelmColor.textSecondary
    }
}

/// Output sheet for a one-shot command (quick actions, container ops).
struct CommandOutputSheet: View {
    let title: String
    let result: ShellResult?
    let running: Bool
    var duration: Double? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HelmSpace.md) {
                    HStack(spacing: HelmSpace.sm) {
                        if running {
                            ProgressView().controlSize(.small)
                            Text("Running…").font(HelmFont.mono(.caption)).foregroundStyle(HelmColor.textSecondary)
                        } else if let r = result {
                            StatusChip(text: r.ok ? "exit 0" : "exit \(r.exit)", tint: r.ok ? HelmColor.lime : HelmColor.red)
                            if let duration {
                                Text(String(format: "%.1fs", duration))
                                    .font(HelmFont.mono(.caption2)).foregroundStyle(HelmColor.textTertiary)
                            }
                        }
                        Spacer()
                    }
                    if let r = result {
                        Text(r.output.isEmpty ? "(no output)" : r.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(HelmColor.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(HelmSpace.md)
                            .helmCard(fill: HelmColor.surface)
                    }
                }
                .padding(HelmSpace.lg)
            }
            .helmScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let r = result {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: r.output) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
