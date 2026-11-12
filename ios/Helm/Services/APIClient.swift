import Foundation
import UniformTypeIdentifiers

/// Thin async/await REST client for helmd (PROTOCOL.md "REST").
struct APIClient {
    var config: ServerConfig

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Idle (no-bytes) timeout. helmd may hold a send up to ~30s while it
        // revives a dead runner, so this must exceed that.
        c.timeoutIntervalForRequest = 60
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
        // helmd may wait up to 30s for a revived runner to take the message, past the 20s default.
        var req = try makeRequest("POST", "/sessions/\(id)/messages", query: [], auth: true)
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(req, body: try JSONEncoder().encode(JSONValue.object(body)))
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
        let v = try await multipart("/upload", fields: ["session_id": sessionId],
                                    data: data, filename: filename, mimeType: mimeType)
        guard let path = v["path"]?.string ?? v.string, !path.isEmpty else {
            throw APIError.decoding("upload returned no path")
        }
        return path
    }

    /// Saves a file anywhere on the box (default /root/uploads); returns where it landed.
    func uploadToBox(dir: String, data: Data, filename: String, mimeType: String) async throws -> String {
        let v = try await multipart("/box/upload", fields: ["dir": dir],
                                    data: data, filename: filename, mimeType: mimeType)
        guard let path = v["path"]?.string, !path.isEmpty else {
            throw APIError.decoding("upload returned no path")
        }
        return path
    }

    private func multipart(_ path: String, fields: [String: String], data: Data,
                           filename: String, mimeType: String) async throws -> JSONValue {
        let boundary = "helm-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")

        var req = try makeRequest("POST", path, query: [], auth: true)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Documents can be tens of MB over a phone link; scale the timeout with size.
        req.timeoutInterval = max(120, Double(data.count) / 100_000)
        return try await perform(req, body: body)
    }

    // MARK: Box remote control

    func boxSystem() async throws -> BoxSystem {
        BoxSystem(json: try await request("GET", "/box/system"))
    }

    func boxTmux() async throws -> [TmuxSession] {
        list(try await request("GET", "/box/tmux"), key: "sessions").compactMap(TmuxSession.init(json:))
    }

    func boxTmuxCapture(_ name: String, lines: Int = 200) async throws -> String {
        let v = try await request("GET", "/box/tmux/\(encode(name))/capture",
                                  query: [URLQueryItem(name: "lines", value: String(lines))])
        return v["text"]?.string ?? ""
    }

    func boxTmuxSend(_ name: String, keys: String) async throws {
        _ = try await request("POST", "/box/tmux/\(encode(name))/send", body: .object(["keys": .string(keys)]))
    }

    func boxTmuxKill(_ name: String) async throws {
        _ = try await request("DELETE", "/box/tmux/\(encode(name))")
    }

    func boxReaper() async throws -> ReaperState {
        ReaperState(json: try await request("GET", "/box/reaper"))
    }

    func boxReaperSet(enabled: Bool, idleHours: Double, includeNonHelm: Bool) async throws -> ReaperState {
        ReaperState(json: try await request("PUT", "/box/reaper", body: .object([
            "enabled": .bool(enabled),
            "idle_hours": .number(idleHours),
            "include_non_helm": .bool(includeNonHelm),
        ])))
    }

    func boxReaperRun() async throws -> ReaperState {
        ReaperState(json: try await request("POST", "/box/reaper/run"))
    }

    func boxServices() async throws -> [BoxService] {
        list(try await request("GET", "/box/services"), key: "services").compactMap(BoxService.init(json:))
    }

    @discardableResult
    func boxServiceAction(_ name: String, action: String) async throws -> JSONValue {
        try await request("POST", "/box/services/\(encode(name))/\(action)")
    }

    func boxClaudeSessions(limit: Int = 40) async throws -> [ClaudeSessionRef] {
        let v = try await request("GET", "/box/claude-sessions",
                                  query: [URLQueryItem(name: "limit", value: String(limit))])
        return list(v, key: "sessions").compactMap(ClaudeSessionRef.init(json:))
    }

    func boxClaudeTranscript(project: String, id: String, tail: Int = 60) async throws -> [ClaudeTurn] {
        let v = try await request("GET", "/box/claude-sessions/\(encode(project))/\(encode(id))",
                                  query: [URLQueryItem(name: "tail", value: String(tail))])
        return list(v, key: "turns").compactMap(ClaudeTurn.init(json:))
    }

    func boxBurst() async throws -> [BurstModel] {
        list(try await request("GET", "/box/burst"), key: "models").compactMap(BurstModel.init(json:))
    }

    @discardableResult
    func boxBurstAction(_ model: String, action: String) async throws -> JSONValue {
        try await request("POST", "/box/burst/\(model)/\(action)")
    }

    func boxShell(_ cmd: String, cwd: String? = nil, timeout: Int = 120) async throws -> ShellResult {
        var body: [String: JSONValue] = ["cmd": .string(cmd), "timeout": .number(Double(timeout))]
        if let cwd, !cwd.isEmpty { body["cwd"] = .string(cwd) }
        var req = try makeRequest("POST", "/box/shell", query: [], auth: true)
        req.timeoutInterval = Double(timeout) + 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try JSONEncoder().encode(JSONValue.object(body))
        return ShellResult(json: try await perform(req, body: data))
    }

    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: File manager

    func fsList(_ path: String) async throws -> FsListing {
        FsListing(json: try await request("GET", "/box/fs/list", query: [URLQueryItem(name: "path", value: path)]))
    }

    func fsTree(_ path: String) async throws -> FsTree {
        FsTree(json: try await request("GET", "/box/fs/tree", query: [URLQueryItem(name: "path", value: path)]))
    }

    /// unique: a clash returns "Name-1" rather than reusing the existing folder.
    func fsMkdir(_ path: String, unique: Bool = false) async throws -> String {
        let v = try await request("POST", "/box/fs/mkdir",
                                  body: .object(["path": .string(path), "unique": .bool(unique)]))
        return v["path"]?.string ?? path
    }

    func fsMove(_ src: String, to dst: String) async throws -> String {
        let v = try await request("POST", "/box/fs/move", body: .object(["src": .string(src), "dst": .string(dst)]))
        return v["path"]?.string ?? dst
    }

    func fsDelete(_ path: String) async throws {
        _ = try await request("POST", "/box/fs/delete", body: .object(["path": .string(path)]))
    }

    /// Downloads a box file (or a folder as .zip) to a temp file the caller must move.
    func fsDownload(_ path: String) async throws -> URL {
        var req = try makeRequest("GET", "/box/fs/download", query: [URLQueryItem(name: "path", value: path)], auth: true)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 300
        let (tmp, resp): (URL, URLResponse)
        do {
            (tmp, resp) = try await Self.session.download(for: req)
        } catch {
            throw Self.transportError(error)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            throw Self.httpError(code, data)
        }
        // The system deletes its temp file once this returns, so claim it now.
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: mine)
        return mine
    }

    /// Streams a local file to the box from disk (never loaded into memory).
    /// rel ("Folder/sub/a.pdf") rebuilds folder structure under dir.
    func fsUpload(file: URL, filename: String, dir: String, rel: String? = nil,
                  progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let boundary = "helm-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        var fields = ["dir": dir]
        if let rel { fields["rel"] = rel }
        let size = try Self.writeMultipart(to: body, boundary: boundary, fields: fields, file: file, filename: filename)

        var req = try makeRequest("POST", "/box/upload", query: [], auth: true)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = max(120, Double(size) / 100_000)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.session.upload(for: req, fromFile: body,
                                                         delegate: progress.map { UploadProgress($0) as URLSessionTaskDelegate })
        } catch {
            throw Self.transportError(error)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.httpError(code, data) }
        guard let path = JSONValue.parse(data)?["path"]?.string else {
            throw APIError.decoding("upload returned no path")
        }
        return path
    }

    private static func writeMultipart(to out: URL, boundary: String, fields: [String: String],
                                       file: URL, filename: String) throws -> Int64 {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        var head = ""
        for (k, v) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        let safe = filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\n"
        head += "Content-Type: \(mime)\r\n\r\n"
        try w.write(contentsOf: Data(head.utf8))
        let r = try FileHandle(forReadingFrom: file)
        defer { try? r.close() }
        while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty {
            try w.write(contentsOf: chunk)
        }
        try w.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return Int64(try w.offset())
    }

    private static func transportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let e = error as? URLError, e.code == .cancelled { return CancellationError() }
        return APIError.transport(describe(error))
    }

    private static func httpError(_ code: Int, _ data: Data) -> Error {
        let msg = JSONValue.parse(data).flatMap { $0["detail"]?.string ?? $0["error"]?.string }
            ?? String(data: data, encoding: .utf8) ?? ""
        return APIError.http(code, msg)
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

/// Per-task delegate reporting bytes sent; client-cert challenges go to the shared handler.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onSent: @Sendable (Int64) -> Void
    init(_ onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ClientCertDelegate.shared.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }
}
