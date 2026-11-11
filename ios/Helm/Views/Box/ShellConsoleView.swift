import SwiftUI

/// Arbitrary `bash -lc` on the box. Output bounded server-side (~20 KB).
struct ShellConsoleView: View {
    @Environment(AppStore.self) private var store

    @State private var cmd = ""
    @State private var cwd = "/root"
    @State private var output = ""
    @State private var exitCode: Int?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            terminal
                .padding(.horizontal, HelmSpace.sm)
                .padding(.top, HelmSpace.sm)
            if let exitCode {
                exitRow(exitCode)
                    .transition(.opacity)
            }
            inputBar
        }
        .background(HelmBackground())
        .helmAnimation(HelmMotion.snappy, value: exitCode)
        .navigationTitle("Shell")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output.isEmpty ? "Run a command to see output here." : output)
                    .font(HelmFont.mono(.caption))
                    .foregroundStyle(output.isEmpty ? HelmColor.textTertiary : HelmColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(HelmSpace.md)
                    .id("bottom")
            }
            .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                .fill(HelmColor.obsidian)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous)
                .strokeBorder(HelmColor.hairlineStrong, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if running {
                ThinkingIndicator(label: nil)
                    .padding(HelmSpace.sm)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HelmRadius.card, style: .continuous))
    }

    private func exitRow(_ code: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(code == 0 ? HelmColor.lime : HelmColor.red)
            Text("exit \(code)")
                .font(HelmFont.mono(.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(code == 0 ? HelmColor.textSecondary : HelmColor.red)
            Spacer()
        }
        .padding(.horizontal, HelmSpace.lg)
        .padding(.vertical, 6)
    }

    private var inputBar: some View {
        VStack(spacing: HelmSpace.sm) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(HelmColor.textTertiary)
                TextField("cwd", text: $cwd)
                    .font(HelmFont.mono(.caption))
                    .foregroundStyle(HelmColor.textSecondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, HelmSpace.md)
            .padding(.vertical, 8)
            .helmCard(radius: HelmRadius.chip, fill: HelmColor.raised)
            HStack(alignment: .bottom, spacing: HelmSpace.sm) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$")
                        .font(HelmFont.mono(.body, weight: .bold))
                        .foregroundStyle(HelmColor.lime)
                    TextField("command…", text: $cmd, axis: .vertical)
                        .font(HelmFont.mono(.body))
                        .foregroundStyle(HelmColor.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...4)
                }
                .padding(.horizontal, HelmSpace.md)
                .padding(.vertical, 10)
                .helmCard(radius: HelmRadius.control, fill: HelmColor.raised)
                Button { run() } label: {
                    Group {
                        if running {
                            ProgressView().tint(HelmColor.textSecondary)
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(HelmPrimaryButtonStyle(fullWidth: false))
                .disabled(cmd.isEmpty || running)
            }
        }
        .padding(HelmSpace.sm)
        .background(HelmColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(HelmColor.hairline).frame(height: 1)
        }
    }

    private func run() {
        let c = cmd
        running = true
        exitCode = nil
        Haptics.tap()
        Task {
            defer { running = false }
            do {
                let r = try await store.api.boxShell(c, cwd: cwd, timeout: 120)
                output = r.output.isEmpty ? "(no output)" : r.output
                exitCode = r.exit
            } catch {
                output = APIClient.describe(error)
                exitCode = -1
            }
        }
    }
}
