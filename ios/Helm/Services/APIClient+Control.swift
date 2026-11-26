import Foundation

/// Box controller endpoints (helmd control.py). See PROTOCOL.md "Box controller".
extension APIClient {
    func boxOverview() async throws -> BoxOverview {
        BoxOverview(json: try await request("GET", "/box/overview"))
    }

    func boxMetrics(minutes: Int = 15, points: Int = 120) async throws -> [MetricPoint] {
        let v = try await request("GET", "/box/metrics", query: [
            URLQueryItem(name: "minutes", value: String(minutes)),
            URLQueryItem(name: "points", value: String(points)),
        ])
        return v["points"]?.array?.map(MetricPoint.init(json:)) ?? []
    }

    func boxDocker(stats: Bool = false) async throws -> DockerListing {
        DockerListing(json: try await request("GET", "/box/docker",
                                              query: [URLQueryItem(name: "stats", value: stats ? "1" : "0")]))
    }

    func boxDockerAction(_ name: String, action: String) async throws -> JSONValue {
        try await slow("POST", "/box/docker/\(encode(name))/\(action)", timeout: 100)
    }

    func boxDockerLogs(_ name: String, lines: Int = 300) async throws -> String {
        let v = try await slow("GET", "/box/docker/\(encode(name))/logs",
                               query: [URLQueryItem(name: "lines", value: String(lines))], timeout: 45)
        return v["output"]?.string ?? ""
    }

    func boxProcs(sort: String = "cpu", limit: Int = 80, query: String = "") async throws -> [BoxProcess] {
        let v = try await request("GET", "/box/procs", query: [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "q", value: query),
        ])
        return list(v, key: "procs").compactMap(BoxProcess.init(json:))
    }

    func boxSignal(pid: Int, signal: String) async throws -> JSONValue {
        try await request("POST", "/box/procs/\(pid)/signal", body: .object(["signal": .string(signal)]))
    }

    func boxUnits(query: String = "", state: String = "") async throws -> [SystemdUnit] {
        let v = try await request("GET", "/box/units", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "state", value: state),
        ])
        return list(v, key: "units").compactMap(SystemdUnit.init(json:))
    }

    func boxUnitLogs(_ name: String, lines: Int = 300, priority: String = "") async throws -> String {
        let v = try await slow("GET", "/box/units/\(encode(name))/logs", query: [
            URLQueryItem(name: "lines", value: String(lines)),
            URLQueryItem(name: "priority", value: priority),
        ], timeout: 35)
        return v["output"]?.string ?? ""
    }

    func boxJournalErrors(minutes: Int = 60) async throws -> String {
        let v = try await slow("GET", "/box/journal/errors",
                               query: [URLQueryItem(name: "minutes", value: String(minutes))], timeout: 35)
        return v["output"]?.string ?? ""
    }

    func boxNetwork() async throws -> BoxNetwork {
        BoxNetwork(json: try await request("GET", "/box/network"))
    }

    func boxCron() async throws -> [CronJob] {
        list(try await request("GET", "/box/cron"), key: "jobs").compactMap(CronJob.init(json:))
    }

    func boxActions() async throws -> [QuickAction] {
        list(try await request("GET", "/box/actions"), key: "actions").compactMap(QuickAction.init(json:))
    }

    func boxSaveActions(_ actions: [QuickAction]) async throws -> [QuickAction] {
        let v = try await request("PUT", "/box/actions", body: .object(["actions": .array(actions.map(\.json))]))
        return list(v, key: "actions").compactMap(QuickAction.init(json:))
    }

    func boxRunAction(_ action: QuickAction) async throws -> ShellResult {
        let v = try await slow("POST", "/box/actions/\(encode(action.id))/run",
                               timeout: Double(action.timeout) + 20)
        return ShellResult(json: v)
    }

    /// A request with its own timeout, for endpoints that may legitimately take
    /// longer than the shared session's default (docker on a loaded box, actions).
    private func slow(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      timeout: Double) async throws -> JSONValue {
        var req = try makeRequest(method, path, query: query, auth: true)
        req.timeoutInterval = timeout
        return try await perform(req, body: nil)
    }
}
