import Foundation

/// Models for the box controller (helmd control.py: /box/overview, metrics,
/// docker, procs, units, network, cron, actions). Lenient like Box.swift.

struct MetricPoint: Identifiable, Hashable {
    var t: Double
    var cpu: Double
    var mem: Double
    var swap: Double
    var load: Double
    var rx: Double
    var tx: Double
    var rd: Double
    var wr: Double
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }

    init(json j: JSONValue) {
        t = j["t"]?.double ?? 0
        cpu = j["cpu"]?.double ?? 0
        mem = j["mem"]?.double ?? 0
        swap = j["swap"]?.double ?? 0
        load = j["load"]?.double ?? 0
        rx = j["rx"]?.double ?? 0
        tx = j["tx"]?.double ?? 0
        rd = j["rd"]?.double ?? 0
        wr = j["wr"]?.double ?? 0
    }
}

struct DiskInfo: Identifiable, Hashable {
    var mount: String
    var type: String
    var totalGB: Double
    var usedGB: Double
    var freeGB: Double
    var usedPct: Int
    var remote: Bool
    var ok: Bool
    var error: String?
    var id: String { mount }

    init?(json j: JSONValue) {
        guard let m = j["mount"]?.string else { return nil }
        mount = m
        type = j["type"]?.string ?? ""
        totalGB = j["total_gb"]?.double ?? 0
        usedGB = j["used_gb"]?.double ?? 0
        freeGB = j["free_gb"]?.double ?? 0
        usedPct = j["used_pct"]?.int ?? 0
        remote = j["remote"]?.bool ?? false
        ok = j["ok"]?.bool ?? true
        error = j["error"]?.string
    }
}

struct BoxAlert: Identifiable, Hashable {
    enum Level: String { case crit, warn, info }
    var level: Level
    var kind: String
    var title: String
    var detail: String
    var target: String?
    var id: String { kind + title }

    init?(json j: JSONValue) {
        guard let t = j["title"]?.string else { return nil }
        title = t
        level = Level(rawValue: j["level"]?.string ?? "") ?? .info
        kind = j["kind"]?.string ?? ""
        detail = j["detail"]?.string ?? ""
        target = j["target"]?.string
    }
}

struct BoxOverview {
    var system: BoxSystem
    var latest: MetricPoint?
    var disks: [DiskInfo]
    var alerts: [BoxAlert]
    var containersRunning: Int
    var containersTotal: Int
    var containersUnhealthy: Int
    var unitsFailed: Int
    var tmux: Int
    var helmChats: Int
    var peersOnline: Int
    var peers: Int

    init(json j: JSONValue) {
        system = BoxSystem(json: j["system"] ?? .null)
        latest = j["latest"].flatMap { $0 == .null ? nil : MetricPoint(json: $0) }
        disks = j["disks"]?.array?.compactMap(DiskInfo.init(json:)) ?? []
        alerts = j["alerts"]?.array?.compactMap(BoxAlert.init(json:)) ?? []
        let c = j["counts"] ?? .null
        containersRunning = c["containers_running"]?.int ?? 0
        containersTotal = c["containers_total"]?.int ?? 0
        containersUnhealthy = c["containers_unhealthy"]?.int ?? 0
        unitsFailed = c["units_failed"]?.int ?? 0
        tmux = c["tmux"]?.int ?? 0
        helmChats = c["helm_chats"]?.int ?? 0
        peersOnline = c["peers_online"]?.int ?? 0
        peers = c["peers"]?.int ?? 0
    }

    var critCount: Int { alerts.filter { $0.level == .crit }.count }
}

struct DockerContainer: Identifiable, Hashable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var health: String
    var project: String
    var ports: String
    var cpu: Double?
    var memPct: Double?
    var mem: String?

    init?(json j: JSONValue) {
        guard let n = j["name"]?.string else { return nil }
        name = n
        id = j["id"]?.string ?? n
        image = j["image"]?.string ?? ""
        state = j["state"]?.string ?? ""
        status = j["status"]?.string ?? ""
        health = j["health"]?.string ?? ""
        project = j["project"]?.string ?? ""
        ports = j["ports"]?.string ?? ""
        cpu = j["cpu"]?.double
        memPct = j["mem_pct"]?.double
        mem = j["mem"]?.string
    }

    var isRunning: Bool { state == "running" }
    var isTrouble: Bool { health == "unhealthy" || state == "restarting" || state == "dead" }
}

struct DockerListing {
    var containers: [DockerContainer]
    var ageSeconds: Double?
    var refreshing: Bool
    var error: String?

    init(json j: JSONValue) {
        containers = j["containers"]?.array?.compactMap(DockerContainer.init(json:)) ?? []
        ageSeconds = j["age_s"]?.double
        refreshing = j["refreshing"]?.bool ?? false
        error = j["error"]?.string
    }
}

struct BoxProcess: Identifiable, Hashable {
    var pid: Int
    var ppid: Int
    var user: String
    var cpu: Double
    var mem: Double
    var rssMB: Double
    var elapsed: Int
    var stat: String
    var comm: String
    var args: String
    var id: Int { pid }

    init?(json j: JSONValue) {
        guard let p = j["pid"]?.int else { return nil }
        pid = p
        ppid = j["ppid"]?.int ?? 0
        user = j["user"]?.string ?? ""
        cpu = j["cpu"]?.double ?? 0
        mem = j["mem"]?.double ?? 0
        rssMB = j["rss_mb"]?.double ?? 0
        elapsed = j["elapsed"]?.int ?? 0
        stat = j["stat"]?.string ?? ""
        comm = j["comm"]?.string ?? ""
        args = j["args"]?.string ?? ""
    }
}

struct SystemdUnit: Identifiable, Hashable {
    var name: String
    var load: String
    var active: String
    var sub: String
    var description: String
    var watched: Bool
    var id: String { name }

    init?(json j: JSONValue) {
        guard let n = j["name"]?.string else { return nil }
        name = n
        load = j["load"]?.string ?? ""
        active = j["active"]?.string ?? ""
        sub = j["sub"]?.string ?? ""
        description = j["description"]?.string ?? ""
        watched = j["watched"]?.bool ?? false
    }
}

struct WGPeer: Identifiable, Hashable {
    var iface: String
    var key: String
    var endpoint: String
    var allowed: String
    var handshakeAgo: Int?
    var rx: Double
    var tx: Double
    var online: Bool
    var id: String { iface + key }

    init?(json j: JSONValue) {
        guard let k = j["key"]?.string else { return nil }
        key = k
        iface = j["iface"]?.string ?? ""
        endpoint = j["endpoint"]?.string ?? ""
        allowed = j["allowed"]?.string ?? ""
        handshakeAgo = j["handshake_ago"]?.int
        rx = j["rx"]?.double ?? 0
        tx = j["tx"]?.double ?? 0
        online = j["online"]?.bool ?? false
    }
}

struct ListeningPort: Identifiable, Hashable {
    var addr: String
    var port: Int
    var proc: String
    var id: String { "\(port)-\(proc)-\(addr)" }

    init?(json j: JSONValue) {
        guard let p = j["port"]?.int else { return nil }
        port = p
        addr = j["addr"]?.string ?? ""
        proc = j["proc"]?.string ?? ""
    }

    var isPublic: Bool { addr == "0.0.0.0" || addr == "*" || addr == "::" }
}

struct NetInterface: Identifiable, Hashable {
    var name: String
    var addr: String
    var id: String { name + addr }
}

struct BoxNetwork {
    var peers: [WGPeer]
    var ports: [ListeningPort]
    var interfaces: [NetInterface]

    init(json j: JSONValue) {
        peers = j["peers"]?.array?.compactMap(WGPeer.init(json:)) ?? []
        ports = j["ports"]?.array?.compactMap(ListeningPort.init(json:)) ?? []
        interfaces = j["interfaces"]?.array?.compactMap { v in
            v["name"]?.string.map { NetInterface(name: $0, addr: v["addr"]?.string ?? "") }
        } ?? []
    }
}

struct CronJob: Identifiable, Hashable {
    var line: Int
    var enabled: Bool
    var schedule: String
    var command: String
    var id: Int { line }

    init?(json j: JSONValue) {
        guard let l = j["line"]?.int else { return nil }
        line = l
        enabled = j["enabled"]?.bool ?? true
        schedule = j["schedule"]?.string ?? ""
        command = j["command"]?.string ?? ""
    }
}

struct QuickAction: Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    var cmd: String
    var confirm: Bool
    var timeout: Int

    init(id: String = UUID().uuidString.prefix(8).lowercased(), title: String = "", icon: String = "bolt",
         cmd: String = "", confirm: Bool = false, timeout: Int = 120) {
        self.id = id; self.title = title; self.icon = icon
        self.cmd = cmd; self.confirm = confirm; self.timeout = timeout
    }

    init?(json j: JSONValue) {
        guard let i = j["id"]?.string, let t = j["title"]?.string else { return nil }
        id = i
        title = t
        icon = j["icon"]?.string ?? "bolt"
        cmd = j["cmd"]?.string ?? ""
        confirm = j["confirm"]?.bool ?? false
        timeout = j["timeout"]?.int ?? 120
    }

    var json: JSONValue {
        .object(["id": .string(id), "title": .string(title), "icon": .string(icon), "cmd": .string(cmd),
                 "confirm": .bool(confirm), "timeout": .number(Double(timeout))])
    }
}

// MARK: Formatting

enum Fmt {
    static func rate(_ bytesPerSec: Double) -> String { bytes(bytesPerSec) + "/s" }

    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func duration(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}
