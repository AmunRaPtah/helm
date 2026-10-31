import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var isOnboarding = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helm.appearance") private var appearance = Appearance.dark.rawValue

    @State private var url = ""
    @State private var token = ""
    @State private var revealToken = false
    @State private var test = ConnectionTest.State.idle
    @State private var loaded = false
    @State private var certName: String? = ClientIdentity.installedName
    @State private var showImporter = false
    @State private var pendingP12: Data?
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
                    .font(.body.monospaced())
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
                    .font(.body.monospaced())
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if token.isEmpty {
                        Button("Paste") {
                            if let s = UIPasteboard.general.string { token = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Over WireGuard: http://10.66.66.1:3340. Without it: https://helm.178-18-250-254.sslip.io plus the client certificate below. The token is in Bitwarden as \u{201C}Helm Token\u{201D} and is stored in the iOS Keychain.")
            }

            Section {
                if let certName {
                    LabeledContent("Installed", value: certName)
                    Button("Remove certificate", role: .destructive) {
                        ClientIdentity.remove()
                        self.certName = nil
                    }
                } else if pendingP12 != nil {
                    // Inline rather than an alert: an alert raised while the file picker is
                    // still dismissing is silently dropped by SwiftUI.
                    SecureField("Certificate password", text: $p12Password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Import") { importPending() }
                        .disabled(p12Password.isEmpty)
                    Button("Cancel", role: .cancel) {
                        pendingP12 = nil
                        p12Password = ""
                    }
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import .p12 certificate", systemImage: "lock.shield")
                    }
                }
                if let certError {
                    Text(certError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Client certificate")
            } footer: {
                Text("Password is in Bitwarden as \u{201C}Helm Client Cert\u{201D}. Required for the public https route, which rejects any device without it before helmd is reached. Not needed over WireGuard.")
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if case .running = test { ProgressView() }
                    }
                }
                .disabled(draft.baseURL == nil || isTesting)
                ConnectionTestResult(state: test)
            }

            Section {
                Button(isOnboarding ? "Connect" : "Save") { save() }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .disabled(!draft.isConfigured)
            }

            if !isOnboarding {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Protocol", value: "v1")
                }
            }
        }
        .navigationTitle(isOnboarding ? "Welcome" : "Settings")
        .navigationBarTitleDisplayMode(isOnboarding ? .large : .inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
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
                    pendingP12 = data
                } else {
                    certError = "Could not read that file."
                }
            case .failure(let error):
                certError = error.localizedDescription
            }
        }
        .onAppear {
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
        guard let data = pendingP12 else { return }
        pendingP12 = nil
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
        VStack(spacing: 12) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("Helm")
                .font(.title.weight(.semibold))
            Text("Chat with the coding harnesses on your server. Enter your helmd URL and token. Off WireGuard, use the https URL and import your client certificate.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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
