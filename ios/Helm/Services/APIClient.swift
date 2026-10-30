import Foundation

/// Thin async/await REST client for helmd (PROTOCOL.md "REST").
struct APIClient {
    var config: ServerConfig

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: ClientCertDelegate.shared, delegateQueue: nil)
    }()

    // MARK: Endpoints

    func health() async throws -> JSONValue {
        try await request("GET", "/health", auth: false)
    }

    func harnesses() async throws -> [Harness] {
        let v = try await request("GET", "/harnesses")
        return list(v, key: "harnesses").compactMap(Harness.init(json:))
    }

    func sessions() async throws -> [Session] {
        let v = try await request("GET", "/sessions")
        return list(v, key: "sessions").compactMap(Session.init(json:))
            .sorted { $0.updated > $1.updated }
    }

    func session(_ id: String) async throws -> Session {
        try decodeSession(try await request("GET", "/sessions/\(id)"))
    }

    struct NewSession {
        var harness: String
        var profile: String?
        var model: String?
        var cwd: String?
        var permission: String?
        var text: String?
    }

    func createSession(_ n: NewSession) async throws -> Session {
        var body: [String: JSONValue] = ["harness": .string(n.harness)]
        if let p = n.profile, !p.isEmpty { body["profile"] = .string(p) }
        if let m = n.model, !m.isEmpty { body["model"] = .string(m) }
        if let c = n.cwd, !c.isEmpty { body["cwd"] = .string(c) }
        if let p = n.permission { body["permission"] = .string(p) }
        if let t = n.text, !t.isEmpty { body["text"] = .string(t) }
        return try decodeSession(try await request("POST", "/sessions", body: .object(body)))
    }

    func rename(_ id: String, title: String) async throws -> Session {
        try decodeSession(try await request("PATCH", "/sessions/\(id)", body: .object(["title": .string(title)])))
    }

    func delete(_ id: String, purge: Bool = false) async throws {
        _ = try await request("DELETE", "/sessions/\(id)", query: purge ? [URLQueryItem(name: "purge", value: "1")] : [])
    }

    func events(_ id: String, after: Int, limit: Int = 500) async throws -> [HelmEvent] {
        let v = try await request("GET", "/sessions/\(id)/events", query: [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return list(v, key: "events").map(HelmEvent.init(raw:))
    }

    func send(_ id: String, text: String, attachments: [String], clientId: String? = nil) async throws {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let clientId { body["client_id"] = .string(clientId) }
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map { .string($0) }) }
        _ = try await request("POST", "/sessions/\(id)/messages", body: .object(body))
    }

    func dequeue(_ id: String, queueId: String) async throws {
        _ = try await request("DELETE", "/sessions/\(id)/queue/\(queueId)")
    }

    /// Slash commands the session's harness accepts (without the leading `/`).
    func commands(_ id: String) async throws -> [String] {
        try await request("GET", "/sessions/\(id)/commands")["commands"]?.stringArray ?? []
    }

    func interrupt(_ id: String) async throws {
        _ = try await request("POST", "/sessions/\(id)/interrupt")
    }

    func resume(_ id: String) async throws -> Session {
        let v = try await request("POST", "/sessions/\(id)/resume")
        if let s = Session(json: v) { return s }
        return try await session(id)
    }

    func dirs(_ path: String) async throws -> DirListing {
        let v = try await request("GET", "/dirs", query: [URLQueryItem(name: "path", value: path)])
        return DirListing(json: v, requested: path)
    }

    func upload(sessionId: String, data: Data, filename: String, mimeType: String) async throws -> String {
        let boundary = "helm-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"session_id\"")
        line("")
        line(sessionId)
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")

        var req = try makeRequest("POST", "/upload", query: [], auth: true)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let v = try await perform(req, body: body)
        guard let path = v["path"]?.string ?? v.string, !path.isEmpty else {
            throw APIError.decoding("upload returned no path")
        }
        return path
    }

    // MARK: Plumbing

    /// Accepts either a bare array or an object wrapping it (tolerant of either shape).
    private func list(_ v: JSONValue, key: String) -> [JSONValue] {
        if let a = v.array { return a }
        if let a = v[key]?.array { return a }
        if let a = v["items"]?.array { return a }
        return []
    }

    private func decodeSession(_ v: JSONValue) throws -> Session {
        if let s = Session(json: v) ?? v["session"].flatMap(Session.init(json:)) { return s }
        throw APIError.decoding("missing session id")
    }

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem], auth: Bool) throws -> URLRequest {
        guard let base = config.baseURL else { throw APIError.notConfigured }
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard !config.token.isEmpty else { throw APIError.notConfigured }
            req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    @discardableResult
    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: JSONValue? = nil, auth: Bool = true) async throws -> JSONValue {
        var req = try makeRequest(method, path, query: query, auth: auth)
        var data: Data?
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            data = try JSONEncoder().encode(body)
        }
        return try await perform(req, body: data)
    }

    private func perform(_ req: URLRequest, body: Data?) async throws -> JSONValue {
        let result: (Data, URLResponse)
        do {
            if let body {
                result = try await Self.session.upload(for: req, from: body)
            } else {
                result = try await Self.session.data(for: req)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport(Self.describe(error))
        }
        let (data, resp) = result
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = JSONValue.parse(data).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(code, msg)
        }
        if data.isEmpty { return .null }
        return JSONValue.parse(data) ?? .string(String(data: data, encoding: .utf8) ?? "")
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "Timed out. Is WireGuard connected?"
            case .cannotConnectToHost, .cannotFindHost: return "Can't reach the server. Is WireGuard on and helmd running?"
            case .notConnectedToInternet: return "No network connection."
            case .networkConnectionLost: return "Connection lost."
            default: return e.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
