import Foundation

/// Models for the box remote-control surface (PROTOCOL.md "Box remote control").
/// Every field is lenient: a missing or mistyped value falls back rather than
/// failing the whole decode, matching Session/Harness.

struct BoxSystem {
    var uptimeSeconds: Double?
    var loadavg: [Double]
    var cpus: Int?
    var memTotalMB: Int
    var memAvailableMB: Int
    var memUsedMB: Int
    var swapTotalMB: Int
    var swapUsedMB: Int
    var diskTotalGB: Double
    var diskFreeGB: Double
    var diskUsedPct: Int?
    var hostname: String

    init(json j: JSONValue) {
        uptimeSeconds = j["uptime_seconds"]?.double
        loadavg = j["loadavg"]?.array?.compactMap { $0.double } ?? []
        cpus = j["cpus"]?.int
        memTotalMB = j["mem_total_mb"]?.int ?? 0
        memAvailableMB = j["mem_available_mb"]?.int ?? 0
        memUsedMB = j["mem_used_mb"]?.int ?? 0
        swapTotalMB = j["swap_total_mb"]?.int ?? 0
        swapUsedMB = j["swap_used_mb"]?.int ?? 0
        diskTotalGB = j["disk_total_gb"]?.double ?? 0
        diskFreeGB = j["disk_free_gb"]?.double ?? 0
        diskUsedPct = j["disk_used_pct"]?.int
        hostname = j["hostname"]?.string ?? "box"
    }

    var memUsedPct: Int { memTotalMB > 0 ? Int(100.0 * Double(memUsedMB) / Double(memTotalMB)) : 0 }
    var swapUsedPct: Int { swapTotalMB > 0 ? Int(100.0 * Double(swapUsedMB) / Double(swapTotalMB)) : 0 }

    var uptimeText: String {
        guard let s = uptimeSeconds else { return "—" }
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600
        return d > 0 ? "\(d)d \(h)h" : "\(h)h"
    }
}

struct TmuxSession: Identifiable {
    var name: String
    var windows: Int
    var created: Double?
    var attached: Bool
    var isHelm: Bool
    var id: String { name }

    init?(json j: JSONValue) {
        guard let n = j["name"]?.string else { return nil }
        name = n
        windows = j["windows"]?.int ?? 0
        created = j["created"]?.double
        attached = j["attached"]?.bool ?? false
        isHelm = j["is_helm"]?.bool ?? n.hasPrefix("hx-")
    }
}

struct BoxService: Identifiable {
    var name: String
    var active: String
    var enabled: String
    var id: String { name }

    init?(json j: JSONValue) {
        guard let n = j["name"]?.string else { return nil }
        name = n
        active = j["active"]?.string ?? "unknown"
        enabled = j["enabled"]?.string ?? "unknown"
    }

    var isActive: Bool { active == "active" }
}

struct ClaudeSessionRef: Identifiable {
    var id: String
    var project: String
    var path: String
    var modified: Double
    var sizeKB: Double
    var summary: String

    init?(json j: JSONValue) {
        guard let i = j["id"]?.string else { return nil }
        id = i
        project = j["project"]?.string ?? ""
        path = j["path"]?.string ?? ""
        modified = j["modified"]?.double ?? 0
        sizeKB = j["size_kb"]?.double ?? 0
        summary = j["summary"]?.string ?? ""
    }

    /// Friendly project label: Claude Code encodes the cwd as a dashed path.
    var projectLabel: String {
        let trimmed = project.hasPrefix("-") ? String(project.dropFirst()) : project
        let parts = trimmed.split(separator: "-")
        return parts.suffix(2).joined(separator: "/")
    }
}

struct ClaudeTurn: Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var ts: String?

    init?(json j: JSONValue) {
        guard let r = j["role"]?.string else { return nil }
        role = r
        text = j["text"]?.string ?? ""
        ts = j["ts"]?.string
    }
}

struct BurstModel: Identifiable {
    var model: String
    var target: String
    var held: Bool
    var detail: String
    var id: String { model }

    init?(json j: JSONValue) {
        guard let m = j["model"]?.string else { return nil }
        model = m
        target = j["target"]?.string ?? ""
        held = j["held"]?.bool ?? false
        detail = j["detail"]?.string ?? ""
    }
}

struct ShellResult {
    var ok: Bool
    var exit: Int
    var output: String

    init(json j: JSONValue) {
        ok = j["ok"]?.bool ?? false
        exit = j["exit"]?.int ?? -1
        output = j["output"]?.string ?? ""
    }
}
