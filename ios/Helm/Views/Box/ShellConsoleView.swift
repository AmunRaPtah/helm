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
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? "Run a command to see output here." : output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(output.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("bottom")
                }
                .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let exitCode {
                HStack {
                    Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                    Text("exit \(exitCode)").font(.caption.monospaced())
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            VStack(spacing: 8) {
                TextField("cwd", text: $cwd)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack(spacing: 8) {
                    TextField("command…", text: $cmd, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...4)
                    Button { run() } label: {
                        if running { ProgressView() } else { Image(systemName: "play.fill") }
                    }
                    .disabled(cmd.isEmpty || running)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Shell")
        .navigationBarTitleDisplayMode(.inline)
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
