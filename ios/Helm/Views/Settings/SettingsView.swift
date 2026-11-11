import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var isOnboarding = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var revealToken = false
    @State private var test = ConnectionTest.State.idle
    @State private var loaded = false
    @State private var certName: String? = ClientIdentity.installedName
    @State private var showImporter = false
    @State private var inbox = CertInbox.shared
    @State private var p12Password = ""
    @State private var certError: String?

    private var draft: ServerConfig { ServerConfig(urlString: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        Form {
            if isOnboarding {
                Section {
                    OnboardingHeader()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("http://10.66.66.1:3340", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(HelmFont.mono(.body))
                    .foregroundStyle(HelmColor.textPrimary)
                HStack {
                    Group {
                        if revealToken {
                            TextField("Bearer token", text: $token)
                        } else {
                            SecureField("Bearer token", text: $token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(HelmFont.mono(.body))
                    .foregroundStyle(HelmColor.textPrimary)
                    Button {
                        Haptics.tap()
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                            .foregroundStyle(HelmColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    if token.isEmpty {
                        Button("Paste") {
                            Haptics.tap()
                            if let s = UIPasteboard.general.string { token = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.semibold))
                        .tint(HelmColor.lime)
                    }
                }
            } header: {
                HelmSectionHeader(title: "Server")
            } footer: {
                Text("Over WireGuard: http://10.66.66.1:3340. Without it: https://helm.178-18-250-254.sslip.io plus the client certificate below. The token is in Bitwarden as \u{201C}Helm Token\u{201D} and is stored in the iOS Keychain.")
                    .foregroundStyle(HelmColor.textTertiary)
            }
            .helmRow()

            Section {
                if let certName {
                    LabeledContent("Installed") {
                        Text(certName)
                            .font(HelmFont.mono(.callout))
                            .foregroundStyle(HelmColor.textSecondary)
                    }
                    .foregroundStyle(HelmColor.textPrimary)
                    Button("Remove certificate", role: .destructive) {
                        Haptics.warning()
                        ClientIdentity.remove()
                        self.certName = nil
                    }
                } else if inbox.pending != nil {
                    // Inline rather than an alert: an alert raised while the file picker is
                    // still dismissing is silently dropped by SwiftUI.
                    SecureField("Certificate password", text: $p12Password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(HelmFont.mono(.body))
                    Button("Import") { importPending() }
                        .fontWeight(.semibold)
                        .tint(HelmColor.lime)
                        .disabled(p12Password.isEmpty)
                    Button("Cancel", role: .cancel) {
                        Haptics.tap()
                        inbox.pending = nil
                        p12Password = ""
                    }
                } else {
                    Button {
                        Haptics.tap()
                        showImporter = true
                    } label: {
                        Label("Import .p12 certificate", systemImage: "lock.shield")
                    }
                    .tint(HelmColor.textPrimary)
                    Button {
                        Haptics.tap()
                        certError = nil
                        if let text = UIPasteboard.general.string, let data = CertInbox.decodePasted(text) {
                            p12Password = ""
                            inbox.pending = data
                        } else {
                            certError = "Clipboard does not hold a base64 certificate."
                        }
                    } label: {
                        Label("Paste certificate text", systemImage: "doc.on.clipboard")
                    }
                    .tint(HelmColor.textPrimary)
                }
                if let certError {
                    Label {
                        Text(certError).font(HelmFont.mono(.caption))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(HelmColor.red)
                }
            } header: {
                HelmSectionHeader(title: "Client certificate")
            } footer: {
                Text("Or share the .p12 to Helm from Telegram, Mail or Files. Password is in Bitwarden as \u{201C}Helm Client Cert\u{201D}. Required for the public https route, which rejects any device without it before helmd is reached. Not needed over WireGuard.")
                    .foregroundStyle(HelmColor.textTertiary)
            }
            .helmRow()

            Section {
                Button {
                    Haptics.tap()
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(HelmColor.textPrimary)
                        Spacer()
                        if case .running = test {
                            ProgressView().tint(HelmColor.amber)
                        }
                    }
                }
                .disabled(draft.baseURL == nil || isTesting)
                ConnectionTestResult(state: test)
            } header: {
                HelmSectionHeader(title: "Diagnostics")
            }
            .helmRow()

            Section {
                Button(isOnboarding ? "Connect" : "Save") { save() }
                    .buttonStyle(HelmPrimaryButtonStyle())
                    .disabled(!draft.isConfigured)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: HelmSpace.xs, leading: 0, bottom: HelmSpace.xs, trailing: 0))

            if !isOnboarding {
                Section {
                    LabeledContent("Version") {
                        Text(Bundle.main.shortVersion)
                            .font(HelmFont.mono(.callout))
                            .foregroundStyle(HelmColor.textSecondary)
                    }
                    LabeledContent("Protocol") {
                        Text("v1")
                            .font(HelmFont.mono(.callout))
                            .foregroundStyle(HelmColor.textSecondary)
                    }
                } header: {
                    HelmSectionHeader(title: "About")
                }
                .foregroundStyle(HelmColor.textPrimary)
                .helmRow()
            }
        }
        .helmScreen()
        .tint(HelmColor.lime)
        .navigationTitle(isOnboarding ? "Welcome" : "Settings")
        .navigationBarTitleDisplayMode(isOnboarding ? .large : .inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(HelmColor.textSecondary)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12, .data]) { result in
            certError = nil
            switch result {
            case .success(let fileURL):
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: fileURL) {
                    p12Password = ""
                    inbox.pending = data
                } else {
                    certError = "Could not read that file."
                }
            case .failure(let error):
                certError = error.localizedDescription
            }
        }
        .onAppear {
            certName = ClientIdentity.installedName
            guard !loaded else { return }
            loaded = true
            url = store.config.urlString.isEmpty ? ServerConfig.defaultURL : store.config.urlString
            token = store.config.token
        }
    }

    private var isTesting: Bool { if case .running = test { return true }; return false }

    private func runTest() async {
        test = .running
        test = await ConnectionTest.run(draft)
        if case .success = test { Haptics.success() } else { Haptics.warning() }
    }

    private func importPending() {
        guard let data = inbox.pending else { return }
        inbox.pending = nil
        do {
            certName = try ClientIdentity.importP12(data, password: p12Password)
            certError = nil
            Haptics.success()
        } catch {
            certError = error.localizedDescription
            Haptics.warning()
        }
        p12Password = ""
    }

    private func save() {
        store.updateConfig(draft)
        Haptics.success()
        Task {
            await store.refreshHarnesses()
            await store.refresh()
        }
        if !isOnboarding { dismiss() }
    }
}

private struct OnboardingHeader: View {
    var body: some View {
        VStack(spacing: HelmSpace.md) {
            HelmMark(size: 76)
                .padding(.top, HelmSpace.sm)
                .padding(.bottom, HelmSpace.xs)
            Text("Helm")
                .font(.system(.title, design: .default, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(HelmColor.textPrimary)
            Text("Chat with the coding harnesses on your server. Enter your helmd URL and token. Off WireGuard, use the https URL and import your client certificate.")
                .font(.subheadline)
                .foregroundStyle(HelmColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, HelmSpace.sm)
        .frame(maxWidth: .infinity)
    }
}

extension Bundle {
    var shortVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
