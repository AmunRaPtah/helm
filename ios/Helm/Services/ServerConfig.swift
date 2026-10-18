import Foundation

/// Server URL (UserDefaults) and bearer token (Keychain).
struct ServerConfig: Equatable {
    static let defaultURL = "http://10.66.66.1:3340"
    private static let urlKey = "helm.serverURL"
    private static let tokenAccount = "helm.token"

    var urlString: String
    var token: String

    static func load() -> ServerConfig {
        ServerConfig(
            urlString: UserDefaults.standard.string(forKey: urlKey) ?? defaultURL,
            token: Keychain.read(tokenAccount) ?? ""
        )
    }

    func save() {
        UserDefaults.standard.set(normalizedURLString, forKey: Self.urlKey)
        Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.tokenAccount)
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    var normalizedURLString: String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var baseURL: URL? {
        guard let u = URL(string: normalizedURLString), u.host != nil else { return nil }
        return u
    }
}
